import SwiftUI
import CoreGraphics
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

/// The opening's colours (motion/specification/design-tokens.json): teal and cream only, on a near-black deep teal.
enum OpeningColors {
    static let background = Color(hex: 0x04090D)
    static let backgroundGlow = Color(hex: 0x0A2A33)
    static let teal = Color(hex: 0x1FA7B8)
    static let iceTeal = Color(hex: 0x8FD8E3)
    static let silver = Color(hex: 0xC9D2DA)
    static let cream = Color(hex: 0xF2EEE6)
    static let foreground = Color(hex: 0xF5F7FC)
    static let foregroundSecondary = Color(hex: 0x9AA4AE)
}

/// The opening's geometry on its 1000 x 600 artboard. The television's layers share one 1024 x 1024 canvas
/// (motion/assets/tune-in/manifest.json), placed in `markRect`; `at` turns a canvas pixel into an artboard point.
enum OpeningGeometry {
    static let markRect = CGRect(x: 335, y: 105, width: 330, height: 330)
    static let markCentre = CGPoint(x: 500, y: 270)
    static let wordmarkBaseline: CGFloat = 478
    static let taglineBaseline: CGFloat = 520
    static let canvas: CGFloat = 1024
    static var unit: CGFloat { markRect.width / canvas }

    static func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: markRect.minX + x * unit, y: markRect.minY + y * unit) }

    /// From the manifest: the antennas' pivots, the play button's centre, the screen window, and the ribbon's centre line with its widths.
    static let pivotLeft = at(454.5, 222.0)
    static let pivotRight = at(529.4, 226.0)
    static let play = at(501.6, 501.3)
    static let screen = CGRect(origin: at(175, 264), size: CGSize(width: (857 - 175) * unit, height: (833 - 264) * unit))
    static let screenShape = Path(roundedRect: screen, cornerRadius: 125 * unit, style: .continuous)

    static let ribbonLine: [(CGPoint, CGFloat)] = {
        let points: [(CGFloat, CGFloat)] = [(884.9, 334.1), (895.2, 353.2), (903.8, 373.0), (910.3, 393.4), (915.5, 414.4), (919.9, 435.9), (924.1, 458.1),
            (932.0, 463.6), (943.1, 461.8), (953.6, 458.9), (954.0, 511.4), (936.0, 547.3), (908.2, 578.2), (876.2, 605.1), (840.8, 627.3), (803.2, 646.1),
            (764.9, 663.2), (725.5, 677.7), (685.6, 690.5), (645.1, 701.8), (604.5, 712.5), (564.0, 723.1), (522.8, 731.4), (481.6, 739.4), (440.5, 747.8),
            (399.0, 754.4), (357.6, 761.0), (316.6, 770.0), (275.7, 779.4), (235.2, 790.3), (195.1, 802.7), (157.6, 821.4), (122.0, 843.3), (93.3, 871.9)]
        let widths: [CGFloat] = [1.0, 19.5, 39.7, 60.6, 81.0, 99.4, 114.7, 92.3, 50.3, 8.0, 67.9, 46.8, 89.5, 109.5, 125.9, 127.2, 133.2, 134.5, 135.8,
                                 135.9, 132.9, 131.7, 132.2, 130.3, 130.1, 131.1, 127.9, 127.1, 124.4, 123.3, 111.2, 107.8, 103.5, 85.4]
        return zip(points, widths).map { (at($0.0, $0.1), $1 * unit) }
    }()
    /// The rear segment runs to the split (index 9); the front from the split to the free tail.
    static let rearLine = Array(ribbonLine[0...9])
    static let frontLine = Array(ribbonLine[9...])

    /// The part of a centre line drawn so far, as a band wide enough to hold the ribbon and its glow. Drawn as overlapping round-capped
    /// pieces, so the wipe moves on continuously, also across the split between the rear and front segments.
    static func band(_ line: [(CGPoint, CGFloat)], _ progress: Double) -> Path {
        var lengths: [CGFloat] = [0]
        for i in 1..<line.count { lengths.append(lengths[i - 1] + hypot(line[i].0.x - line[i - 1].0.x, line[i].0.y - line[i - 1].0.y)) }
        let reach = lengths.last! * CGFloat(min(1, max(0, progress)))
        var path = Path()
        guard reach > 0 else { return path }
        for i in 1..<line.count where lengths[i - 1] < reach {
            let a = line[i - 1].0, b = line[i].0
            let f = min(1, (reach - lengths[i - 1]) / max(0.001, lengths[i] - lengths[i - 1]))
            let end = CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
            var seg = Path(); seg.move(to: a); seg.addLine(to: end)
            let width = max(line[i - 1].1, line[i].1) * 1.45 + 6
            path.addPath(seg.strokedPath(StrokeStyle(lineWidth: width, lineCap: .round)))
        }
        return path
    }

    /// A centre line's wipe with its stroked pieces made once: each frame only appends the finished pieces and strokes the one in progress.
    final class Band: @unchecked Sendable {
        private let line: [(CGPoint, CGFloat)]
        private let lengths: [CGFloat]
        private let pieces: [Path]
        init(_ line: [(CGPoint, CGFloat)]) {
            self.line = line
            var l: [CGFloat] = [0]
            for i in 1..<line.count { l.append(l[i - 1] + hypot(line[i].0.x - line[i - 1].0.x, line[i].0.y - line[i - 1].0.y)) }
            lengths = l
            pieces = (1..<line.count).map { i in Band.piece(line[i - 1].0, line[i].0, max(line[i - 1].1, line[i].1)) }
        }
        private static func piece(_ a: CGPoint, _ b: CGPoint, _ w: CGFloat) -> Path {
            var seg = Path(); seg.move(to: a); seg.addLine(to: b)
            return seg.strokedPath(StrokeStyle(lineWidth: w * 1.45 + 6, lineCap: .round))
        }
        func path(_ progress: Double) -> Path {
            let reach = lengths.last! * CGFloat(min(1, max(0, progress)))
            var path = Path()
            guard reach > 0 else { return path }
            for i in 1..<line.count where lengths[i - 1] < reach {
                if lengths[i] <= reach { path.addPath(pieces[i - 1]); continue }
                let a = line[i - 1].0, b = line[i].0
                let f = (reach - lengths[i - 1]) / max(0.001, lengths[i] - lengths[i - 1])
                path.addPath(Band.piece(a, CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f), max(line[i - 1].1, line[i].1)))
            }
            return path
        }
    }
    static let rearBand = Band(rearLine)
    static let frontBand = Band(frontLine)
    static let ribbonBand = Band(ribbonLine)

    /// The point `fraction` of the way along a centre line.
    static func point(_ line: [(CGPoint, CGFloat)], _ fraction: Double) -> CGPoint {
        var total: CGFloat = 0
        for i in 1..<line.count { total += hypot(line[i].0.x - line[i - 1].0.x, line[i].0.y - line[i - 1].0.y) }
        var left = total * CGFloat(min(1, max(0, fraction)))
        for i in 1..<line.count {
            let a = line[i - 1].0, b = line[i].0, l = hypot(b.x - a.x, b.y - a.y)
            if left <= l { let f = left / max(0.001, l); return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f) }
            left -= l
        }
        return line.last!.0
    }
}

