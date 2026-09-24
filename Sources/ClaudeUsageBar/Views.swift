import AppKit
import SwiftUI

// MARK: - Layout & palette

/// One grid for the whole popover: icons sit in a narrow column inline with their text;
/// bars and detail lines run the full width.
private enum Layout {
    static let width: CGFloat = 330
    static let inset: CGFloat = 14
    static let iconColumn: CGFloat = 16
    static let iconGap: CGFloat = 6
    static let rowSpacing: CGFloat = 16
}

private extension Color {
    /// Light/dark pair resolved by the current appearance.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

private enum Palette {
    static let brand = Color(red: 0.85, green: 0.47, blue: 0.34)
    // Status colors: reserved for limit state, always paired with an icon + label.
    static let warning = Color.dynamic(light: 0xD48A00, dark: 0xFAB219)
    static let critical = Color.dynamic(light: 0xD03B3B, dark: 0xE66767)
}

private enum Level {
    case normal, high, critical

    init(_ utilization: Double) {
        switch utilization {
        case ..<70: self = .normal
        case ..<90: self = .high
        default: self = .critical
        }
    }

    var fill: Color {
        switch self {
        case .normal: return Color.primary.opacity(0.78)
        case .high: return Palette.warning
        case .critical: return Palette.critical
        }
    }

    var badge: StatusPill? {
        switch self {
        case .normal: return nil
        case .high: return StatusPill(icon: "exclamationmark.circle.fill", text: "High", color: Palette.warning)
        case .critical: return StatusPill(icon: "exclamationmark.octagon.fill", text: "Near limit", color: Palette.critical)
        }
    }
}

/// Fixed-width icon cell so titles line up across rows.
private struct IconCell: View {
    let symbol: String
    var color: Color = .secondary
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: Layout.iconColumn, alignment: .center)
    }
}

// MARK: - Popover

struct PopoverView: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: Layout.rowSpacing) {
                if let error = store.apiError { ErrorNote(text: error) }
                limits
            }
            .padding(Layout.inset)
            if store.settingsOpen {
                Divider()
                SettingsSection().padding(Layout.inset)
            }
            footer
        }
        .frame(width: Layout.width)
    }

    private var header: some View {
        HStack(spacing: Layout.iconGap) {
            IconCell(symbol: "sparkle", color: Palette.brand, size: 14)
            Text(store.plan ?? "Claude")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            if let update = store.availableUpdate {
                Button {
                    Task { await store.installUpdate() }
                } label: {
                    Label(store.isInstallingUpdate ? "Updating…" : "Update", systemImage: "arrow.down.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .disabled(store.isInstallingUpdate)
                .help("Install version \(update.version), then relaunch")
            }
            Text(store.lastUpdatedText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button {
                Task { await store.refresh(manual: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                    .animation(store.isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                               value: store.isRefreshing)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle().inset(by: -6))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .keyboardShortcut("r")
            .help("Refresh (⌘R)")
        }
        .padding(.horizontal, Layout.inset)
        .frame(height: 40)
    }

    @ViewBuilder private var limits: some View {
        if let snapshot = store.snapshot {
            ForEach(snapshot.windows) { window in
                LimitRow(window: window, now: store.now)
            }
        } else if store.apiError == nil {
            HStack(spacing: Layout.iconGap) {
                ProgressView().controlSize(.small).frame(width: Layout.iconColumn)
                Text("Loading…").font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
            } label: {
                HStack(spacing: 4) {
                    Text("Open claude.ai").fixedSize()
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold))
                }
            }
            Spacer(minLength: 12)
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { store.settingsOpen.toggle() }
            } label: {
                ShortcutLabel(title: store.settingsOpen ? "Done" : "Settings", keys: ["⌘", ","])
            }
            .keyboardShortcut(",")
            Button { NSApp.terminate(nil) } label: {
                ShortcutLabel(title: "Quit", keys: ["⌘", "Q"])
            }
            .keyboardShortcut("q")
        }
        .buttonStyle(.plain)
        .focusable(false)
        .font(.system(size: 12, weight: .medium))
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Layout.inset)
        .frame(width: Layout.width, height: 36)
        .background(Color.primary.opacity(0.04))
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Limit row

/// [icon] Title  subtitle  [badge]          74%
/// ████████████|──────────────────────────────
/// Resets 1:28 PM · 2h 13m        🐇 Out in ~58m
struct LimitRow: View {
    let window: LimitWindow
    let now: Date

    private var level: Level { Level(window.utilization) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            titleLine
            UsageBar(fraction: window.utilization / 100, marker: window.elapsedFraction(now: now), fill: level.fill)
            metaLine.padding(.top, 3)
        }
    }

    private var titleLine: some View {
        HStack(alignment: .center, spacing: Layout.iconGap) {
            IconCell(symbol: window.kind.symbol, size: 12)
            Text(window.kind.title)
                .font(.system(size: 13, weight: .semibold))
            Text(window.kind.subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if let badge = level.badge { badge }
            Spacer(minLength: 8)
            (Text("\(Int(window.utilization.rounded()))")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
             + Text("%")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.secondary))
                .monospacedDigit()
        }
        .frame(height: 24)
    }

    private var metaLine: some View {
        HStack(spacing: 8) {
            if let reset = window.resetsAt {
                Text("Resets \(resetClock(reset)) · \(Format.duration(reset.timeIntervalSince(now)))")
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let pace = window.pace(now: now) {
                HStack(spacing: 4) {
                    Image(systemName: pace.symbol)
                        .foregroundStyle(pace.isWarning ? Palette.warning : Color.secondary)
                    Text(pace.label)
                }
                .lineLimit(1)
                .fixedSize()
                .help(pace.help)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private func resetClock(_ date: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

struct UsageBar: View {
    let fraction: Double
    let marker: Double?
    let fill: Color

    var body: some View {
        GeometryReader { geo in
            let clamped = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(fill)
                    .frame(width: clamped > 0 ? max(geo.size.width * clamped, 6) : 0)
                if let marker {
                    // Time-elapsed tick: usage past it means you're burning faster than the window allows.
                    Capsule()
                        .fill(Color.primary.opacity(0.45))
                        .frame(width: 2, height: geo.size.height + 6)
                        .offset(x: geo.size.width * marker - 1)
                }
            }
        }
        .frame(height: 6)
        .help(marker.map { "Bar: usage · Tick: \(Int(($0 * 100).rounded()))% of the window has elapsed" } ?? "")
    }
}

// MARK: - Small pieces

private struct StatusPill: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).foregroundStyle(.primary)
        }
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15), in: Capsule())
    }
}

