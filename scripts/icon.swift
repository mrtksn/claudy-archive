import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for (points, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let pixels = points * scale
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = AffineTransform(scale: CGFloat(pixels) / 1024)
    (transform as NSAffineTransform).concat()
    NSColor(srgbRed: 0.76, green: 0.37, blue: 0.25, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 34, y: 34, width: 956, height: 956), xRadius: 215, yRadius: 215).fill()
    NSColor(srgbRed: 0.95, green: 0.87, blue: 0.76, alpha: 0.42).setFill()
    NSBezierPath(roundedRect: NSRect(x: 238, y: 205, width: 610, height: 510), xRadius: 105, yRadius: 105).fill()
    NSColor(srgbRed: 1, green: 0.97, blue: 0.91, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 165, y: 306, width: 635, height: 500), xRadius: 108, yRadius: 108).fill()
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: 245, y: 345)); tail.line(to: NSPoint(x: 245, y: 235)); tail.line(to: NSPoint(x: 380, y: 345)); tail.close(); tail.fill()
    NSColor(srgbRed: 0.76, green: 0.37, blue: 0.25, alpha: 1).setFill()
    for (y, width) in [(645, 360), (535, 360), (425, 240)] {
        NSBezierPath(roundedRect: NSRect(x: 285, y: y, width: width, height: 35), xRadius: 17, yRadius: 17).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
}

// ICNS is a big-endian container of PNG representations. Building it directly
// also works in restricted environments where iconutil's image service cannot run.
func bigEndian(_ value: UInt32) -> Data {
    var value = value.bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}
var contents = Data()
for (kind, name) in [("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"),
                     ("icp6", "icon_32x32@2x.png"), ("ic07", "icon_128x128.png"),
                     ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"),
                     ("ic10", "icon_512x512@2x.png")] {
    let png = try Data(contentsOf: directory.appendingPathComponent(name))
    contents.append(Data(kind.utf8)); contents.append(bigEndian(UInt32(png.count + 8))); contents.append(png)
}
var icon = Data("icns".utf8)
icon.append(bigEndian(UInt32(contents.count + 8))); icon.append(contents)
try icon.write(to: directory.deletingLastPathComponent().appendingPathComponent("AppIcon.icns"))