/// The television's layers (motion/assets/tune-in), never redrawn or distorted. The Mac release copies them into the app's Resources as
/// TuneIn-<layer>.png and a development build reads them from the repository; the iPhone app has them in its asset catalogue.
///
/// The layers are decoded and shrunk to the size they are drawn at exactly once per process, off the main thread (`preload`), and held as
/// bitmaps. A frame never decodes, looks up or scales an image; until the layers are ready the opening draws only its dark background.
struct OpeningArt {
    var ribbonRear, screen, antennaLeft, antennaRight, tvBody, playButton, ribbonFront, sweepMask, glintMask: Image?
    /// The single brand symbol, used only if the layers are missing.
    var fallback: Image?
    /// The layers have been looked for (found or not). Before that a frame draws nothing but the background.
    var isReady = true

    var isLayered: Bool { tvBody != nil && screen != nil && playButton != nil && ribbonFront != nil }

    static let layerNames = ["ribbon-rear", "screen", "antenna-left", "antenna-right", "tv-body", "play-button", "ribbon-front", "sweep-mask", "glint-mask"]
    /// The longest side the layers are kept at: the television is at most about 210 points wide on a phone (630 px at scale 3).
    #if os(macOS)
    static let maxPixel = 1024
    #else
    static let maxPixel = 640
    #endif

