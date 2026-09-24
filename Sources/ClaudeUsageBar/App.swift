import AppKit
import Observation
import SwiftUI

@main
struct ClaudeUsageBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// Status item + transient popover: closes on any click outside, unlike MenuBarExtra's window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = UsageStore()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if DebugRender.runIfRequested() { return }
        #endif

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        let host = NSHostingController(rootView: PopoverView().environment(store))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        updateStatusItem()
        store.start()
    }

    /// Re-renders the menu bar image whenever anything it reads changes.
    private func updateStatusItem() {
        withObservationTracking {
            statusItem.button?.image = MenuBarImage.make(store: store)
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateStatusItem() }
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.now = Date()
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        store.settingsOpen = false
    }
}

/// Draws the menu bar content as one template image: [clock] 42%  [calendar] 18%  [pace]
@MainActor
enum MenuBarImage {
    private enum Part {
        case symbol(String)
        case text(String)
        case gap(CGFloat)
    }

    static func make(store: UsageStore) -> NSImage {
        var parts: [Part] = []
        let windows: [LimitWindow?]
        switch store.menuDisplay {
        case .both: windows = [store.session, store.weekly]
        case .session: windows = [store.session]
        case .weekly: windows = [store.weekly]
        }

        if store.snapshot == nil {
            parts = [.symbol("sparkle"), .gap(3), .text("–")]
        } else {
            let shown = windows.compactMap { $0 }
            for (i, window) in shown.enumerated() {
                if i > 0 { parts.append(.gap(8)) }
                parts.append(.symbol(window.kind.symbol))
                parts.append(.gap(3))
                parts.append(.text(Format.percent(window.utilization)))
            }
            // One animal: the most urgent pace among the shown windows.
            let paces = shown.compactMap { $0.pace(now: store.now) }
            if store.showPaceInMenuBar, let pace = paces.max(by: { $0.severity < $1.severity }) {
                parts.append(.gap(6))
                parts.append(.symbol(pace.symbol))
            }
        }
        return render(parts)
    }

    private static func render(_ parts: [Part]) -> NSImage {
        let height: CGFloat = 18
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)

        func symbolImage(_ name: String) -> NSImage? {
            NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        }
        func width(_ part: Part) -> CGFloat {
            switch part {
            case .symbol(let n): return symbolImage(n)?.size.width ?? 0
            case .text(let t): return ceil((t as NSString).size(withAttributes: attrs).width)
            case .gap(let g): return g
            }
        }

        let total = max(parts.reduce(0) { $0 + width($1) }, 1)
        let image = NSImage(size: NSSize(width: total, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for part in parts {
                switch part {
                case .symbol(let n):
                    if let img = symbolImage(n) {
                        img.draw(in: NSRect(x: x, y: (height - img.size.height) / 2, width: img.size.width, height: img.size.height))
                        x += img.size.width
                    }
                case .text(let t):
                    let size = (t as NSString).size(withAttributes: attrs)
                    (t as NSString).draw(at: NSPoint(x: x, y: (height - size.height) / 2), withAttributes: attrs)
                    x += ceil(size.width)
                case .gap(let g):
                    x += g
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
