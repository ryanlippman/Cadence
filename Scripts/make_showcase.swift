// Composes the README images from raw app snapshots.
//
//   build/Cadence.app/Contents/MacOS/Cadence --snapshot /tmp/snap
//   swift Scripts/make_showcase.swift /tmp/snap docs/images
//
// Pure CoreGraphics/CoreText (no SwiftUI), so it runs with the Command Line Tools alone.
import AppKit
import CoreGraphics
import CoreText

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: make_showcase.swift <snapshot dir> <out dir>"); exit(1) }
let src = args[1], out = args[2]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func load(_ name: String) -> CGImage {
    let url = URL(fileURLWithPath: "\(src)/\(name).png")
    guard let s = CGImageSourceCreateWithURL(url as CFURL, nil), let i = CGImageSourceCreateImageAtIndex(s, 0, nil) else {
        fatalError("missing \(name).png")
    }
    return i
}

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

/// Canvas in points; rendered at 2× (snapshots are 2× already).
func canvas(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: w * 2, height: h * 2, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: 2, y: 2)
    // flip to top-left origin, like a screen
    ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
    ctx.interpolationQuality = .high
    draw(ctx)
    return ctx.makeImage()!
}

func save(_ img: CGImage, _ name: String) {
    let url = URL(fileURLWithPath: "\(out)/\(name).png")
    let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil)
    CGImageDestinationFinalize(d)
    print("wrote \(url.path)")
}

/// Draws an image with top-left origin at `r` (the context is flipped).
func drawImage(_ ctx: CGContext, _ img: CGImage, _ r: CGRect) {
    ctx.saveGState()
    ctx.translateBy(x: r.minX, y: r.maxY); ctx.scaleBy(x: 1, y: -1)
    ctx.draw(img, in: CGRect(origin: .zero, size: r.size))
    ctx.restoreGState()
}

func glow(_ ctx: CGContext, _ c: CGPoint, _ radius: CGFloat, _ color: CGColor) {
    let g = CGGradient(colorsSpace: nil, colors: [color, color.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
}

/// Deep indigo backdrop with soft colour fields in the three mode tints.
func backdrop(_ ctx: CGContext, _ w: CGFloat, _ h: CGFloat) {
    let g = CGGradient(colorsSpace: nil, colors: [rgb(0.07, 0.07, 0.16), rgb(0.12, 0.09, 0.25), rgb(0.04, 0.13, 0.17)] as CFArray,
                       locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
    glow(ctx, CGPoint(x: w * 0.78, y: h * 0.38), w * 0.42, rgb(0.42, 0.48, 0.95, 0.42))
    glow(ctx, CGPoint(x: w * 0.12, y: h * 1.0), w * 0.38, rgb(0.25, 0.70, 0.62, 0.30))
    glow(ctx, CGPoint(x: w * 0.30, y: h * 0.0), w * 0.30, rgb(0.58, 0.45, 0.85, 0.30))
}

/// macOS-style window: rounded corners, hairline border, traffic lights, deep shadow.
func window(_ ctx: CGContext, _ img: CGImage, at origin: CGPoint, scale: CGFloat = 0.5, titleBar: CGFloat = 0,
            dark: Bool = true, radius: CGFloat = 12, lights: Bool = true) {
    let size = CGSize(width: CGFloat(img.width) * scale, height: CGFloat(img.height) * scale + titleBar)
    let frame = CGRect(origin: origin, size: size)
    let path = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
    // shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 26), blur: 60, color: rgb(0, 0, 0, 0.55))
    ctx.addPath(path); ctx.setFillColor(dark ? rgb(0.12, 0.12, 0.13) : rgb(0.96, 0.96, 0.96)); ctx.fillPath()
    ctx.restoreGState()
    // content
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    if titleBar > 0 {
        ctx.setFillColor(dark ? rgb(0.16, 0.16, 0.17) : rgb(0.92, 0.92, 0.93))
        ctx.fill(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: titleBar))
    }
    drawImage(ctx, img, CGRect(x: frame.minX, y: frame.minY + titleBar, width: frame.width, height: frame.height - titleBar))
    ctx.restoreGState()
    // border
    ctx.addPath(CGPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setStrokeColor(dark ? rgb(1, 1, 1, 0.14) : rgb(0, 0, 0, 0.12)); ctx.setLineWidth(1); ctx.strokePath()
    guard lights else { return }
    let y = frame.minY + (titleBar > 0 ? titleBar / 2 : 20)
    for (i, c) in [rgb(1, 0.37, 0.34), rgb(1, 0.74, 0.18), rgb(0.16, 0.79, 0.25)].enumerated() {
        let r = CGRect(x: frame.minX + 14 + CGFloat(i) * 20, y: y - 6, width: 12, height: 12)
        ctx.setFillColor(c); ctx.fillEllipse(in: r)
        ctx.setStrokeColor(rgb(0, 0, 0, 0.18)); ctx.setLineWidth(0.5); ctx.strokeEllipse(in: r.insetBy(dx: 0.25, dy: 0.25))
    }
}

enum Face { case serif, serifRegular, sans, sansMedium }
/// System faces: New York (serif) and SF Pro, as in the app.
func font(_ face: Face, _ size: CGFloat) -> CTFont {
    let weight: NSFont.Weight = face == .serif ? .medium : (face == .sansMedium ? .medium : .regular)
    var d = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
    if face == .serif || face == .serifRegular, let s = d.withDesign(.serif) { d = s }
    return NSFont(descriptor: d, size: size)! as CTFont
}

/// Draws text with its top-left at `p`.
func text(_ ctx: CGContext, _ s: String, _ p: CGPoint, _ f: CTFont, _ color: CGColor) {
    let attr = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: color])
    let line = CTLineCreateWithAttributedString(attr)
    ctx.saveGState()
    ctx.textMatrix = .identity
    ctx.translateBy(x: p.x, y: p.y + CTFontGetAscent(f)); ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

func width(_ s: String, _ f: CTFont) -> CGFloat {
    CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: f])), nil, nil, nil))
}