    /// Not yet decoded.
    static let pending = OpeningArt(isReady: false)
    private static let store = Locked<OpeningArt?>(nil)
    /// How many times the layers were decoded in this process (a test asserts it stays at one).
    nonisolated(unsafe) static var decodeCount = 0

    /// The layers, once decoded; `pending` until then. Cheap: no decoding, safe to call every frame.
    static var current: OpeningArt { store.value ?? .pending }

    /// Decodes the layers once, off the main thread. Calling it again does nothing.
    static func preload() {
        guard store.value == nil, !preloading.swap(true) else { return }
        Task.detached(priority: .userInitiated) { _ = loadNow() }
    }
    private static let preloading = Locked(false)

    /// Decodes now (the caller waits) and keeps the result; later calls return it.
    @discardableResult static func loadNow(maxPixel: Int = OpeningArt.maxPixel) -> OpeningArt {
        if let done = store.value { return done }
        decodeCount += 1
        var images: [String: Image] = [:]
        for name in layerNames {
            if let cg = source(name).flatMap({ downscaled($0, maxPixel: maxPixel) }) { images[name] = Image(decorative: cg, scale: 1) }
        }
        let art = OpeningArt(ribbonRear: images["ribbon-rear"], screen: images["screen"], antennaLeft: images["antenna-left"], antennaRight: images["antenna-right"],
                             tvBody: images["tv-body"], playButton: images["play-button"], ribbonFront: images["ribbon-front"],
                             sweepMask: images["sweep-mask"], glintMask: images["glint-mask"], fallback: nil, isReady: true)
        store.value = art
        return art
    }

    /// Compatibility for callers that want the art synchronously (tests, previews).
    @MainActor static func load() -> OpeningArt {
        var art = loadNow()
        if !art.isLayered { art.fallback = mark }
        return art
    }

