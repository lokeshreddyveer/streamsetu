#if os(macOS)
import SwiftUI

/// The Mac opening: icons, their names, and the app's own header branding, on pure black, in one continuous story.
///
/// The story is told in design seconds (0 ... `end`) and fitted onto the variant's length, so the full opening and the short cut have the same shape:
///
///     0.00 - 0.40  the first icon-and-name group starts in from the right, fading up to its quiet state
///     0.40 - 4.25  the groups cross the exact centre one at a time, right to left, in order; each is seen alone and lights in the accent as it crosses
///     4.25 - 4.75  once the last has been featured, the icons come in from both sides and converge on the centre; the names fade away
///     4.75 - 5.60  the icons spin as one formation, closing onto the symbol's ring, and become the header symbol (arcs and play triangle)
///     5.60 - 6.15  the symbol's own gesture: a press and settle
///     6.15 - 7.25  the wordmark slides out from behind the symbol through a mask while the pair settles into its centred lockup
///     7.25 - 8.00  the finished identity holds; the coordinator fades it into the prepared app, which shows the same logo in its header
///
/// The short opening (every launch after the first) is a different, simpler thing: the StreamSetu symbol fades in, its arcs turn once with the same eased motion as the header's symbol,
/// and the name slides out from behind it. Squeezing the full story into three seconds read as rushed, so it is not attempted.
///
/// A pure function of time: the same variant and millisecond always give the same frame. Reduce Motion is the finished lockup, still.
struct OpeningMacFrame: Equatable, Sendable {
    /// Seconds into the story: the full story's design seconds (0 ... `OpeningMacStory.end`), or, for the short one, real seconds (0 ... `OpeningMacStory.shortEnd`).
    var t = 0.0
    /// The short opening of every ordinary launch: the app's own symbol and name, like the top bar's, with no icon story.
    var short = false

    static let lockup = OpeningMacFrame(t: OpeningMacStory.end)
}

enum OpeningMacStory {
    /// Where the design's story ends and its hold begins.
    static let end = 7.25

    static let enter = 0.0 ... 0.4
    static let procession = 0.0 ... 4.25
    static let converge = 4.25 ... 4.75
    static let namesFade = 4.25 ... 4.45
    static let spin = 4.75 ... 5.6
    static let gesture = 5.6 ... 6.15
    static let reveal = 6.15 ... 7.25

    /// The short opening, in real seconds: the symbol in, the arcs' one eased turn (the header's motion), the name out from behind the symbol, then the lockup at rest.
    static let shortEnd = 2.65
    static let shortIn = 0.0 ... 0.4, shortTurn = 0.15 ... 1.45, shortReveal = 0.95 ... 1.95

    static func frame(_ v: OpeningVariant, at ms: Double) -> OpeningMacFrame {
        guard v != .reducedMotion, v.holdMs > 0 else { return .lockup }
        if v == .standard { return OpeningMacFrame(t: max(0, min(shortEnd, ms / 1000)), short: true) }
        return OpeningMacFrame(t: max(0, min(end, ms / Double(v.holdMs) * end)))
    }