let serif = Face.serif, serifReg = Face.serifRegular, sans = Face.sans

let mainDark = load("main-dark"), mainLight = load("main-light")
let menuDark = load("menubar-dark")
let settingsDark = load("settings-dark"), settingsLight = load("settings-light")
let artwork = load("artwork-dark"), sheet = load("artwork-sheet")

// 1. Hero
save(canvas(1600, 900) { ctx in
    backdrop(ctx, 1600, 900)
    text(ctx, "Cadence", CGPoint(x: 110, y: 150), font(serif, 96), rgb(1, 1, 1))
    text(ctx, "Endless original piano music,", CGPoint(x: 112, y: 280), font(serifReg, 36), rgb(1, 1, 1, 0.82))
    text(ctx, "composed as you listen.", CGPoint(x: 112, y: 328), font(serifReg, 36), rgb(1, 1, 1, 0.82))
    let bullets = ["Four styles, never the same piece twice", "Rhythmic modulation for focus, relax and sleep",
                   "Eases you in, then stays out of the way", "Native macOS · fully offline · no account"]
    for (i, b) in bullets.enumerated() {
        let y = 428 + CGFloat(i) * 42
        ctx.setFillColor(rgb(0.62, 0.66, 1)); ctx.fillEllipse(in: CGRect(x: 116, y: y + 9, width: 8, height: 8))
        text(ctx, b, CGPoint(x: 140, y: y), font(sans, 22), rgb(1, 1, 1, 0.78))
    }
    // the current piece's cover, as a small "now playing" card
    window(ctx, artwork, at: CGPoint(x: 112, y: 630), scale: 0.1, radius: 12, lights: false)
    text(ctx, "Now playing", CGPoint(x: 260, y: 650), font(.sansMedium, 15), rgb(0.62, 0.66, 1))
    text(ctx, "A new name and cover for every piece", CGPoint(x: 260, y: 676), font(sans, 20), rgb(1, 1, 1, 0.82))
    text(ctx, "shown in the window, menu bar and Control Centre", CGPoint(x: 260, y: 706), font(sans, 16), rgb(1, 1, 1, 0.55))
    window(ctx, menuDark, at: CGPoint(x: 800, y: 500), scale: 0.5, lights: false)
    window(ctx, mainDark, at: CGPoint(x: 1080, y: 130), scale: 0.5)
}, "hero")

// 2. Light & dark
save(canvas(1200, 860) { ctx in
    let g = CGGradient(colorsSpace: nil, colors: [rgb(0.84, 0.86, 0.97), rgb(0.55, 0.52, 0.80), rgb(0.10, 0.09, 0.22)] as CFArray,
                       locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 1200, y: 860), options: [])
    window(ctx, mainLight, at: CGPoint(x: 155, y: 110), dark: false)
    window(ctx, mainDark, at: CGPoint(x: 625, y: 110))
}, "light-dark")

// 3. Settings
save(canvas(1300, 820) { ctx in
    backdrop(ctx, 1300, 820)
    window(ctx, settingsLight, at: CGPoint(x: 110, y: 96), titleBar: 28, dark: false)
    window(ctx, settingsDark, at: CGPoint(x: 690, y: 96), titleBar: 28)
}, "settings")

// 4. Covers
let sw = CGFloat(sheet.width) / 2, sh = CGFloat(sheet.height) / 2
let cw = max(sw + 160, 1000)
save(canvas(Int(cw), Int(sh + 210)) { ctx in
    backdrop(ctx, cw, sh + 210)
    let t1 = "Every piece gets its own name and cover", t2 = "Style sets the picture · mode sets the colour family · key turns the hue"
    text(ctx, t1, CGPoint(x: (cw - width(t1, font(serif, 34))) / 2, y: 50), font(serif, 34), rgb(1, 1, 1))
    text(ctx, t2, CGPoint(x: (cw - width(t2, font(sans, 18))) / 2, y: 102), font(sans, 18), rgb(1, 1, 1, 0.6))
    window(ctx, sheet, at: CGPoint(x: (cw - sw) / 2, y: 160), radius: 14, lights: false)
}, "covers")
