import AppKit
import CoreGraphics
import Foundation

let output = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
    ?? URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for size in [16, 32, 64, 128, 256, 512, 1024] {
    let pixels = size * 4
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: pixels,
        bitsPerPixel: 32
    ), let context = NSGraphicsContext(bitmapImageRep: rep) else { continue }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let inset = CGFloat(size) * 0.06
    let radius = CGFloat(size) * 0.22
    let card = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: radius, yRadius: radius)
    NSColor(calibratedRed: 0.035, green: 0.055, blue: 0.095, alpha: 1).setFill()
    card.fill()

    let center = CGPoint(x: CGFloat(size) / 2, y: CGFloat(size) / 2)
    let ring = NSBezierPath(ovalIn: CGRect(x: CGFloat(size) * 0.22, y: CGFloat(size) * 0.22, width: CGFloat(size) * 0.56, height: CGFloat(size) * 0.56))
    ring.lineWidth = CGFloat(size) * 0.035
    NSColor(calibratedRed: 0.08, green: 0.86, blue: 0.76, alpha: 1).setStroke()
    ring.stroke()

    let bars: [(CGFloat, CGFloat)] = [(-0.22, 0.12), (-0.12, 0.22), (-0.02, 0.36), (0.08, 0.25), (0.18, 0.48)]
    for (offset, height) in bars {
        let width = CGFloat(size) * 0.045
        let barHeight = CGFloat(size) * height
        let bar = NSBezierPath(roundedRect: CGRect(
            x: center.x + CGFloat(size) * offset - width / 2,
            y: center.y - barHeight / 2,
            width: width,
            height: barHeight
        ), xRadius: width / 2, yRadius: width / 2)
        NSColor.white.setFill()
        bar.fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else { continue }
    try data.write(to: output.appendingPathComponent("icon-\(size).png"))
}
