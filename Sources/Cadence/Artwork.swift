import AppKit
import CoreGraphics
import CadenceCore

/// One generated piece (a movement): its title and procedurally generated cover art.
/// Everything is derived deterministically from the movement number, key, style and mode, so the
/// same piece always gets the same cover, and every new piece gets a new one.
struct PieceIdentity: Equatable {
    var movement: Int
    var keyName: String
    var style: CompositionStyle
    var mode: FocusMode
    /// Random per launch, so piece 1 of today differs from piece 1 of yesterday.
    var salt: UInt64 = 0
    /// Bumped when a generated name was already used, to pick a fresh one.
    var attempt = 0

    /// e.g. "Nocturne in E♭ major"
    var subtitle: String { "\(form) in \(keyName)" }

    /// A unique, evocative name, e.g. "Lanterns on Still Water".
    var name: String {
        var r = seed ^ (UInt64(attempt) &* 0x9E3779B97F4A7C15)
        func pick(_ a: [String]) -> String {
            r ^= r << 13; r ^= r >> 7; r ^= r << 17
            return a[Int(r % UInt64(a.count))]
        }
        let adj: [String]
        let noun: [String]
        switch mode {
        case .focus:
            adj = ["Clear", "Quiet", "Steady", "Bright", "Patient", "Open", "Even", "Silver", "Morning", "Gentle", "Lucid", "Level",
                   "Northern", "Still", "Careful", "Glass", "Paper", "Cedar", "Slate", "Linen"]
            noun = ["Lantern", "Current", "Meridian", "Compass", "Window", "Orchard", "Harbour", "Lighthouse", "Library", "Path",
                    "Desk", "Horizon", "Thread", "Field", "Bridge", "River", "Atlas", "Workshop", "Garden", "Signal"]
        case .relax:
            adj = ["Soft", "Warm", "Drifting", "Golden", "Slow", "Velvet", "Amber", "Mellow", "Hazy", "Tender", "Sunlit", "Low",
                   "Willow", "Honeyed", "Easy", "Rose", "Faded", "Summer", "Coastal", "Wandering"]
            noun = ["Afternoon", "Tide", "Meadow", "Cloud", "Shore", "Breeze", "Porch", "Lagoon", "Hammock", "Hill", "Garden",
                    "Orchard", "Lake", "Veranda", "Dune", "Valley", "Wheatfield", "Sail", "Rain", "Pond"]
        case .sleep:
            adj = ["Distant", "Hushed", "Midnight", "Moonlit", "Fading", "Sleeping", "Starlit", "Dim", "Deep", "Velvet", "Silent",
                   "Folded", "Blue", "Last", "Snowbound", "Sheltered", "Dreaming", "Long", "Quiet", "Evening"]
            noun = ["Lantern", "Snow", "Ember", "Owl", "Nightfall", "Harbour", "Candle", "Constellation", "Lake", "Moon", "Pine",
                    "Attic", "Blanket", "Lullaby", "Tide", "Window", "Cottage", "Hearth", "Feather", "Cloud"]
        }
        let place = ["Still Water", "the Hill", "the Window", "the Garden", "the Shore", "Evening", "the Valley", "the Sea",
                     "the Field", "Morning", "the Lake", "Snowfall", "the River", "the Pines", "Rain", "the Harbour"]
        let plural = { (w: String) -> String in
            w.hasSuffix("s") || w.hasSuffix("sh") ? w + "es" : (w.hasSuffix("y") && !w.hasSuffix("ay") ? String(w.dropLast()) + "ies" : w + "s")
        }
        switch Int(r % 5) {
        case 0: return "\(pick(adj)) \(pick(noun))"
        case 1: return "\(plural(pick(noun))) on \(pick(place))"
        case 2: return "The \(pick(adj)) \(pick(noun))"
        case 3: return "\(pick(adj)) \(plural(pick(noun)))"
        default: return "\(pick(noun)) by \(pick(place))"
        }
    }

    private var form: String {
        let forms: [String]
        switch style {
        case .minimalist: forms = ["Study", "Pattern", "Drift", "Still Life"]
        case .impressionist: forms = ["Reverie", "Image", "Pastel", "Mist"]
        case .romantic: forms = ["Nocturne", "Romance", "Song Without Words", "Intermezzo"]
        case .baroque: forms = ["Prelude", "Invention", "Air", "Sinfonia"]
        }
        return forms[Int(seed % UInt64(forms.count))]
    }

    /// Stable FNV-1a hash (Swift's `hashValue` is randomised per launch).
    var seed: UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in "\(salt)|\(movement)|\(keyName)|\(style.rawValue)|\(mode.rawValue)".utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
}

/// Remembers names already given, so no two pieces ever share one (kept across launches).
@MainActor
enum PieceNames {
    private static let key = "cadence.pieceNames.v1"
    private static var used: [String] = UserSettings.persistenceEnabled ? (UserDefaults.standard.stringArray(forKey: key) ?? []) : []

