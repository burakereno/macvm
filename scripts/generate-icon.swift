import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("MacVM.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let background = NSBezierPath(roundedRect: NSRect(x: 54, y: 54, width: 916, height: 916), xRadius: 212, yRadius: 212)
        NSGradient(starting: NSColor(calibratedRed: 1, green: 0.72, blue: 0.34, alpha: 1), ending: NSColor(calibratedRed: 0.89, green: 0.29, blue: 0.13, alpha: 1))!.draw(in: background, angle: -75)
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.shadowBlurRadius = 32; shadow.shadowOffset = NSSize(width: 0, height: -18)
        shadow.set()
        let back = NSBezierPath(roundedRect: NSRect(x: 252, y: 368, width: 555, height: 409), xRadius: 65, yRadius: 65)
        NSColor.white.withAlphaComponent(0.4).setFill(); back.fill()
        let front = NSBezierPath(roundedRect: NSRect(x: 187, y: 253, width: 596, height: 443), xRadius: 66, yRadius: 66)
        NSColor(calibratedWhite: 0.99, alpha: 0.96).setFill(); front.fill()
        NSShadow().set()
        let screen = NSBezierPath(roundedRect: NSRect(x: 218, y: 285, width: 534, height: 315), xRadius: 35, yRadius: 35)
        NSColor(calibratedRed: 0.19, green: 0.22, blue: 0.26, alpha: 1).setFill(); screen.fill()
        for x in [242, 280, 318] {
            NSColor(calibratedWhite: 0.7, alpha: 0.8).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: 638, width: 19, height: 19)).fill()
        }
        let arrow = NSBezierPath(); arrow.move(to: NSPoint(x: 427, y: 361))
        arrow.line(to: NSPoint(x: 427, y: 523)); arrow.line(to: NSPoint(x: 561, y: 442)); arrow.close()
        NSColor(calibratedRed: 1, green: 0.68, blue: 0.32, alpha: 1).setFill(); arrow.fill()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