    static func unit(_ t: Double, _ r: ClosedRange<Double>) -> Double { min(1, max(0, (t - r.lowerBound) / (r.upperBound - r.lowerBound))) }
    static func smooth(_ x: Double) -> Double { x * x * (3 - 2 * x) }
    static func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }

    /// The track's position as it travels: mostly even, with a soft start and a soft stop at the sequence's end.
    static func profile(_ u: Double) -> Double { 0.35 * u + 0.65 * smooth(u) }

    // MARK: layout

    /// Sizes for a stage: groups are spaced so that only one is on stage at a time.
    struct Metrics: Equatable {
        var gap: Double          // distance between group centres on the track
        var side: Double         // icon box
        var entry: Double        // where the first group starts, right of centre
        var total: Double        // how far the track travels so the last group ends at the centre
        var focusRadius: Double
        var ring: Double         // the convergence formation's radius
        var symbol: Double       // the symbol's size when formed (and in the lockup)

        init(size: CGSize, count: Int) {
            let w = Double(size.width), h = Double(size.height)
            let n = Double(max(count, 2))
            // One group is on stage at a time: the gap between groups is wider than the stage's lit window, so the next has not appeared when the last is leaving.
            gap = w * 0.46
            side = min(min(w, h) * 0.115, w * 0.12)
            entry = w * 0.30
            total = entry + (n - 1) * gap
            focusRadius = w * 0.14
            ring = side * 1.7
            symbol = min(min(w, h) * 0.17, w * 0.14)
        }
    }

    /// One group on the track at design time `t`: its offset from the centre, how visible it is, and how strongly the centre's focus is on it.
    struct Group: Equatable { var x: Double; var alpha: Double; var focus: Double }

    static func group(_ i: Int, _ m: Metrics, halfWidth: Double, _ t: Double) -> Group {
        let travel = m.total * profile(unit(t, procession))
        let x = m.entry + Double(i) * m.gap - travel
        // A group is only seen near the middle of the stage: full inside a fifth of the half-width, gone beyond three fifths of it (so only one is ever on stage).
        let full = halfWidth * 0.2, fade = halfWidth * 0.4
        let seen = min(1, max(0, 1 - (abs(x) - full) / fade))
        let alpha = smooth(unit(t, enter)) * smooth(seen)
        let focus = 1 - smooth(min(1, abs(x) / m.focusRadius))
        return Group(x: x, alpha: alpha, focus: focus)
    }

    /// Convergence progress 0 ... 1 and how visible the names still are.
    static func convergence(_ t: Double) -> Double { easeInOut(unit(t, converge)) }
    static func nameAlpha(_ t: Double) -> Double { 1 - smooth(unit(t, namesFade)) }

    /// The formation's angle for icon `i`. The left half of the row goes to the upper half of the ring and the right half to the lower half, each keeping its left-to-right order,
    /// so no icon's path crosses another's on the way in.
    static func ringAngle(_ i: Int, count: Int) -> Double {
        let upper = (count + 1) / 2
        if i < upper { return -.pi + .pi * (Double(i) + 0.5) / Double(upper) }                     // upper half, left to right
        let lower = count - upper
        return .pi - .pi * (Double(i - upper) + 0.5) / Double(max(lower, 1))                       // lower half, left to right
    }

    /// The spin: progress 0 ... 1, the shared rotation (one full turn, so it ends at the symbol's canonical pose), the formation's radius, and each icon's size and visibility.
    struct Spin: Equatable { var u: Double; var angle: Double; var radius: Double; var iconScale: Double; var iconAlpha: Double; var arcs: Double; var triangle: Double }

    static func spin(_ t: Double, _ m: Metrics) -> Spin {
        let u = unit(t, Self.spin)
        let e = easeInOut(u)
        let symbolRadius = EclipseGeometry.radius / EclipseGeometry.canvas * m.symbol
        return Spin(u: u, angle: 2 * .pi * e, radius: m.ring + (symbolRadius - m.ring) * e,
                    iconScale: 1 - 0.62 * smooth(unit(u, 0.0 ... 0.9)),
                    iconAlpha: 1 - smooth(unit(u, 0.68 ... 1.0)),
                    arcs: smooth(unit(u, 0.30 ... 0.85)),
                    triangle: smooth(unit(u, 0.50 ... 1.0)))
    }

    /// The symbol's own gesture: a press of the play triangle and a small breath of the whole mark, both ending exactly at rest.
    static func gestureScales(_ t: Double) -> (mark: Double, triangle: Double) {
        let a = unit(t, gesture)
        return (1 + 0.05 * sin(.pi * a), 1 - 0.14 * sin(.pi * a) * sin(.pi * a) + 0.06 * sin(2 * .pi * a) * (1 - a))
    }

    /// The reveal: 0 (the wordmark entirely behind the symbol) ... 1 (the finished lockup).
    static func revealProgress(_ t: Double) -> Double { easeInOut(unit(t, reveal)) }
}

extension OpeningMacStory {
    /// What the symbol and the wordmark look like at a moment: how visible the whole mark is, how much of its arcs and triangle are formed, the arcs' angle, two small scales, and how far the
    /// wordmark has come out from behind the symbol (0 hidden ... 1 in its place beside it).
    struct SymbolParts: Equatable {
        var opacity = 1.0, arcs = 1.0, triangle = 1.0, angle = 0.0, mark = 1.0, play = 1.0, reveal = 1.0
        var isVisible: Bool { opacity > 0 && (arcs > 0 || triangle > 0) }
    }

    static func parts(_ f: OpeningMacFrame, _ m: Metrics) -> SymbolParts {
        if f.short {
            let into = easeOutQuart(unit(f.t, shortIn))
            let turn = easeInOut(unit(f.t, shortTurn))
            return SymbolParts(opacity: smooth(unit(f.t, shortIn)), arcs: 1, triangle: 1, angle: 2 * .pi * turn, mark: 0.92 + 0.08 * into, play: 1, reveal: easeInOut(unit(f.t, shortReveal)))
        }
        let sp = spin(f.t, m)
        let g = gestureScales(f.t)
        return SymbolParts(opacity: 1, arcs: sp.arcs, triangle: sp.triangle, angle: sp.angle, mark: g.mark, play: g.triangle, reveal: revealProgress(f.t))
    }

