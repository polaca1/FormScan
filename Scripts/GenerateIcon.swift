import AppKit

// Produce exact, opaque 1024px asset-catalog inputs from the original artwork.
let root = "Assets.xcassets/AppIcon.appiconset"
try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
for (source, filename) in [("IconLight.png", "AppIcon.png"), ("IconDark.png", "AppIconDark.png")] {
    guard let image = NSImage(contentsOfFile: "Artwork/" + source),
          let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { fatalError("Missing icon artwork") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: root + "/" + filename))
}
