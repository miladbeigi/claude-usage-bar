#if DEBUG
import AppKit
import SwiftUI

/// `ClaudeUsageBar --render <dir> [--settings] [--models] [--scale N]` writes popover and menu bar images with sample data, then exits.
@MainActor
enum DebugRender {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        // `--test-update <zip file URL> <sha256 file URL>`: runs the real installer against local files.
        if let i = args.firstIndex(of: "--test-update"), i + 2 < args.count,
           let zip = URL(string: args[i + 1]), let sum = URL(string: args[i + 2]) {
            Task {
                do {
                    try await Updater.install(AppRelease(version: "test", zipURL: zip, checksumURL: sum, pageURL: nil))
                } catch {
                    print("update failed: \(error.localizedDescription)")
                    exit(1)
                }
            }
            return true
        }
        guard let i = args.firstIndex(of: "--render"), i + 1 < args.count else { return false }
        let dir = URL(fileURLWithPath: args[i + 1])
        let store = UsageStore()
        store.loadPreviewData()
        store.settingsOpen = args.contains("--settings")

        // `--scale N` sets the pixel density of the popover images (default 1).
        let scale = args.firstIndex(of: "--scale").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 1

        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            NSApp.appearance = appearance
            let view = PopoverView().environment(store)
                .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.97))
                .environment(\.colorScheme, scheme)
            // Drawn through an offscreen window rather than ImageRenderer so native controls
            // (switches and pop-up menus) render as themselves instead of placeholders.
            let host = NSHostingView(rootView: view)
            host.appearance = appearance
            host.setFrameSize(host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = appearance
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            host.display()
            if let rep = snapshot(host, scale: scale) {
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "\(name).png"))
            }
        }

        // Menu bar image tinted white on a dark strip, like a dark menu bar.
        let bar = MenuBarImage.make(store: store)
        let strip = NSImage(size: NSSize(width: bar.size.width + 20, height: 24), flipped: false) { rect in
            NSColor(white: 0.15, alpha: 1).setFill()
            rect.fill()
            let tinted = NSImage(size: bar.size, flipped: false) { r in
                bar.draw(in: r)
                NSColor.white.set()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: 10, y: 3, width: bar.size.width, height: bar.size.height))
            return true
        }
        write(strip, to: dir.appending(path: "menubar.png"), scale: 3)
        exit(0)
    }

    private static func snapshot(_ view: NSView, scale: Double) -> NSBitmapImageRep? {
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private static func write(_ image: NSImage, to url: URL, scale: CGFloat = 1) {
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