    /// Returns `piece` with `attempt` chosen so that its name has not been used before, and records it.
    static func claim(_ piece: PieceIdentity) -> PieceIdentity {
        var p = piece
        let set = Set(used)
        while set.contains(p.name) && p.attempt < 64 { p.attempt += 1 }
        used.append(p.name)
        if used.count > 3000 { used.removeFirst(used.count - 3000) }
        if UserSettings.persistenceEnabled { UserDefaults.standard.set(used, forKey: key) }
        return p
    }
}

enum Artwork {
    private static var cache: [UInt64: NSImage] = [:]

    static func image(for piece: PieceIdentity, size: Int = 600) -> NSImage {
        let key = piece.seed ^ UInt64(size) ^ UInt64(piece.attempt)
        if let c = cache[key] { return c }
        guard let cg = render(piece, size: size) else { return NSImage() }
        let img = NSImage(cgImage: cg, size: NSSize(width: size, height: size))
        if cache.count > 24 { cache.removeAll() }
        cache[key] = img
        return img
    }

    // MARK: drawing

    private struct RNG {
        var s: UInt64
        mutating func next() -> Double {
            s ^= s << 13; s ^= s >> 7; s ^= s << 17
            return Double(s >> 11) / Double(1 << 53)
        }
        mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
    }

    private static func hsb(_ h: Double, _ s: Double, _ b: Double, _ a: Double = 1) -> CGColor {
        let c = NSColor(hue: CGFloat((h.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)),
                        saturation: CGFloat(s), brightness: CGFloat(b), alpha: CGFloat(a))
        return c.cgColor
    }

    private static func baseHue(_ mode: FocusMode) -> Double {
        switch mode { case .focus: return 0.64; case .relax: return 0.47; case .sleep: return 0.74 }
    }

