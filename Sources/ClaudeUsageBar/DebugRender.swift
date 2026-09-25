#if DEBUG
import AppKit
import SwiftUI

/// `ClaudeUsageBar --render <dir> [--settings] [--models]` writes popover and menu bar images with sample data, then exits.
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

        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            let view = PopoverView().environment(store)
                .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.97))
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let img = renderer.nsImage { write(img, to: dir.appending(path: "\(name).png")) }
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