private struct ShortcutLabel: View {
    let title: String
    let keys: [String]

    var body: some View {
        HStack(spacing: 6) {
            Text(title).fixedSize()
            HStack(spacing: 2) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
    }
}

private struct ErrorNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Layout.iconGap) {
            IconCell(symbol: "exclamationmark.triangle.fill", color: Palette.warning, size: 12)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .padding(.vertical, 8)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Settings

struct SettingsSection: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 4) {
            Text("Settings")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            SettingRow(icon: "menubar.rectangle", title: "Menu bar") {
                Picker("", selection: $store.menuDisplay) {
                    ForEach(MenuDisplay.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingRow(icon: "hare", title: "Pace animal in menu bar") {
                Toggle("", isOn: $store.showPaceInMenuBar).labelsHidden().toggleStyle(.switch)
            }
            SettingRow(icon: "arrow.clockwise", title: "Check every") {
                Picker("", selection: $store.refreshMinutes) {
                    ForEach([2, 5, 10, 15, 30], id: \.self) { Text("\($0) min").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingRow(icon: "power", title: "Launch at login") {
                Toggle("", isOn: $store.launchAtLogin).labelsHidden().toggleStyle(.switch)
            }
            if Updater.repository != nil {
                Group {
                    SettingRow(icon: "arrow.down.circle", title: "Check for updates") {
                        Toggle("", isOn: $store.checkForUpdates).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow(icon: "info.circle", title: "Version \(Updater.currentVersion)") {
                        Button {
                            Task { await store.checkForUpdate(manual: true) }
                        } label: {
                            HStack(spacing: 4) {
                                if store.isCheckingUpdate {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                                Text("Check now")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(store.isCheckingUpdate)
                        .focusable(false)
                    }
                    if let status = store.updateStatus {
                        IndentedNote(text: status)
                            .transition(.opacity)
                    }
                    if let update = store.availableUpdate {
                        HStack(spacing: Layout.iconGap) {
                            IconCell(symbol: "arrow.down.circle.fill", color: .accentColor, size: 11)
                            Text("Version \(update.version) is available").font(.system(size: 12))
                            Spacer(minLength: 8)
                            Button(store.isInstallingUpdate ? "Updating…" : "Update") {
                                Task { await store.installUpdate() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(store.isInstallingUpdate)
                            .focusable(false)
                        }
                        .frame(height: 22)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: store.updateStatus)
                .animation(.easeInOut(duration: 0.2), value: store.availableUpdate)
            }

            Text("Pace")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            PaceLegend()
        }
        .controlSize(.small)
    }
}

/// Secondary text aligned with setting titles, wrapping instead of truncating.
private struct IndentedNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Layout.iconGap) {
            Color.clear.frame(width: Layout.iconColumn, height: 1)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}

private struct SettingRow<Control: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: Layout.iconGap) {
            IconCell(symbol: icon, size: 11)
            Text(title).font(.system(size: 12))
            Spacer(minLength: 8)
            control
        }
        .frame(height: 22)
    }
}

/// Explains the animals: where you'll end up at reset if you keep this rate.
private struct PaceLegend: View {
    private let items: [(String, String, String)] = [
        ("tortoise.fill", "Under pace", "ends below 75%"),
        ("dog.fill", "On pace", "ends at 75–100%"),
        ("hare.fill", "Ahead", "runs out before reset"),
        ("bird.fill", "Way ahead", "over 1.5× the limit"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(items, id: \.0) { symbol, name, detail in
                HStack(spacing: Layout.iconGap) {
                    IconCell(symbol: symbol, size: 11)
                    Text(name).foregroundStyle(.primary)
                    Text(detail).foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 11))
    }
}
