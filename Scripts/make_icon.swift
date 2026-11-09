import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else { fatalError("Usage: make_icon.swift output.iconset") }
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
        let context = graphics.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let tile = NSBezierPath(roundedRect: NSRect(x: 58, y: 58, width: 908, height: 908), xRadius: 210, yRadius: 210)
        let forest = NSColor(srgbRed: 0.055, green: 0.09, blue: 0.08, alpha: 1)
        let highlight = NSColor(srgbRed: 0.14, green: 0.24, blue: 0.19, alpha: 1)
        NSGradient(starting: forest, ending: highlight)!.draw(in: tile, angle: 60)
        let lime = NSColor(srgbRed: 0.79, green: 0.94, blue: 0.37, alpha: 1)
        context.setStrokeColor(lime.withAlphaComponent(0.22).cgColor)
        context.setLineWidth(36)
        context.strokeEllipse(in: CGRect(x: 217, y: 217, width: 590, height: 590))
        context.setStrokeColor(lime.cgColor); context.setLineWidth(44); context.setLineCap(.round)
        context.addArc(center: CGPoint(x: 512, y: 512), radius: 295, startAngle: .pi * 0.23, endAngle: .pi * 1.23, clockwise: false)
        context.strokePath()
        context.setStrokeColor(NSColor(srgbRed: 0.95, green: 0.96, blue: 0.88, alpha: 1).cgColor)
        context.setLineWidth(60); context.setLineJoin(.round)
        context.move(to: CGPoint(x: 512, y: 325)); context.addLine(to: CGPoint(x: 512, y: 685))
        context.move(to: CGPoint(x: 382, y: 555)); context.addLine(to: CGPoint(x: 512, y: 685)); context.addLine(to: CGPoint(x: 642, y: 555))
        context.strokePath()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    }
}