    static func render(_ p: PieceIdentity, size: Int) -> CGImage? {
        let W = CGFloat(size)
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var r = RNG(s: (p.seed ^ (UInt64(p.attempt) &* 0x2545F4914F6CDD1D)) | 1)
        for _ in 0..<4 { _ = r.next() }
        let minor = p.keyName.contains("minor") || p.keyName.contains("dorian")
        // hue: mode sets the family, the key turns it a little (circle-of-fifths neighbours stay close)
        let tonicIndex = ["C", "G", "D", "A", "E", "B", "F♯", "C♯", "G♯", "D♭", "A♭", "E♭", "B♭", "F"]
            .firstIndex { p.keyName.hasPrefix($0 + " ") } ?? 0
        let hue = baseHue(p.mode) + (Double(tonicIndex) - 6) * 0.012 + r.range(-0.03, 0.03)
        let dark = p.mode == .sleep ? 0.22 : (minor ? 0.34 : 0.42)
        let light = p.mode == .sleep ? 0.45 : (minor ? 0.7 : 0.86)

        // background gradient
        let bg = CGGradient(colorsSpace: nil, colors: [hsb(hue + 0.04, 0.55, light), hsb(hue - 0.05, 0.75, dark)] as CFArray,
                            locations: [0, 1])!
        let angle = r.range(0, 2 * .pi)
        let reach = W * 0.71   // half the diagonal, so the gradient spans the whole square
        ctx.drawLinearGradient(bg, start: CGPoint(x: W / 2 + cos(angle) * reach, y: W / 2 + sin(angle) * reach),
                               end: CGPoint(x: W / 2 - cos(angle) * reach, y: W / 2 - sin(angle) * reach),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

        switch p.style {
        case .minimalist: minimalist(ctx, W, &r, hue, light)
        case .impressionist: impressionist(ctx, W, &r, hue)
        case .romantic: romantic(ctx, W, &r, hue, light)
        case .baroque: baroque(ctx, W, &r, hue, light)
        }

        // soft vignette for depth
        let vg = CGGradient(colorsSpace: nil, colors: [hsb(0, 0, 0, 0), hsb(hue, 0.6, 0.08, 0.35)] as CFArray, locations: [0.55, 1])!
        ctx.drawRadialGradient(vg, startCenter: CGPoint(x: W / 2, y: W / 2), startRadius: 0,
                               endCenter: CGPoint(x: W / 2, y: W / 2), endRadius: W * 0.75, options: [.drawsAfterEndLocation])
        return ctx.makeImage()
    }

    /// A single soft sun and a few thin concentric rings: lots of space.
    private static func minimalist(_ ctx: CGContext, _ W: CGFloat, _ r: inout RNG, _ hue: Double, _ light: Double) {
        let c = CGPoint(x: W * r.range(0.32, 0.68), y: W * r.range(0.32, 0.68))
        let rad = W * r.range(0.14, 0.24)
        let g = CGGradient(colorsSpace: nil, colors: [hsb(hue + 0.08, 0.25, 1, 0.9), hsb(hue + 0.08, 0.3, 1, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: rad * 1.6, options: [])
        ctx.setLineWidth(W * 0.003)
        let rings = 3 + Int(r.next() * 4)
        for k in 1...rings {
            ctx.setStrokeColor(hsb(hue, 0.15, 1, 0.35 - Double(k) * 0.04))
            let rr = rad * (1.3 + CGFloat(k) * CGFloat(r.range(0.28, 0.42)))
            ctx.strokeEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
        }
        // horizon line
        ctx.setStrokeColor(hsb(hue, 0.1, 1, 0.25))
        let y = W * r.range(0.18, 0.3)
        ctx.move(to: CGPoint(x: W * 0.1, y: y)); ctx.addLine(to: CGPoint(x: W * 0.9, y: y)); ctx.strokePath()
    }

    /// Overlapping translucent washes of colour, like watercolour.
    private static func impressionist(_ ctx: CGContext, _ W: CGFloat, _ r: inout RNG, _ hue: Double) {
        for _ in 0..<26 {
            let c = CGPoint(x: W * r.next(), y: W * r.next())
            let rad = W * r.range(0.08, 0.32)
            let h = hue + r.range(-0.12, 0.16)
            let g = CGGradient(colorsSpace: nil, colors: [hsb(h, r.range(0.3, 0.7), r.range(0.7, 1), r.range(0.18, 0.4)),
                                                          hsb(h, 0.5, 0.9, 0)] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: rad, options: [])
        }
        // a few light dabs
        for _ in 0..<40 {
            let c = CGPoint(x: W * r.next(), y: W * r.next())
            let rad = W * r.range(0.004, 0.012)
            ctx.setFillColor(hsb(hue + 0.1, 0.1, 1, r.range(0.25, 0.6)))
            ctx.fillEllipse(in: CGRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2))
        }
    }

    /// Flowing ribbons: layered waves sweeping across the cover.
    private static func romantic(_ ctx: CGContext, _ W: CGFloat, _ r: inout RNG, _ hue: Double, _ light: Double) {
        let ribbons = 7
        let f1 = r.range(1.2, 2.4), f2 = r.range(2.5, 4.5), phase = r.range(0, 6.28)
        for k in 0..<ribbons {
            let t = Double(k) / Double(ribbons - 1)
            let yBase = W * CGFloat(0.25 + 0.5 * t)
            let amp = W * CGFloat(r.range(0.05, 0.12))
            let path = CGMutablePath()
            let steps = 80
            for s in 0...steps {
                let x = W * CGFloat(s) / CGFloat(steps)
                let u = Double(s) / Double(steps)
                let y = yBase + amp * CGFloat(sin(2 * .pi * f1 * u + phase + t * 1.4) * 0.7 + sin(2 * .pi * f2 * u + t * 3) * 0.3)
                s == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
            }
            ctx.addPath(path)
            ctx.setLineWidth(W * CGFloat(0.006 + 0.02 * (1 - abs(t - 0.5) * 2)))
            ctx.setLineCap(.round)
            ctx.setStrokeColor(hsb(hue + 0.05 + t * 0.08, 0.35, 1, 0.16 + 0.22 * (1 - abs(t - 0.5) * 2)))
            ctx.strokePath()
        }
        // a moon
        let c = CGPoint(x: W * r.range(0.6, 0.82), y: W * r.range(0.68, 0.84))
        let rad = W * 0.06
        ctx.setFillColor(hsb(hue + 0.12, 0.12, 1, 0.75))
        ctx.fillEllipse(in: CGRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2))
    }

    /// Interlaced geometry: a rosette of overlapping circles (counterpoint made visible).
    private static func baroque(_ ctx: CGContext, _ W: CGFloat, _ r: inout RNG, _ hue: Double, _ light: Double) {
        let c = CGPoint(x: W / 2, y: W / 2)
        let petals = [6, 8, 10, 12][Int(r.next() * 4)]
        let rad = W * CGFloat(r.range(0.16, 0.22))
        let rot = r.range(0, .pi)
        ctx.setLineWidth(W * 0.0035)
        for ring in 0..<2 {
            let dist = rad * (ring == 0 ? 1 : 1.75)
            for k in 0..<petals {
                let a = rot + Double(k) / Double(petals) * 2 * .pi + (ring == 1 ? .pi / Double(petals) : 0)
                let pc = CGPoint(x: c.x + CGFloat(cos(a)) * dist, y: c.y + CGFloat(sin(a)) * dist)
                ctx.setStrokeColor(hsb(hue + 0.08 + Double(ring) * 0.05, 0.25, 1, ring == 0 ? 0.5 : 0.28))
                ctx.strokeEllipse(in: CGRect(x: pc.x - rad, y: pc.y - rad, width: rad * 2, height: rad * 2))
            }
        }
        ctx.setStrokeColor(hsb(hue + 0.1, 0.2, 1, 0.45))
        ctx.strokeEllipse(in: CGRect(x: c.x - rad * 2.75, y: c.y - rad * 2.75, width: rad * 5.5, height: rad * 5.5))
        let g = CGGradient(colorsSpace: nil, colors: [hsb(hue + 0.1, 0.2, 1, 0.55), hsb(hue, 0.3, 1, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: rad * 0.9, options: [])
    }
}
