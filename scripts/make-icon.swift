// swift scripts/make-icon.swift → Resources/AppIcon.icns
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGradient(starting: NSColor(white: 0.16, alpha: 1), ending: NSColor(white: 0.06, alpha: 1))!.draw(in: bg, angle: -90)
    NSColor(white: 1, alpha: 0.1).setStroke(); bg.lineWidth = s * 0.006; bg.stroke()
    // The pill: a vertical capsule with three status dots.
    let pw = tile.width * 0.26, ph = tile.height * 0.62
    let pill = NSRect(x: tile.midX - pw / 2, y: tile.midY - ph / 2, width: pw, height: ph)
    let pillPath = NSBezierPath(roundedRect: pill, xRadius: pw / 2, yRadius: pw / 2)
    NSColor(white: 0.03, alpha: 1).setFill(); pillPath.fill()
    NSColor(white: 1, alpha: 0.14).setStroke(); pillPath.lineWidth = s * 0.008; pillPath.stroke()
    let colors = [NSColor(red: 0.99, green: 0.74, blue: 0.27, alpha: 1), NSColor(red: 0.32, green: 0.82, blue: 0.50, alpha: 1),
                  NSColor(red: 0.68, green: 0.55, blue: 1.0, alpha: 1)]
    for (i, c) in colors.enumerated() {
        let d = pw * (i == 0 ? 0.52 : 0.34)
        let cy = pill.maxY - pw * 0.62 - CGFloat(i) * ph * 0.3
        c.setFill(); NSBezierPath(ovalIn: NSRect(x: pill.midX - d / 2, y: cy - d / 2, width: d, height: d)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: dir.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: dir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
