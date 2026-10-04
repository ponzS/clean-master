import AppKit
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let s = CGFloat(pixels), margin = s * 0.07
        let rect = NSRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
        let shape = NSBezierPath(roundedRect: rect, xRadius: s * 0.20, yRadius: s * 0.20)
        NSGradient(starting: NSColor(red: 0.19, green: 0.76, blue: 0.58, alpha: 1), ending: NSColor(red: 0.06, green: 0.44, blue: 0.37, alpha: 1))!.draw(in: shape, angle: -70)
        let drive = NSBezierPath(roundedRect: NSRect(x: s * 0.24, y: s * 0.29, width: s * 0.52, height: s * 0.43), xRadius: s * 0.06, yRadius: s * 0.06)
        NSColor.white.withAlphaComponent(0.94).setFill(); drive.fill()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: s * 0.31, y: s * 0.43)); line.line(to: NSPoint(x: s * 0.69, y: s * 0.43))
        line.lineWidth = s * 0.025; NSColor(red: 0.10, green: 0.55, blue: 0.43, alpha: 0.35).setStroke(); line.stroke()
        let badge = NSBezierPath(ovalIn: NSRect(x: s * 0.51, y: s * 0.19, width: s * 0.31, height: s * 0.31))
        NSColor(red: 0.06, green: 0.42, blue: 0.32, alpha: 1).setFill(); badge.fill()
        badge.lineWidth = s * 0.02; NSColor.white.setStroke(); badge.stroke()
        let check = NSBezierPath()
        check.move(to: NSPoint(x: s * 0.59, y: s * 0.345)); check.line(to: NSPoint(x: s * 0.64, y: s * 0.295)); check.line(to: NSPoint(x: s * 0.735, y: s * 0.40))
        check.lineWidth = s * 0.027; check.lineCapStyle = .round; check.lineJoinStyle = .round; check.stroke()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name))
    }
}
