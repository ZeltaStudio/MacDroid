import AppKit

// Reuse the same SF Symbol as the app's sidebar; this is a vector-native asset.
let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources", isDirectory: true)
let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
guard let symbol = NSImage(systemSymbolName: "externaldrive.connected.to.line.below.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 600, weight: .regular)) else {
    fatalError("The app's drive symbol is unavailable")
}

func render(_ pixels: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.imageInterpolation = .high
    let tile = NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 205, yRadius: 205)
    NSGradient(starting: NSColor(srgbRed: 0.20, green: 0.23, blue: 0.24, alpha: 1),
               ending: NSColor(srgbRed: 0.11, green: 0.13, blue: 0.14, alpha: 1))!.draw(in: tile, angle: -90)
    NSColor(white: 1, alpha: 0.08).setStroke(); tile.lineWidth = 2; tile.stroke()
    let ratio = symbol.size.width / symbol.size.height
    let height: CGFloat = 600
    let width = height * ratio
    let rect = NSRect(x: (1024 - width) / 2, y: 212, width: width, height: height)
    // A transparency layer confines source-in tinting to the symbol, leaving the tile untouched.
    context.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
    symbol.draw(in: rect)
    NSColor(srgbRed: 0, green: 0.81, blue: 0.73, alpha: 1).setFill()
    rect.fill(using: .sourceIn)
    context.cgContext.endTransparencyLayer()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for points in [16, 32, 128, 256, 512] {
    try render(points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
try render(1024).write(to: output.appendingPathComponent("AppIcon.png"))
print("Generated iconset at \(iconset.path)")
