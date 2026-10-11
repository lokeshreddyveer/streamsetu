// Generates AppIcon.icns: swift Scripts/make-icon.swift <output-dir>
import AppKit

func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
    defer { NSGraphicsContext.restoreGraphicsState() }
    let s = CGFloat(size)
    let tile = NSRect(x: 0, y: 0, width: s, height: s).insetBy(dx: s * 0.055, dy: s * 0.055)
    let shape = NSBezierPath(roundedRect: tile, xRadius: s * 0.225, yRadius: s * 0.225)
    NSGradient(colors: [NSColor(red: 0.13, green: 0.15, blue: 0.21, alpha: 1), NSColor(red: 0.035, green: 0.043, blue: 0.063, alpha: 1)])!.draw(in: shape, angle: -90)
    NSColor.white.withAlphaComponent(0.08).setStroke(); shape.lineWidth = s * 0.006; shape.stroke()

    // television
    let tv = NSRect(x: s * 0.2, y: s * 0.3, width: s * 0.6, height: s * 0.42)
    let body = NSBezierPath(roundedRect: tv, xRadius: s * 0.07, yRadius: s * 0.07)
    NSColor.white.withAlphaComponent(0.94).setStroke(); body.lineWidth = s * 0.035; body.stroke()
    // antenna
    let ant = NSBezierPath()
    ant.move(to: NSPoint(x: s * 0.5, y: tv.maxY)); ant.line(to: NSPoint(x: s * 0.4, y: s * 0.82))
    ant.move(to: NSPoint(x: s * 0.5, y: tv.maxY)); ant.line(to: NSPoint(x: s * 0.6, y: s * 0.82))
    ant.lineWidth = s * 0.03; ant.lineCapStyle = .round; NSColor.white.withAlphaComponent(0.94).setStroke(); ant.stroke()
    // stand
    let stand = NSBezierPath(roundedRect: NSRect(x: s * 0.38, y: s * 0.235, width: s * 0.24, height: s * 0.03), xRadius: s * 0.015, yRadius: s * 0.015)
    NSColor.white.withAlphaComponent(0.94).setFill(); stand.fill()
    // play triangle
    let tri = NSBezierPath()
    tri.move(to: NSPoint(x: s * 0.445, y: s * 0.43)); tri.line(to: NSPoint(x: s * 0.445, y: s * 0.59)); tri.line(to: NSPoint(x: s * 0.585, y: s * 0.51)); tri.close()
    NSColor(red: 0.933, green: 0.271, blue: 0.290, alpha: 1).setFill(); tri.fill()
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: dir.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: dir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
