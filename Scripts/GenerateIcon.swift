import AppKit
import ImageIO

// Produce exact, opaque 1024px asset-catalog inputs from the original artwork.
let root = "Assets.xcassets/AppIcon.appiconset"
try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
for (source, filename) in [("IconLight.png", "AppIcon.png"), ("IconDark.png", "AppIconDark.png")] {
    let url = URL(fileURLWithPath: "Artwork/" + source)
    guard let input = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(input, 0, nil),
          let context = CGContext(data: nil, width: 1024, height: 1024,
            bitsPerComponent: 8, bytesPerRow: 1024 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("Missing icon artwork") }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    guard let output = context.makeImage() else { fatalError("Cannot render icon") }
    let bitmap = NSBitmapImageRep(cgImage: output)
    // Catch failed offscreen rendering before shipping an empty icon.
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    let total = (0..<(1024 * 1024)).reduce(UInt64(0)) { sum, pixel in
        sum + UInt64(pixels[pixel * 4]) + UInt64(pixels[pixel * 4 + 1]) + UInt64(pixels[pixel * 4 + 2])
    }
    precondition(total > 15 * 3 * 1024 * 1024, "Icon rendering is blank")
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: root + "/" + filename))
}