    static func easeOutQuart(_ x: Double) -> Double { 1 - pow(1 - x, 4) }
}

enum OpeningMacRenderer {
    private static let black = Color(red: 0, green: 0, blue: 0)
    /// Quiet neutrals on black (the saved theme's own text colours can be dark, so they are not used here).
    static let quietIcon = Color.white.opacity(0.58), quietName = Color.white.opacity(0.46)

    /// The sizes the text is drawn at for a stage, so the pre-rendered text symbols (see OpeningMacCanvas) and the frame agree.
    struct TextSizes { var name: CGFloat; var nameGap: CGFloat; var kk: CGFloat }
    static func textSizes(_ m: OpeningMacStory.Metrics) -> TextSizes {
        let side = CGFloat(m.side)
        return TextSizes(name: max(9, side * 0.27), nameGap: max(6, side * 0.2), kk: CGFloat(m.symbol) / 22)
    }

    /// A pre-rendered piece of text, by id (see `OpeningMacCanvas`): the frame draws it, it never lays text out itself.
    typealias Symbols = (String) -> GraphicsContext.ResolvedSymbol?
    static func nameID(_ i: Int, accent: Bool) -> String { "name.\(accent ? "a" : "q").\(i)" }

    /// The whole frame, on pure black.
    static func draw(_ ctx: inout GraphicsContext, size: CGSize, f: OpeningMacFrame, theme: OpeningTheme, icons: [CGImage], symbols: Symbols) {
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(black))
        let n = min(icons.count, OpeningIcons.symbols.count)
        let m = OpeningMacStory.Metrics(size: size, count: max(n, 2))
        let mid = CGPoint(x: size.width / 2, y: size.height / 2)
        if !f.short, f.t < OpeningMacStory.spin.upperBound, n > 0 { groups(&ctx, size: size, mid: mid, m: m, t: f.t, icons: Array(icons.prefix(n)), theme: theme, symbols: symbols) }
        symbolAndWordmark(&ctx, mid: mid, m: m, parts: OpeningMacStory.parts(f, m), theme: theme, symbols: symbols)
    }

    // MARK: icons and names

    private static func groups(_ ctx: inout GraphicsContext, size: CGSize, mid: CGPoint, m: OpeningMacStory.Metrics, t: Double, icons: [CGImage], theme: OpeningTheme, symbols: Symbols) {
        let n = icons.count
        let ty = textSizes(m)
        let block = m.side + ty.nameGap + ty.name * 1.2                  // icon, gap, name
        let conv = OpeningMacStory.convergence(t)
        let nameA = OpeningMacStory.nameAlpha(t)
        let sp = OpeningMacStory.spin(t, m)
        let halfW = Double(size.width) / 2

        for i in 0..<n {
            let g = OpeningMacStory.group(i, m, halfWidth: halfW, min(t, OpeningMacStory.procession.upperBound))
            // Out of sight: nothing is drawn (a group is only on stage near the middle).
            if g.alpha <= 0.003, t <= OpeningMacStory.converge.lowerBound { continue }
            // The track position, drifting to the formation as the icons converge and then turning with it.
            let rowCentre = CGPoint(x: mid.x + g.x, y: mid.y - block / 2 + m.side / 2)
            let a0 = OpeningMacStory.ringAngle(i, count: n)
            var centre = rowCentre
            var scale = 1.0, alpha = g.alpha, focus = g.focus * (1 - conv), rotation = 0.0
            if t > OpeningMacStory.converge.lowerBound {
                let r = t < OpeningMacStory.spin.lowerBound ? m.ring : sp.radius
                let angle = a0 + (t < OpeningMacStory.spin.lowerBound ? 0 : sp.angle)
                let ringPoint = CGPoint(x: mid.x + cos(angle) * r, y: mid.y + sin(angle) * r)
                // The last group is already at the centre; the others come in from the side they belong to (the left half of the row from the left, the right half from the right).
                let isLast = i == n - 1
                let start = isLast ? rowCentre : CGPoint(x: mid.x + (i < (n + 1) / 2 ? -1 : 1) * (halfW + m.side), y: ringPoint.y)
                centre = CGPoint(x: start.x + (ringPoint.x - start.x) * conv, y: start.y + (ringPoint.y - start.y) * conv)
                alpha = isLast ? g.alpha : OpeningMacStory.smooth(OpeningMacStory.unit(conv, 0 ... 0.35))
                scale = 1 - 0.1 * conv
                if t >= OpeningMacStory.spin.lowerBound { scale = 0.9 * sp.iconScale; alpha *= sp.iconAlpha; rotation = sp.angle }
            }
            guard alpha > 0.003 else { continue }
            scale *= 1 + 0.14 * focus

            let image = icons[i]
            let aspect = Double(image.width) / Double(image.height)
            let box = m.side * scale
            let w = aspect >= 1 ? box : box * aspect, h = aspect >= 1 ? box / aspect : box
            let colour = mix(quietIcon, theme.accent, focus)

            var c = ctx
            c.translateBy(x: centre.x, y: centre.y)
            if rotation != 0 { c.rotate(by: .radians(rotation)) }
            if focus > 0.02 {
                // A bounded glow, and nothing heavy: a soft accent pool behind the icon and a slightly larger, faint copy of the glyph.
                var glow = c
                glow.blendMode = .plusLighter
                glow.fill(Path(ellipseIn: CGRect(x: -box * 1.1, y: -box * 1.1, width: box * 2.2, height: box * 2.2)),
                          with: .radialGradient(Gradient(colors: [theme.accent.opacity(0.36 * focus * alpha), theme.accent.opacity(0.10 * focus * alpha), .clear]), center: .zero, startRadius: 0, endRadius: box * 1.1))
                var halo = glow.resolve(Image(decorative: image, scale: 1).renderingMode(.template))
                halo.shading = .color(theme.accent.opacity(0.30 * focus * alpha))
                glow.draw(halo, in: CGRect(x: -w * 0.6, y: -h * 0.6, width: w * 1.2, height: h * 1.2))
            }
            var resolved = c.resolve(Image(decorative: image, scale: 1).renderingMode(.template))
            resolved.shading = .color(colour.opacity(alpha))
            c.draw(resolved, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))

            // The name travels with its icon on the track (same position) and is gone before the spin; its colour crossfades from quiet to the accent.
            let la = nameA * g.alpha
            if la > 0.003, let quiet = symbols(nameID(i, accent: false)), let lit = symbols(nameID(i, accent: true)) {
                let lc = CGPoint(x: centre.x, y: rowCentre.y + m.side / 2 + ty.nameGap + ty.name * 0.6)
                var l = ctx
                l.opacity = la * (1 - focus)
                l.draw(quiet, at: lc, anchor: .center)
                l.opacity = la * focus
                l.draw(lit, at: lc, anchor: .center)
            }
        }
    }

    // MARK: the symbol and the wordmark

    /// The symbol: the header's two arcs and rounded play triangle (EclipseGeometry), then the wordmark that slides out from behind it through a mask.
    private static func symbolAndWordmark(_ ctx: inout GraphicsContext, mid: CGPoint, m: OpeningMacStory.Metrics, parts: OpeningMacStory.SymbolParts, theme: OpeningTheme, symbols: Symbols) {
        guard parts.isVisible, let stream = symbols("word.stream"), let setu = symbols("word.setu") else { return }
        let kk = textSizes(m).kk                                                  // the header draws the symbol at 22 pt and the wordmark at 20 pt; both scale by this
        let ws = stream.size, wu = setu.size
        let gap = 6 * kk
        let total = m.symbol + gap + ws.width + wu.width

        let r = parts.reveal
        // The symbol starts at the centre and settles to the left of the centred pair as the wordmark comes out.
        let finalCentreX = mid.x - total / 2 + m.symbol / 2
        let symbolCentreX = mid.x + (finalCentreX - mid.x) * r
        let symbolRect = CGRect(x: symbolCentreX - m.symbol / 2, y: mid.y - m.symbol / 2, width: m.symbol, height: m.symbol)

        // The wordmark: its left edge starts at the symbol's centre (hidden behind it) and ends beside it. A mask exposes only what is outside the symbol's front edge.
        if r > 0 {
            let finalLeft = mid.x - total / 2 + m.symbol + gap
            let left = symbolCentreX + (finalLeft - symbolCentreX) * r
            var w = ctx
            w.clip(to: Path(CGRect(x: symbolRect.midX + m.symbol * 0.42, y: 0, width: 10_000, height: 10_000)))
            w.draw(stream, at: CGPoint(x: left, y: mid.y), anchor: .leading)
            w.draw(setu, at: CGPoint(x: left + ws.width, y: mid.y), anchor: .leading)
        }

        // The mark, in front.
        var s = ctx
        s.opacity = parts.opacity
        s.translateBy(x: symbolRect.midX, y: symbolRect.midY)
        s.scaleBy(x: m.symbol / EclipseGeometry.canvas * parts.mark, y: m.symbol / EclipseGeometry.canvas * parts.mark)
        s.translateBy(x: -EclipseGeometry.center.x, y: -EclipseGeometry.center.y)
        var arcs = s
        // The arcs turn with the formation (the angle ends at a full turn, the canonical pose).
        arcs.translateBy(x: EclipseGeometry.center.x, y: EclipseGeometry.center.y)
        arcs.rotate(by: .radians(parts.angle))
        arcs.translateBy(x: -EclipseGeometry.center.x, y: -EclipseGeometry.center.y)
        let line = StrokeStyle(lineWidth: EclipseGeometry.lineWidth * (0.35 + 0.65 * parts.arcs), lineCap: .round)
        arcs.stroke(Path(EclipseGeometry.arc(EclipseGeometry.primary)), with: .color(theme.accent.opacity(parts.arcs)), style: line)
        arcs.stroke(Path(EclipseGeometry.arc(EclipseGeometry.secondary)), with: .color(theme.accent.opacity(EclipseGeometry.secondaryOpacity * parts.arcs)), style: line)
        var play = s
        let ts = (0.4 + 0.6 * parts.triangle) * parts.play
        play.translateBy(x: EclipseGeometry.center.x, y: EclipseGeometry.center.y)
        play.scaleBy(x: ts, y: ts)
        play.translateBy(x: -EclipseGeometry.center.x, y: -EclipseGeometry.center.y)
        play.fill(Path(EclipseGeometry.play()), with: .color(theme.accent.opacity(parts.triangle)))
    }

    private static func mix(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let x = NSColor(a).usingColorSpace(.sRGB) ?? .gray, y = NSColor(b).usingColorSpace(.sRGB) ?? .white
        let ax = x.alphaComponent
        return Color(red: x.redComponent + (y.redComponent - x.redComponent) * t, green: x.greenComponent + (y.greenComponent - x.greenComponent) * t,
                     blue: x.blueComponent + (y.blueComponent - x.blueComponent) * t).opacity(ax + (1 - ax) * t)
    }
}

