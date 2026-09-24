import Foundation
import Observation
import ServiceManagement

enum MenuDisplay: String, CaseIterable, Identifiable {
    case both, session, weekly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .both: return "Session and weekly"
        case .session: return "Session only"
        case .weekly: return "Weekly only"
        }
    }
}

@MainActor
@Observable
final class UsageStore {
    var snapshot: UsageSnapshot?
    var plan: String?
    private(set) var apiError: String?
    private(set) var isRefreshing = false
    var now = Date()
    var settingsOpen = false
    private(set) var availableUpdate: AppRelease?
    private(set) var updateStatus: String?
    private(set) var isInstallingUpdate = false

    var menuDisplay: MenuDisplay {
        didSet { defaults.set(menuDisplay.rawValue, forKey: "menuDisplay") }
    }
    var showPaceInMenuBar: Bool {
        didSet { defaults.set(showPaceInMenuBar, forKey: "showPaceInMenuBar") }
    }
    var checkForUpdates: Bool {
        didSet {
            defaults.set(checkForUpdates, forKey: "checkForUpdates")
            if checkForUpdates { Task { await self.checkForUpdate(manual: false) } }
        }
    }
    var refreshMinutes: Int {
        didSet { defaults.set(refreshMinutes, forKey: "refreshMinutes") }
    }
    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                apiError = "Launch at login failed: \(error.localizedDescription)"
            }
        }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var credentials: Credentials?
    @ObservationIgnored private var lastFetch = Date.distantPast
    @ObservationIgnored private var backoffUntil = Date.distantPast
    @ObservationIgnored private var backoff: TimeInterval = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var lastUpdateCheck = Date.distantPast

    init() {
        menuDisplay = MenuDisplay(rawValue: defaults.string(forKey: "menuDisplay") ?? "") ?? .both
        showPaceInMenuBar = defaults.object(forKey: "showPaceInMenuBar") as? Bool ?? true
        checkForUpdates = defaults.object(forKey: "checkForUpdates") as? Bool ?? true
        let minutes = defaults.integer(forKey: "refreshMinutes")
        refreshMinutes = minutes > 0 ? minutes : 5
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func start() {
        guard !started else { return }
        started = true
        Task { await run() }
    }

    // MARK: Derived values

    var session: LimitWindow? { snapshot?.session }
    var weekly: LimitWindow? { snapshot?.weekly }

    var lastUpdatedText: String {
        guard let fetched = snapshot?.fetchedAt else { return "Not updated yet" }
        let seconds = now.timeIntervalSince(fetched)
        return seconds < 60 ? "Updated just now" : "Updated \(Format.duration(seconds)) ago"
    }

    // MARK: Refresh loop

    private func run() async {
        await refresh(manual: true)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            await refresh(manual: false)
        }
    }

    func refresh(manual: Bool) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        now = Date()

        if checkForUpdates, Updater.repository != nil, now.timeIntervalSince(lastUpdateCheck) > 6 * 3600 {
            await checkForUpdate(manual: false)
        }

        let due = now.timeIntervalSince(lastFetch) >= Double(refreshMinutes * 60)
        if (manual || due) && now >= backoffUntil {
            await fetchLimits()
        } else if manual, now < backoffUntil {
            apiError = "Rate limited — next try in \(Format.duration(backoffUntil.timeIntervalSince(now)))."
        }
    }

    private func fetchLimits() async {
        lastFetch = Date()
        do {
            let creds = try await loadCredentials()
            let snap = try await UsageAPI.fetch(token: creds.accessToken)
            snapshot = snap
            apiError = nil
            backoff = 0
        } catch UsageError.rateLimited(let retryAfter) {
            backoff = min(max(backoff * 2, 120), 1800)
            let wait = retryAfter ?? backoff
            backoffUntil = Date().addingTimeInterval(wait)
            apiError = "Rate limited by Anthropic — retrying in \(Format.duration(wait))."
        } catch UsageError.unauthorized {
            credentials = nil // Claude Code may have refreshed the token; re-read next time.
            apiError = UsageError.unauthorized.errorDescription
        } catch {
            credentials = nil
            apiError = error.localizedDescription
        }
    }

    // MARK: Updates

    func checkForUpdate(manual: Bool) async {
        lastUpdateCheck = Date()
        do {
            let release = try await Updater.latestRelease()
            if let release, Updater.isNewer(release.version, than: Updater.currentVersion) {
                availableUpdate = release
                updateStatus = nil
            } else {
                availableUpdate = nil
                if manual { updateStatus = "You're on the latest version." }
            }
        } catch {
            if manual { updateStatus = error.localizedDescription }
        }
    }

    func installUpdate() async {
        guard let release = availableUpdate, !isInstallingUpdate else { return }
        isInstallingUpdate = true
        updateStatus = "Downloading v\(release.version)…"
        do {
            try await Updater.install(release) // quits and relaunches on success
        } catch {
            isInstallingUpdate = false
            updateStatus = error.localizedDescription
        }
    }

    private func loadCredentials() async throws -> Credentials {
        if let c = credentials, (c.expiresAt ?? .distantFuture) > Date() { return c }
        // Keychain access may show a system prompt; keep it off the main thread.
        let c = try await Task.detached { try CredentialStore.load() }.value
        plan = c.planName
        if let exp = c.expiresAt, exp <= Date() { throw UsageError.tokenExpired }
        credentials = c
        return c
    }
}

enum Format {
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(Int(seconds / 60), 0)
        let d = minutes / 1440, h = (minutes % 1440) / 60, m = minutes % 60
        if d > 0 { return "\(d)d \(h)h" }
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    static func percent(_ value: Double) -> String {
        value < 10 && value > 0 && value.rounded() != value
            ? String(format: "%.1f%%", value)
            : "\(Int(value.rounded()))%"
    }
}

#if DEBUG
extension UsageStore {
    /// Debug-only: fills the store with sample data so the UI can be rendered without network or keychain.
    func loadPreviewData() {
        let now = Date()
        snapshot = UsageSnapshot(
            session: LimitWindow(kind: .session, utilization: 74, resetsAt: now.addingTimeInterval(2 * 3600 + 13 * 60)),
            weekly: LimitWindow(kind: .weekly, utilization: 18, resetsAt: now.addingTimeInterval(4 * 86400)),
            fetchedAt: now.addingTimeInterval(-90)
        )
        plan = "Max 5x"
        self.now = now
    }
}
#endif