    /// A bitmap no larger than `maxPixel` on its longest side, redrawn once into a plain premultiplied sRGB bitmap so drawing it later
    /// needs no decoding.
    static func downscaled(_ image: CGImage, maxPixel: Int) -> CGImage? {
        let k = min(1, Double(maxPixel) / Double(max(image.width, image.height)))
        let w = max(1, Int((Double(image.width) * k).rounded())), h = max(1, Int((Double(image.height) * k).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private static func source(_ name: String) -> CGImage? {
        #if os(macOS)
        func read(_ url: URL) -> CGImage? { CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } }
        if let url = Bundle.main.url(forResource: "TuneIn-\(name)", withExtension: "png"), let image = read(url) { return image }
        #if DEBUG
        // swift run and swift test have no app bundle: the layers are read from the repository's motion assets.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if let image = read(root.appendingPathComponent("motion/assets/tune-in/\(name).png")) { return image }
        #endif
        return nil
        #else
        return UIImage(named: "TuneIn-\(name)")?.cgImage
        #endif
    }

    @MainActor static var mark: Image {
        #if os(macOS)
        if let image = BrandSymbolImage.shared { return Image(nsImage: image) }
        return Image(systemName: "play.tv")
        #else
        return Image("BrandSymbol")
        #endif
    }

    /// A small tile of fixed noise for the film grain and the snow, made once.
    nonisolated(unsafe) static let noise: Image = {
        let size = 128
        var bytes = [UInt8](repeating: 0, count: size * size)
        var seed: UInt32 = 2_463_534_242
        for i in bytes.indices { seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; bytes[i] = UInt8(truncatingIfNeeded: seed) }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let cg = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(),
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return Image(decorative: cg, scale: 1)
    }()
}

/// Draws one frame of "Tune In" from the television's layers. The artboard (1000 x 600) is fitted into the view and centred; on a
/// portrait screen only its middle 700 units are fitted, so the television is not tiny.
///
/// The layers' weak spots are kept out of sight by the motion itself: the glass behind the play button (a clean plate) is covered by the
/// dot's glow and then by the button, which grows from its own centre; the corner of the frame under the ribbon (also a clean plate)
/// stays in shadow until the ribbon has wrapped it; the wipe runs on across the split between the rear and front ribbon without a pause.
enum OpeningRenderer {
    static func draw(_ ctx: inout GraphicsContext, size: CGSize, frame f: OpeningFrame, art: OpeningArt, time ms: Double = 0) {
        let full = CGRect(origin: .zero, size: size)
        ctx.fill(Path(full), with: .color(OpeningColors.background))
        ctx.fill(Path(full), with: .radialGradient(Gradient(colors: [OpeningColors.backgroundGlow.opacity(0.8 * max(f.warm, 0.35 * f.setLight)), .clear]),
                                                   center: CGPoint(x: size.width / 2, y: size.height * 0.46), startRadius: 0, endRadius: min(size.width, size.height) * 0.75))
        let window: CGFloat = size.width < size.height ? 700 : 1000
        let s = min(size.width / window, size.height / 600)
        let ox = size.width / 2 - 500 * s, oy = size.height / 2 - 300 * s
        var c = ctx
        c.translateBy(x: ox, y: oy)
        c.scaleBy(x: s, y: s)
        // One slow push of about 4 %, with a short ease-back during the anticipation.
        let camera = 1 + 0.04 * f.push - 0.02 * f.easeBack
        c.translateBy(x: 500, y: 300); c.scaleBy(x: camera, y: camera); c.translateBy(x: -500, y: -300)

        if art.isLayered { television(&c, f, art, ms) } else if let fallback = art.fallback { var m = c; m.opacity = f.setLight; m.draw(fallback, in: OpeningGeometry.markRect) }
        words(&c, f)
        grain(&ctx, size, ms)
        let g = OpeningGeometry.screen
        let glass = CGRect(x: ox + (500 + (g.minX - 500) * camera) * s, y: oy + (300 + (g.minY - 300) * camera) * s,
                           width: g.width * camera * s, height: g.height * camera * s)
        matchCut(&ctx, f, size: size, glass: glass)
    }

    private static func television(_ ctx: inout GraphicsContext, _ f: OpeningFrame, _ art: OpeningArt, _ ms: Double) {
        typealias G = OpeningGeometry
        let rect = G.markRect
        let light = f.setLight

        // The rear of the ribbon, drawn on along its centre line, behind the set.
        if let rear = art.ribbonRear, f.ribbonRear > 0 {
            var r = ctx
            r.clip(to: G.rearBand.path(f.ribbonRear))
            r.opacity = max(0.35, light)
            r.draw(rear, in: rect)
        }
        // The glass: dark at first, warming to its teal; snow and the dot's glow on it.
        if let screen = art.screen {
            var g = ctx
            g.opacity = 0.18 * min(1, light * 3) + 0.82 * f.warm
            g.draw(screen, in: rect)
        }
        screenLife(&ctx, f, ms)
        // The antennas, turning a little about their pivots as the set is tuned.
        for (image, pivot, angle) in [(art.antennaLeft, G.pivotLeft, f.twitchLeft), (art.antennaRight, G.pivotRight, f.twitchRight)] {
            guard let image else { continue }
            var a = ctx
            a.opacity = light
            a.translateBy(x: pivot.x, y: pivot.y); a.rotate(by: .degrees(angle)); a.translateBy(x: -pivot.x, y: -pivot.y)
            a.draw(image, in: rect)
        }
        if let body = art.tvBody {
            var b = ctx
            b.opacity = light
            b.draw(body, in: rect)
        }
        // The light band of the tuning, kept to the silver (the sweep mask holds the body and the antennas).
        if f.sweep >= 0, let mask = art.sweepMask {
            var bounded = ctx
            bounded.clip(to: Path(rect.insetBy(dx: -60, dy: -60)))
            bounded.drawLayer { layer in
                layer.draw(mask, in: rect)
                layer.blendMode = .sourceIn
                let x = rect.minX - 140 + (rect.width + 280) * f.sweep
                layer.fill(Path(rect.insetBy(dx: -60, dy: -60)),
                           with: .linearGradient(Gradient(stops: [.init(color: .clear, location: 0), .init(color: OpeningColors.cream.opacity(0.75), location: 0.5), .init(color: .clear, location: 1)]),
                                                 startPoint: CGPoint(x: x - 60, y: rect.minY), endPoint: CGPoint(x: x + 60, y: rect.maxY - 80)))
            }
        }
        // The dot, then the play button growing out of it from its centre, with the small press-in of the hero beat.
        if f.dot > 0.001 {
            var d = ctx
            d.opacity = f.dot
            let p = G.play
            d.fill(Path(ellipseIn: CGRect(x: p.x - 26, y: p.y - 26, width: 52, height: 52)),
                   with: .radialGradient(Gradient(colors: [OpeningColors.cream.opacity(0.65), OpeningColors.teal.opacity(0.25), .clear]), center: p, startRadius: 0, endRadius: 26))
            d.fill(Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)), with: .color(OpeningColors.cream))
        }
        if f.play > 0.001, let button = art.playButton {
            var b = ctx
            let k = (0.18 + 0.82 * f.play) * (1 - 0.03 * f.press)
            b.opacity = min(1, f.play * 1.6)
            b.translateBy(x: G.play.x, y: G.play.y); b.scaleBy(x: k, y: k); b.translateBy(x: -G.play.x, y: -G.play.y)
            b.draw(button, in: rect)
        }
        // The front of the ribbon, wiped on along its centre line right after the rear, so it binds the set.
        if let front = art.ribbonFront, f.ribbonFront > 0 {
            var r = ctx
            if f.ribbonFront < 1 { r.clip(to: G.frontBand.path(f.ribbonFront)) }
            r.draw(front, in: rect)
            if f.sheen >= 0 {
                // The satin light travelling along the ribbon, kept to the ribbon's own pixels.
                var bounded = ctx
                bounded.clip(to: Path(rect.insetBy(dx: -60, dy: -60)))
                bounded.drawLayer { layer in
                    layer.draw(front, in: rect)
                    layer.blendMode = .sourceAtop
                    let p = G.point(G.frontLine, f.sheen)
                    var e = layer
                    e.translateBy(x: p.x, y: p.y); e.rotate(by: .degrees(-20))
                    e.fill(Path(ellipseIn: CGRect(x: -60, y: -16, width: 120, height: 32)),
                           with: .radialGradient(Gradient(colors: [.white.opacity(0.55 * sin(.pi * f.sheen)), .clear]), center: .zero, startRadius: 0, endRadius: 60))
                }
            }
        }
        // The one glint, on the antenna tips and the top of the frame (the glint mask).
        if f.glint > 0.001, let glint = art.glintMask {
            var g = ctx
            g.opacity = 0.9 * f.glint
            g.blendMode = .plusLighter
            g.draw(glint, in: rect)
        }
    }

