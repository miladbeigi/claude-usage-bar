import Foundation
import Security

// MARK: - Models

enum LimitKind: Hashable, Sendable {
    case session
    case weekly
    /// A weekly limit scoped to one model, by display name ("Fable", "Opus").
    case model(String)

    var id: String {
        switch self {
        case .session: return "five_hour"
        case .weekly: return "seven_day"
        case .model(let name): return "model:" + name.lowercased()
        }
    }

    var title: String {
        switch self {
        case .session: return "Session"
        case .weekly: return "Weekly"
        case .model(let name): return name
        }
    }

    var subtitle: String {
        switch self {
        case .session: return "5 hours"
        case .weekly: return "All models"
        case .model: return "Weekly"
        }
    }

    var symbol: String {
        switch self {
        case .session: return "clock.fill"
        case .weekly: return "calendar"
        case .model: return "cpu"
        }
    }

    var duration: TimeInterval { self == .session ? 5 * 3600 : 7 * 86400 }
}

struct LimitWindow: Identifiable, Sendable {
    let kind: LimitKind
    let utilization: Double // 0...100 (percent)
    let resetsAt: Date?
    var id: String { kind.id }

    /// Fraction of the window that has elapsed (0...1), used for the pace marker.
    func elapsedFraction(now: Date) -> Double? {
        guard let resetsAt else { return nil }
        return min(max(1 - resetsAt.timeIntervalSince(now) / kind.duration, 0), 1)
    }

    /// Projects usage at the reset time from the burn rate so far.
    func pace(now: Date) -> Pace? {
        guard let elapsed = elapsedFraction(now: now), let resetsAt else { return nil }
        if utilization >= 100 { return .reached }
        guard elapsed > 0.03 else { return nil }
        let projected = utilization / (elapsed * 100) // usage at reset, as a multiple of the limit
        let rate = utilization / (elapsed * kind.duration)
        let runsOutIn = min(rate > 0 ? (100 - utilization) / rate : .infinity, resetsAt.timeIntervalSince(now))
        switch projected {
        case ..<0.75: return .under
        case ...1.0: return .onPace
        case ...1.5: return .ahead(runsOutIn: runsOutIn)
        default: return .wayAhead(runsOutIn: runsOutIn)
        }
    }
}

enum Pace: Equatable {
    case under, onPace, ahead(runsOutIn: TimeInterval), wayAhead(runsOutIn: TimeInterval), reached

    var symbol: String {
        switch self {
        case .under: return "tortoise.fill"
        case .onPace: return "dog.fill"
        case .ahead: return "hare.fill"
        case .wayAhead: return "bird.fill"
        case .reached: return "exclamationmark.octagon.fill"
        }
    }

    var label: String {
        switch self {
        case .under: return "Under pace"
        case .onPace: return "On pace"
        case .ahead(let t), .wayAhead(let t): return "Out in ~\(Format.duration(t))"
        case .reached: return "Limit reached"
        }
    }

    var help: String {
        switch self {
        case .under: return "Under pace: at this rate you'll end below 75% of the limit."
        case .onPace: return "On pace: at this rate you'll end at 75–100% of the limit."
        case .ahead: return "Ahead of pace: at this rate you'll hit the limit before it resets."
        case .wayAhead: return "Way ahead: at this rate you'd use over 1.5× the limit before it resets."
        case .reached: return "Limit reached."
        }
    }

    /// Higher is more urgent; used to show a single animal in the menu bar.
    var severity: Int {
        switch self {
        case .under: return 0
        case .onPace: return 1
        case .ahead: return 2
        case .wayAhead: return 3
        case .reached: return 4
        }
    }

    var isWarning: Bool { severity >= 2 }
}

struct UsageSnapshot: Sendable {
    let session: LimitWindow?
    let weekly: LimitWindow?
    /// Per-model weekly limits, sorted by name. Only models the plan actually limits appear.
    var models: [LimitWindow] = []
    let fetchedAt: Date

    var windows: [LimitWindow] { [session, weekly].compactMap { $0 } }
}

struct Credentials: Sendable {
    let accessToken: String
    let expiresAt: Date?
    let subscriptionType: String?
    let rateLimitTier: String?

    var planName: String? {
        let tier = rateLimitTier?.lowercased() ?? ""
        if tier.contains("20x") { return "Max 20x" }
        if tier.contains("5x") { return "Max 5x" }
        guard let s = subscriptionType, !s.isEmpty else { return nil }
        return s.prefix(1).uppercased() + s.dropFirst()
    }
}