/// The opening's one Canvas. The text (the names under the icons and the wordmark) is laid out once, as symbols, when the size is known, and each frame only draws it: laying out
/// text sixty times a second was a cost the frame did not need. `frame` is asked for the story's frame at each draw; `onDraw` is told how long the draw took (the watchdog's input).
struct OpeningMacCanvas: View {
    let theme: OpeningTheme
    let icons: [CGImage]
    let frame: () -> OpeningMacFrame
    var onDraw: (Double) -> Void = { _ in }

    var body: some View {
        GeometryReader { geo in
            let m = OpeningMacStory.Metrics(size: geo.size, count: max(min(icons.count, OpeningIcons.symbols.count), 2))
            let ty = OpeningMacRenderer.textSizes(m)
            let ids = OpeningIcons.symbols.indices.flatMap { [OpeningMacRenderer.nameID($0, accent: false), OpeningMacRenderer.nameID($0, accent: true)] } + ["word.stream", "word.setu"]
            Canvas { ctx, size in
                let began = CACurrentMediaTime()
                // The symbols are looked up once for the frame (a lookup, not a layout), so the draw itself never needs the context twice at once.
                var found: [String: GraphicsContext.ResolvedSymbol] = [:]
                for id in ids { if let r = ctx.resolveSymbol(id: id) { found[id] = r } }
                OpeningMacRenderer.draw(&ctx, size: size, f: frame(), theme: theme, icons: icons) { found[$0] }
                onDraw((CACurrentMediaTime() - began) * 1000)
            } symbols: {
                ForEach(Array(OpeningIcons.symbols.enumerated()), id: \.offset) { i, item in
                    Text(item.name).font(.system(size: ty.name, weight: .semibold)).foregroundStyle(OpeningMacRenderer.quietName).tag(OpeningMacRenderer.nameID(i, accent: false))
                    Text(item.name).font(.system(size: ty.name, weight: .semibold)).foregroundStyle(theme.accent).tag(OpeningMacRenderer.nameID(i, accent: true))
                }
                Text("Stream").font(.system(size: 20 * ty.kk, weight: .bold)).tracking(-0.4 * ty.kk).foregroundStyle(.white).tag("word.stream")
                Text("Setu").font(.system(size: 20 * ty.kk, weight: .bold)).tracking(-0.4 * ty.kk).foregroundStyle(theme.accent).tag("word.setu")
            }
        }
    }
}
#endif
