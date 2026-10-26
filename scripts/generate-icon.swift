#!/usr/bin/env swift
import AppKit

// Deterministic vector artwork, rasterized into the sizes expected by macOS.
let destination = URL(fileURLWithPath: "Spark/Assets.xcassets/AppIcon.appiconset")
var entries: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let body = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 196, yRadius: 196)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 28
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        shadow.set()
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        body.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(colors: [NSColor(srgbRed: 0.20, green: 0.22, blue: 0.27, alpha: 1), NSColor(srgbRed: 0.06, green: 0.07, blue: 0.10, alpha: 1)])!.draw(in: body, angle: -70)
        NSColor.white.withAlphaComponent(0.18).setStroke()
        body.lineWidth = 3
        body.stroke()
        // A warm light behind the prompt.
        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        let glow = NSGradient(starting: NSColor(srgbRed: 0.98, green: 0.57, blue: 0.21, alpha: 0.2), ending: .clear)!
        glow.draw(fromCenter: NSPoint(x: 390, y: 520), radius: 0, toCenter: NSPoint(x: 390, y: 520), radius: 490, options: [])
        NSGraphicsContext.restoreGraphicsState()
        let prompt = NSBezierPath()
        prompt.move(to: NSPoint(x: 285, y: 635))
        prompt.line(to: NSPoint(x: 440, y: 505))
        prompt.line(to: NSPoint(x: 285, y: 375))
        prompt.lineWidth = 62
        prompt.lineCapStyle = .round
        prompt.lineJoinStyle = .round
        NSColor(srgbRed: 1, green: 0.74, blue: 0.43, alpha: 1).setStroke()
        prompt.stroke()
        let cursor = NSBezierPath(roundedRect: NSRect(x: 520, y: 345, width: 210, height: 57), xRadius: 28, yRadius: 28)
        NSColor(srgbRed: 1, green: 0.85, blue: 0.65, alpha: 1).setFill()
        cursor.fill()
        let star = NSBezierPath()
        star.move(to: NSPoint(x: 735, y: 800))
        star.curve(to: NSPoint(x: 820, y: 715), controlPoint1: NSPoint(x: 745, y: 735), controlPoint2: NSPoint(x: 755, y: 725))
        star.curve(to: NSPoint(x: 735, y: 630), controlPoint1: NSPoint(x: 755, y: 705), controlPoint2: NSPoint(x: 745, y: 695))
        star.curve(to: NSPoint(x: 650, y: 715), controlPoint1: NSPoint(x: 725, y: 695), controlPoint2: NSPoint(x: 715, y: 705))
        star.curve(to: NSPoint(x: 735, y: 800), controlPoint1: NSPoint(x: 715, y: 725), controlPoint2: NSPoint(x: 725, y: 735))
        star.close()
        NSColor(srgbRed: 1, green: 0.80, blue: 0.54, alpha: 1).setFill()
        star.fill()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)@\(scale)x.png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name))
        entries.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": name])
    }
}
let json: [String: Any] = ["images": entries, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("Contents.json"))