    /// Inside the glass: faint snow while the set is tuned (never above 12 %), and the teal glow of the warm-up.
    private static func screenLife(_ ctx: inout GraphicsContext, _ f: OpeningFrame, _ ms: Double) {
        typealias G = OpeningGeometry
        var g = ctx
        g.clip(to: G.screenShape)
        let glow = 0.28 * min(1, f.setLight * 3) * (1 - f.warm) + 0.18 * f.warm * (1 - f.play)
        if glow > 0.001 {
            g.fill(G.screenShape, with: .radialGradient(Gradient(colors: [OpeningColors.teal.opacity(glow), .clear]), center: G.play, startRadius: 0, endRadius: G.screen.width * 0.6))
        }
        if f.snow > 0.001 {
            var n = g
            n.opacity = 0.12 * f.snow
            let step = CGFloat(Int(ms / 41.7) % 8)
            let tile = G.screen.width / 2
            for row in 0..<2 { for col in 0..<3 {
                n.draw(OpeningArt.noise, in: CGRect(x: G.screen.minX + CGFloat(col) * tile - step * 6, y: G.screen.minY + CGFloat(row) * tile - step * 4, width: tile, height: tile))
            } }
        }
    }

    /// "StreamSetu" with a small tracking settle, then the line beneath it; both fade as the screen expands.
    private static func words(_ ctx: inout GraphicsContext, _ f: OpeningFrame) {
        typealias G = OpeningGeometry
        let away = 1 - min(1, f.matchCut * 2.5)
        if f.wordmark > 0.001 {
            var w = ctx
            w.opacity = f.wordmark * away
            w.draw(Text("StreamSetu").font(.system(size: 52, weight: .bold)).tracking(-0.6 + 52 * 0.03 * (1 - f.wordmark)).foregroundColor(OpeningColors.foreground),
                   at: CGPoint(x: 500, y: G.wordmarkBaseline), anchor: UnitPoint(x: 0.5, y: 0.78))
        }
        if f.tagline > 0.001 {
            var t = ctx
            t.opacity = f.tagline * away
            t.draw(Text("Your streams. One home.").font(.system(size: 20)).foregroundColor(OpeningColors.foregroundSecondary),
                   at: CGPoint(x: 500, y: G.taglineBaseline), anchor: UnitPoint(x: 0.5, y: 0.78))
        }
    }

