// Generates Resources/AppIcon.icns: a coral squircle with two white usage bars and an elapsed-time tick.
// Run: swift scripts/make-icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024 // design on a 1024 canvas

    // macOS icon grid: 824pt body centered on the 1024 canvas.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 186 * s, yRadius: 186 * s)

    // Soft drop shadow, then a warm gradient fill.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 18 * s
    shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
    shadow.set()
    NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [
        NSColor(srgbRed: 0.93, green: 0.58, blue: 0.43, alpha: 1),
        NSColor(srgbRed: 0.78, green: 0.38, blue: 0.26, alpha: 1),
    ])!.draw(in: squircle, angle: -90)

    // Two usage bars, like the menu bar: session (top) and weekly (bottom).
    func bar(y: CGFloat, height: CGFloat, fill: CGFloat) {
        let track = NSRect(x: 232 * s, y: y * s, width: 560 * s, height: height * s)
        let path = NSBezierPath(roundedRect: track, xRadius: height * s / 2, yRadius: height * s / 2)
        NSColor.white.withAlphaComponent(0.28).setFill()
        path.fill()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSColor.white.setFill()
        NSRect(x: track.minX, y: track.minY, width: track.width * fill, height: track.height).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    bar(y: 540, height: 120, fill: 0.68)
    bar(y: 364, height: 84, fill: 0.36)

    // Elapsed-time tick across the top bar.
    let tick = NSRect(x: (232 + 560 * 0.52 - 9) * s, y: 512 * s, width: 18 * s, height: 176 * s)
    NSColor(srgbRed: 0.55, green: 0.22, blue: 0.13, alpha: 0.85).setFill()
    NSBezierPath(roundedRect: tick, xRadius: 9 * s, yRadius: 9 * s).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appending(path: "icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appending(path: "icon_\(size)x\(size)@2x.png"))
}
let out = root.appending(path: "Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
try render(1024).write(to: root.appending(path: "docs/icon.png"))
print(p.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
