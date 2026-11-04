// Renders Resources/AppIcon.icns: concentric soft rings on an indigo→violet squircle.
import AppKit
let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
let path = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.addPath(path); ctx.clip()
let cs = CGColorSpaceCreateDeviceRGB()
let grad = CGGradient(colorsSpace: cs, colors: [CGColor(red: 0.20, green: 0.22, blue: 0.48, alpha: 1),
                                                CGColor(red: 0.42, green: 0.30, blue: 0.70, alpha: 1)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
let c = CGPoint(x: 512, y: 512)
for (i, r) in [300.0, 250, 205].enumerated() {
    let p = CGMutablePath()
    for k in 0...360 {
        let a = Double(k) / 360 * 2 * .pi
        let rr = r + (i == 0 ? 7 * sin(16 * a) : 0)
        let pt = CGPoint(x: c.x + cos(a) * rr, y: c.y + sin(a) * rr)
        if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
    }
    p.closeSubpath()
    ctx.addPath(p)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: [0.85, 0.45, 0.25][i]))
    ctx.setLineWidth([14, 8, 6][i])
    ctx.strokePath()
}
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.92))
ctx.fillEllipse(in: CGRect(x: 512 - 70, y: 512 - 70, width: 140, height: 140))
img.unlockFocus()
let tiff = img.tiffRepresentation!
let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