    /// Faint film grain over everything, a fixed tile that shifts 24 times a second.
    private static func grain(_ ctx: inout GraphicsContext, _ size: CGSize, _ ms: Double) {
        var g = ctx
        g.opacity = 0.035
        g.blendMode = .plusLighter
        let tile: CGFloat = 256, step = CGFloat(Int(ms / 41.7) % 6) * 37
        var y = -step.truncatingRemainder(dividingBy: tile)
        while y < size.height {
            var x = -step.truncatingRemainder(dividingBy: tile)
            while x < size.width { g.draw(OpeningArt.noise, in: CGRect(x: x, y: y, width: tile, height: tile)); x += tile }
            y += tile
        }
    }

    /// The match-cut: the teal screen grows from the glass to the whole frame while the layer crossfades into the app.
    private static func matchCut(_ ctx: inout GraphicsContext, _ f: OpeningFrame, size: CGSize, glass from: CGRect) {
        guard f.matchCut > 0.001 else { return }
        let full = CGRect(origin: .zero, size: size)
        let t = f.matchCut
        let r = CGRect(x: from.minX + (full.minX - from.minX) * t, y: from.minY + (full.minY - from.minY) * t,
                       width: from.width + (full.width - from.width) * t, height: from.height + (full.height - from.height) * t)
        ctx.fill(Path(roundedRect: r, cornerRadius: 40 * (1 - t), style: .continuous),
                 with: .radialGradient(Gradient(colors: [OpeningColors.backgroundGlow, OpeningColors.background]), center: CGPoint(x: r.midX, y: r.midY), startRadius: 0, endRadius: max(r.width, r.height) * 0.7))
    }
}

/// The ribbon drawing itself on: a small reusable piece of the opening for loading, switching and entering the player. Still (fully
/// drawn) by default; `animated` draws it again and again while it is on screen (still with Reduce Motion).
struct RibbonDrawMark: View {
    var animated = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !animated || reduceMotion)) { context in
            Canvas { ctx, size in
                let p = animated && !reduceMotion ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8 : 1
                typealias G = OpeningGeometry
                let line = G.ribbonLine
                let box = line.reduce(CGRect.null) { $0.union(CGRect(x: $1.0.x, y: $1.0.y, width: 0.1, height: 0.1)) }.insetBy(dx: -24, dy: -24)
                let s = min(size.width / box.width, size.height / box.height)
                ctx.translateBy(x: size.width / 2 - box.midX * s, y: size.height / 2 - box.midY * s)
                ctx.scaleBy(x: s, y: s)
                let drawn = OpeningEasing.cubicInOut(min(1, p / 0.75))
                ctx.opacity = p > 0.85 ? 1 - (p - 0.85) / 0.15 : 1
                ctx.clip(to: G.ribbonBand.path(drawn))
                ctx.fill(Path(box), with: .linearGradient(Gradient(colors: [OpeningColors.teal, OpeningColors.iceTeal, OpeningColors.silver]),
                                                          startPoint: CGPoint(x: box.minX, y: box.maxY), endPoint: CGPoint(x: box.maxX, y: box.minY)))
            }
        }
        .accessibilityHidden(true)
    }
}
