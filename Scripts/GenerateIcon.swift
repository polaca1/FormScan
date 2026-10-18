import AppKit

func icon(dark: Bool) -> NSBitmapImageRep {
    let size = 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                               bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }
    let bounds = NSRect(x: 0, y: 0, width: size, height: size)
    let base = dark ? NSColor(calibratedRed: 0.09, green: 0.08, blue: 0.15, alpha: 1) :
        NSColor(calibratedRed: 0.96, green: 0.95, blue: 1.0, alpha: 1)
    base.setFill()
    bounds.fill()
    let plate = NSBezierPath(roundedRect: NSRect(x: 168, y: 158, width: 688, height: 708), xRadius: 166, yRadius: 166)
    let gradient = NSGradient(starting: dark ? NSColor(calibratedRed: 0.30, green: 0.21, blue: 0.56, alpha: 1) : .white,
                              ending: dark ? NSColor(calibratedRed: 0.14, green: 0.10, blue: 0.29, alpha: 1) :
                                NSColor(calibratedRed: 0.88, green: 0.85, blue: 0.98, alpha: 1))!
    gradient.draw(in: plate, angle: -70)
    NSColor(calibratedWhite: dark ? 1 : 0.45, alpha: 0.22).setStroke()
    plate.lineWidth = 9
    plate.stroke()
    let ink = NSColor(calibratedRed: dark ? 0.79 : 0.47, green: dark ? 0.66 : 0.27, blue: dark ? 1.0 : 0.90, alpha: 1)
    ink.setStroke()
    let doc = NSBezierPath(roundedRect: NSRect(x: 347, y: 307, width: 330, height: 416), xRadius: 39, yRadius: 39)
    doc.lineWidth = 34
    doc.stroke()
    for y in [566.0, 481.0, 396.0] {
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 417, y: y))
        line.line(to: NSPoint(x: 606, y: y))
        line.lineWidth = 29
        line.lineCapStyle = .round
        line.stroke()
    }
    return rep
}
let root = "Assets.xcassets/AppIcon.appiconset"
try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
for (dark, name) in [(false, "AppIcon.png"), (true, "AppIconDark.png")] {
    let png = icon(dark: dark).representation(using: .png, properties: [:])!
    try png.write(to: URL(fileURLWithPath: root + "/" + name))
}