enum UsageError: LocalizedError {
    case noCredentials
    case tokenExpired
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case decoding

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "No Claude Code login found. Run `claude` and sign in with your Claude account."
        case .tokenExpired:
            return "Claude Code token expired. Use `claude` once to refresh it."
        case .unauthorized:
            return "Token rejected (401). Use `claude` once to refresh your login."
        case .rateLimited:
            return "Rate limited by Anthropic."
        case .http(let code):
            return "Usage endpoint returned HTTP \(code)."
        case .decoding:
            return "Couldn't read the usage response."
        }
    }
}

// MARK: - Credentials

/// Reads the OAuth token Claude Code stores after `claude` login.
/// We never refresh the token ourselves: rotating the refresh token would log Claude Code out.
enum CredentialStore {
    static let keychainService = "Claude Code-credentials"

    static func load() throws -> Credentials {
        if let creds = loadFromKeychain() { return creds }
        // Claude Code's file-based fallback when the keychain isn't used.
        let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/.credentials.json")
        if let data = try? Data(contentsOf: file), let creds = parse(data) { return creds }
        throw UsageError.noCredentials
    }

    /// Claude Code writes its item with /usr/bin/security, so that tool is on the item's access list.
    /// Reading through it avoids a keychain prompt on every launch, rebuild, or Claude Code token refresh.
    private static func loadFromKeychain() -> Credentials? {
        // Listing attributes (no secret data) never prompts. There can be several accounts per service.
        let listQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        let accounts: [String?]
        if SecItemCopyMatching(listQuery as CFDictionary, &result) == errSecSuccess,
           let items = result as? [[String: Any]] {
            accounts = items.map { $0[kSecAttrAccount as String] as? String }
        } else {
            accounts = [nil]
        }

        for account in accounts {
            var args = ["find-generic-password", "-s", keychainService, "-w"]
            if let account { args += ["-a", account] }
            if let data = runSecurity(args), let creds = parse(data) { return creds }
        }
        return nil
    }

    private static func runSecurity(_ args: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    private static func parse(_ data: Data) -> Credentials? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let expiresAt = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return Credentials(
            accessToken: token,
            expiresAt: expiresAt,
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String
        )
    }
}

// MARK: - API

enum UsageAPI {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func fetch(token: String) async throws -> UsageSnapshot {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("ClaudeUsageBar/\(Updater.currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageError.decoding }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw UsageError.unauthorized
        case 429:
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw UsageError.rateLimited(retryAfter: retry)
        default: throw UsageError.http(http.statusCode)
        }
        return try decode(data)
    }

    /// Legacy top-level per-model buckets that are read when filled in. Other `seven_day_*`
    /// keys (`cowork`, `oauth_apps`, codenames) aren't models, so there is no wildcard match.
    static let legacyModelBuckets = ["seven_day_opus": "Opus", "seven_day_sonnet": "Sonnet"]

    /// Reads the `five_hour` and `seven_day` buckets: {"utilization": 18.0, "resets_at": "2026-…"},
    /// plus per-model weekly limits (see `modelWindows`).
    static func decode(_ data: Data) throws -> UsageSnapshot {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.decoding
        }
        func window(_ key: String, _ kind: LimitKind) -> LimitWindow? {
            guard let obj = json[key] as? [String: Any],
                  let utilization = (obj["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return LimitWindow(kind: kind, utilization: utilization,
                               resetsAt: (obj["resets_at"] as? String).flatMap(parseDate))
        }
        let legacy = legacyModelBuckets.compactMap { window($0.key, .model($0.value)) }
        return UsageSnapshot(session: window("five_hour", .session), weekly: window("seven_day", .weekly),
                             models: modelWindows(json["limits"], legacy: legacy), fetchedAt: Date())
    }

    /// Model-scoped weekly entries in the `limits` array:
    /// {"kind": "weekly_scoped", "percent": 8, "resets_at": "…", "scope": {"model": {"display_name": "Fable"}}},
    /// merged with `legacy` windows for models the array doesn't cover, sorted by name.
    static func modelWindows(_ limits: Any?, legacy: [LimitWindow]) -> [LimitWindow] {
        var byID: [String: LimitWindow] = [:]
        for entry in limits as? [[String: Any]] ?? [] where entry["kind"] as? String == "weekly_scoped" {
            let model = (entry["scope"] as? [String: Any])?["model"] as? [String: Any]
            guard let name = model?["display_name"] as? String, !name.isEmpty,
                  let percent = (entry["percent"] as? NSNumber)?.doubleValue else { continue }
            let window = LimitWindow(kind: .model(name), utilization: percent,
                                     resetsAt: (entry["resets_at"] as? String).flatMap(parseDate))
            byID[window.id] = byID[window.id] ?? window
        }
        for window in legacy where byID[window.id] == nil { byID[window.id] = window }
        return byID.values.sorted { $0.kind.title.localizedCaseInsensitiveCompare($1.kind.title) == .orderedAscending }
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
