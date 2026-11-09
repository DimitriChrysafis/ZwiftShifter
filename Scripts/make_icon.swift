import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else { fatalError("Usage: make_icon.swift output.iconset") }
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for size in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let pixels = size * scale
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let tile = NSBezierPath(
      roundedRect: NSRect(x: 58, y: 58, width: 908, height: 908), xRadius: 210, yRadius: 210)
    NSColor(white: 0.96, alpha: 1).setFill()
    tile.fill()
    NSColor(white: 0.83, alpha: 1).setStroke()
    tile.lineWidth = 2
    tile.stroke()
    context.setStrokeColor(NSColor(white: 0.14, alpha: 1).cgColor)
    context.setLineWidth(60)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: 368, y: 330))
    context.addLine(to: CGPoint(x: 368, y: 694))
    context.move(to: CGPoint(x: 256, y: 582))
    context.addLine(to: CGPoint(x: 368, y: 694))
    context.addLine(to: CGPoint(x: 480, y: 582))
    context.move(to: CGPoint(x: 656, y: 694))
    context.addLine(to: CGPoint(x: 656, y: 330))
    context.move(to: CGPoint(x: 544, y: 442))
    context.addLine(to: CGPoint(x: 656, y: 330))
    context.addLine(to: CGPoint(x: 768, y: 442))
    context.strokePath()
    NSGraphicsContext.restoreGraphicsState()
    let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
    try bitmap.representation(using: .png, properties: [:])!.write(
      to: output.appendingPathComponent(name))
  }
}
