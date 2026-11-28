import SwiftUI

// One icon style for the drawn Music glyphs: a 24 unit grid, round caps and joins, an optical stroke weight that follows the size, and theme
// colours. Native control glyphs (chevrons, close, menus) stay SF Symbols; everything with a character of its own is drawn here.

/// The icon grid and its optical stroke rule. Pure, so the tests can pin it.
enum MusicIconGrid {
    /// Glyphs are drawn on a 24 by 24 unit grid with a 2 unit safe margin.
    static let units: CGFloat = 24
    /// The size glyphs get when the caller gives none (the same as `MusicIconSize.control`).
    static let defaultSize: CGFloat = 24

    /// Stroke width in points for a glyph drawn at `size`: heavier ratio when small so thin lines survive, lighter when large.
    static func strokeWidth(size: CGFloat) -> CGFloat {
        guard size.isFinite, size > 0 else { return 0 }
        let ratio: CGFloat = size < 16 ? 2.0 / 24 : (size < 32 ? 1.75 / 24 : 1.5 / 24)
        return max(1.25, size * ratio)
    }
}

/// Which drawn glyph.
enum MusicGlyph: String, CaseIterable, Sendable {
    case note, queue, shuffle, repeatAll, repeatOne, equalizer, waveform, quality, devices, lyrics, radio, playlist, loading
    case emptyLibrary, emptySearch, offline, heart, playPause
}

enum MusicIconTint: Sendable {
    case primary, secondary, tertiary, accent, custom(Color)
}

/// One path per glyph on the 24 unit grid, scaled into whatever square it is given.
struct MusicGlyphShape: Shape {
    let glyph: MusicGlyph
    /// Rotation of the loading arc in degrees; ignored by the other glyphs.
    var rotation: Double = 0

    var animatableData: Double {
        get { rotation }
        set { rotation = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let s = side / MusicIconGrid.units
        let ox = rect.midX - side / 2, oy = rect.midY - side / 2
        let p = { (x: CGFloat, y: CGFloat) in CGPoint(x: ox + x * s, y: oy + y * s) }
        let r = { (x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) in CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s) }
        // Arcs are sampled so their direction never depends on the flipped coordinate space.
        func arc(_ path: inout Path, _ cx: CGFloat, _ cy: CGFloat, _ rad: CGFloat, _ from: Double, _ to: Double, moveFirst: Bool = true) {
            let steps = max(8, Int(abs(to - from) / 6))
            for i in 0...steps {
                let a = (from + (to - from) * Double(i) / Double(steps)) * .pi / 180
                let pt = p(cx + rad * CGFloat(cos(a)), cy + rad * CGFloat(sin(a)))
                if i == 0 && moveFirst { path.move(to: pt) } else { path.addLine(to: pt) }
            }
        }
        var path = Path()
        switch glyph {
        case .note:
            path.addEllipse(in: r(5, 15, 5.5, 4.5))
            path.move(to: p(10.5, 17)); path.addLine(to: p(10.5, 4.5))
            path.addCurve(to: p(17, 9.5), control1: p(12.5, 5), control2: p(17, 6.2))
        case .queue:
            path.move(to: p(4, 6)); path.addLine(to: p(16, 6))
            path.move(to: p(4, 11)); path.addLine(to: p(16, 11))
            path.move(to: p(4, 16)); path.addLine(to: p(10, 16))
            path.move(to: p(15, 14)); path.addLine(to: p(15, 21)); path.addLine(to: p(20.5, 17.5)); path.closeSubpath()
        case .shuffle:
            path.move(to: p(3, 7)); path.addLine(to: p(7, 7)); path.addCurve(to: p(17, 17), control1: p(11.5, 7), control2: p(12.5, 17)); path.addLine(to: p(20, 17))
            path.move(to: p(3, 17)); path.addLine(to: p(7, 17)); path.addCurve(to: p(17, 7), control1: p(11.5, 17), control2: p(12.5, 7)); path.addLine(to: p(20, 7))
            path.move(to: p(17.5, 4.5)); path.addLine(to: p(20.5, 7)); path.addLine(to: p(17.5, 9.5))
            path.move(to: p(17.5, 14.5)); path.addLine(to: p(20.5, 17)); path.addLine(to: p(17.5, 19.5))
        case .repeatAll, .repeatOne:
            path.move(to: p(4, 12)); path.addLine(to: p(4, 10)); path.addQuadCurve(to: p(7, 7), control: p(4, 7)); path.addLine(to: p(19, 7))
            path.move(to: p(16, 4)); path.addLine(to: p(19, 7)); path.addLine(to: p(16, 10))
            path.move(to: p(20, 12)); path.addLine(to: p(20, 14)); path.addQuadCurve(to: p(17, 17), control: p(20, 17)); path.addLine(to: p(5, 17))
            path.move(to: p(8, 14)); path.addLine(to: p(5, 17)); path.addLine(to: p(8, 20))
            if glyph == .repeatOne {
                path.move(to: p(10.8, 10.8)); path.addLine(to: p(12.3, 9.8)); path.addLine(to: p(12.3, 14.2))
            }
        case .equalizer:
            for (x, top) in [(6.0, 12.0), (12.0, 5.0), (18.0, 9.0)] {
                path.move(to: p(x, 20)); path.addLine(to: p(x, top))
            }
        case .waveform:
            for (x, h) in [(4.0, 3.0), (8.0, 8.0), (12.0, 14.0), (16.0, 9.0), (20.0, 4.0)] {
                path.move(to: p(x, 12 - h / 2)); path.addLine(to: p(x, 12 + h / 2))
            }
        case .quality:
            path.addRoundedRect(in: r(3, 5.5, 18, 13), cornerSize: CGSize(width: 3.5 * s, height: 3.5 * s))
            for (x, h) in [(8.0, 3.0), (12.0, 7.0), (16.0, 4.5)] {
                path.move(to: p(x, 12 - h / 2)); path.addLine(to: p(x, 12 + h / 2))
            }
        case .devices:
            path.addRoundedRect(in: r(3, 5, 13, 9.5), cornerSize: CGSize(width: 1.5 * s, height: 1.5 * s))
            path.move(to: p(2, 18)); path.addLine(to: p(17, 18))
            path.addRoundedRect(in: r(17.5, 8.5, 4, 7.5), cornerSize: CGSize(width: 1.2 * s, height: 1.2 * s))
        case .lyrics:
            path.addRoundedRect(in: r(3, 4, 18, 13), cornerSize: CGSize(width: 3 * s, height: 3 * s))
            path.move(to: p(8, 17)); path.addLine(to: p(8, 21)); path.addLine(to: p(12, 17))
            path.move(to: p(7.5, 9)); path.addLine(to: p(16.5, 9))
            path.move(to: p(7.5, 12.5)); path.addLine(to: p(13, 12.5))
        case .radio:
            path.addEllipse(in: r(10.2, 10.2, 3.6, 3.6))
            for rad in [CGFloat(6), 9.5] {
                arc(&path, 12, 12, rad, -48, 48)
                arc(&path, 12, 12, rad, 132, 228)
            }
        case .playlist:
            path.move(to: p(4, 6)); path.addLine(to: p(14, 6))
            path.move(to: p(4, 11)); path.addLine(to: p(14, 11))
            path.move(to: p(4, 16)); path.addLine(to: p(9, 16))
            path.addEllipse(in: r(14.5, 15, 4.4, 3.8))
            path.move(to: p(18.9, 17)); path.addLine(to: p(18.9, 7.5)); path.addLine(to: p(21, 8.5))
        case .loading:
            arc(&path, 12, 12, 8, rotation, rotation + 270)
        case .emptyLibrary:
            path.addRoundedRect(in: r(4, 5, 4.5, 14), cornerSize: CGSize(width: 1 * s, height: 1 * s))
            path.addRoundedRect(in: r(10, 5, 4.5, 14), cornerSize: CGSize(width: 1 * s, height: 1 * s))
            path.move(to: p(16.8, 7)); path.addLine(to: p(20.6, 6)); path.addLine(to: p(22, 18)); path.addLine(to: p(18, 19)); path.closeSubpath()
            path.move(to: p(2.5, 21.5)); path.addLine(to: p(21.5, 21.5))
        case .emptySearch:
            path.addEllipse(in: r(4, 4, 12.5, 12.5))
            path.move(to: p(14.5, 14.5)); path.addLine(to: p(20.5, 20.5))
            path.move(to: p(7.8, 10.25)); path.addLine(to: p(12.7, 10.25))
        case .offline:
            path.move(to: p(7, 18))
            path.addCurve(to: p(7.2, 11.5), control1: p(3, 18), control2: p(3, 12))
            path.addCurve(to: p(15.5, 9.5), control1: p(8, 7), control2: p(13.5, 6.5))
            path.addCurve(to: p(17.5, 18), control1: p(20.5, 9.5), control2: p(22, 18))
            path.addLine(to: p(7, 18))
            path.move(to: p(3.5, 3.5)); path.addLine(to: p(20.5, 20.5))
        case .heart:
            path = MusicHeartShape().path(in: rect)
        case .playPause:
            path = MusicPlayPauseShape(progress: 0).path(in: rect)
        }
        return path
    }
}

// MARK: - Heart

struct MusicHeartShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let s = side / MusicIconGrid.units
        let ox = rect.midX - side / 2, oy = rect.midY - side / 2
        let p = { (x: CGFloat, y: CGFloat) in CGPoint(x: ox + x * s, y: oy + y * s) }
        var path = Path()
        path.move(to: p(12, 20.5))
        path.addCurve(to: p(3, 8.5), control1: p(12, 20.5), control2: p(3, 14.5))
        path.addCurve(to: p(8, 3.5), control1: p(3, 5.5), control2: p(5.4, 3.5))
        path.addCurve(to: p(12, 5.8), control1: p(9.7, 3.5), control2: p(11.2, 4.4))
        path.addCurve(to: p(16, 3.5), control1: p(12.8, 4.4), control2: p(14.3, 3.5))
        path.addCurve(to: p(21, 8.5), control1: p(18.6, 3.5), control2: p(21, 5.5))
        path.addCurve(to: p(12, 20.5), control1: p(21, 14.5), control2: p(12, 20.5))
        path.closeSubpath()
        return path
    }
}

// MARK: - Play and pause morph

/// The play triangle is cut into a left and a right piece; each piece is a quad that bends into one pause bar. Pure point maths on the 24 grid.
enum MusicPlayPauseMorph {
    /// Left piece then right piece, four points each (top left, top right, bottom right, bottom left), as a play triangle.
    static let play: [[CGPoint]] = [
        [CGPoint(x: 7, y: 5), CGPoint(x: 12, y: 8.2), CGPoint(x: 12, y: 15.8), CGPoint(x: 7, y: 19)],
        [CGPoint(x: 12, y: 8.2), CGPoint(x: 18, y: 12), CGPoint(x: 18, y: 12), CGPoint(x: 12, y: 15.8)],
    ]
    /// The same two pieces as pause bars.
    static let pause: [[CGPoint]] = [
        [CGPoint(x: 7, y: 5), CGPoint(x: 10.5, y: 5), CGPoint(x: 10.5, y: 19), CGPoint(x: 7, y: 19)],
        [CGPoint(x: 13.5, y: 5), CGPoint(x: 17, y: 5), CGPoint(x: 17, y: 19), CGPoint(x: 13.5, y: 19)],
    ]

    static func clamp(_ t: CGFloat) -> CGFloat { t.isFinite ? min(max(t, 0), 1) : 0 }

    /// Points at `progress` 0 (play) to 1 (pause).
    static func points(progress: CGFloat) -> [[CGPoint]] {
        let t = clamp(progress)
        return zip(play, pause).map { a, b in
            zip(a, b).map { CGPoint(x: $0.x + ($1.x - $0.x) * t, y: $0.y + ($1.y - $0.y) * t) }
        }
    }
}

/// A play or pause glyph at `progress` (0 play, 1 pause). Animating `progress` animates the morph itself.
struct MusicPlayPauseShape: Shape {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let s = side / MusicIconGrid.units
        let ox = rect.midX - side / 2, oy = rect.midY - side / 2
        var path = Path()
        for piece in MusicPlayPauseMorph.points(progress: progress) {
            for (i, pt) in piece.enumerated() {
                let q = CGPoint(x: ox + pt.x * s, y: oy + pt.y * s)
                if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
            }
            path.closeSubpath()
        }
        return path
    }
}

// MARK: - Views

/// A drawn glyph, stroked in a theme colour. Decorative unless given a `label`.
struct MusicIcon: View {
    let glyph: MusicGlyph
    var size: CGFloat = MusicIconGrid.defaultSize
    var tint: MusicIconTint = .primary
    var label: String?
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        MusicGlyphShape(glyph: glyph)
            .stroke(MusicIconColor.resolve(tint, accent: accent), style: StrokeStyle(lineWidth: MusicIconGrid.strokeWidth(size: size), lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .musicIconAccessibility(label)
    }
}

enum MusicIconColor {
    static func resolve(_ tint: MusicIconTint, accent: Color) -> Color {
        switch tint {
        case .primary: ColorTokens.textPrimary
        case .secondary: ColorTokens.textSecondary
        case .tertiary: ColorTokens.textTertiary
        case .accent: accent
        case .custom(let c): c
        }
    }
}

extension View {
    /// Decorative (hidden from VoiceOver) without a label; otherwise an image with that label.
    @ViewBuilder func musicIconAccessibility(_ label: String?) -> some View {
        if let label, !label.isEmpty {
            accessibilityElement(children: .ignore).accessibilityLabel(Text(verbatim: label)).accessibilityAddTraits(.isImage)
        } else {
            accessibilityHidden(true)
        }
    }
}

/// The play and pause glyph with a real morph between the two. Short and interruptible: a quick reversal continues from where it is.
struct MusicPlayPauseIcon: View {
    let isPlaying: Bool
    var size: CGFloat = MusicIconGrid.defaultSize
    var tint: MusicIconTint = .primary
    var label: String?
    @Environment(\.reddyAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let color = MusicIconColor.resolve(tint, accent: accent)
        MusicPlayPauseShape(progress: isPlaying ? 1 : 0)
            .fill(color)
            .overlay(MusicPlayPauseShape(progress: isPlaying ? 1 : 0).stroke(color, style: StrokeStyle(lineWidth: size / MusicIconGrid.units, lineJoin: .round)))
            .frame(width: size, height: size)
            .animation(MusicMotion.interruptible(.snappy, reduce: reduceMotion), value: isPlaying)
            .musicIconAccessibility(label)
    }
}

/// An outlined heart that fills with a small spring. The fill is interruptible; with Reduce Motion it switches at once.
struct MusicHeartIcon: View {
    let filled: Bool
    var size: CGFloat = MusicIconGrid.defaultSize
    var tint: MusicIconTint = .accent
    var label: String?
    @Environment(\.reddyAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let color = MusicIconColor.resolve(tint, accent: accent)
        ZStack {
            MusicHeartShape().fill(color).scaleEffect(filled ? 1 : MusicHeartMotion.restScale).opacity(filled ? 1 : 0)
            MusicHeartShape().stroke(filled ? color : ColorTokens.textSecondary, style: StrokeStyle(lineWidth: MusicIconGrid.strokeWidth(size: size), lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .animation(MusicMotion.interruptible(.snappy, reduce: reduceMotion), value: filled)
        .musicIconAccessibility(label)
    }
}

enum MusicHeartMotion {
    /// Scale of the fill when empty, so it grows out of the middle.
    static let restScale: CGFloat = 0.3
}

// MARK: - Navigation glyphs

/// The navigation icon set: sidebar places and context panel tabs. Every glyph is drawn on the same 24 unit grid, inside the same live area
/// (2 to 22), with the same round stroke, and is shown in one fixed box (`MusicNavIcon.box`), so the icon column stays even.
/// Each has an outline look (stroke only) and a selected look (the same stroke, heavier, with the body filled in a tint of the accent).
enum MusicNavGlyph: String, CaseIterable, Sendable {
    case listenNow, explore, recentlyAdded, search, library, radio, downloads, devices, listenTogether, settings
    case nowPlaying, queue, lyrics, related, credits, info, close
}

extension MusicSection {
    /// The drawn navigation glyph for this place.
    var navGlyph: MusicNavGlyph {
        switch self {
        case .home: .listenNow
        case .explore: .explore
        case .recentlyAdded: .recentlyAdded
        case .search: .search
        case .library: .library
        case .radio: .radio
        case .downloads: .downloads
        case .devices: .devices
        case .room: .listenTogether
        case .settings: .settings
        }
    }
}

extension MusicContextPanelTab {
    /// The drawn navigation glyph for this tab.
    var navGlyph: MusicNavGlyph {
        switch self {
        case .nowPlaying: .nowPlaying
        case .queue: .queue
        case .lyrics: .lyrics
        case .related: .related
        case .credits: .credits
        case .info: .info
        }
    }
}

/// Which part of a navigation glyph to draw: all of it, or only the closed body that the selected look fills.
enum MusicNavGlyphPart: Sendable { case full, body }

struct MusicNavGlyphShape: Shape {
    let glyph: MusicNavGlyph
    var part: MusicNavGlyphPart = .full

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let s = side / MusicIconGrid.units
        let ox = rect.midX - side / 2, oy = rect.midY - side / 2
        let p = { (x: CGFloat, y: CGFloat) in CGPoint(x: ox + x * s, y: oy + y * s) }
        let r = { (x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) in CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s) }
        func circle(_ path: inout Path, _ cx: CGFloat, _ cy: CGFloat, _ rad: CGFloat) { path.addEllipse(in: r(cx - rad, cy - rad, rad * 2, rad * 2)) }
        func arc(_ path: inout Path, _ cx: CGFloat, _ cy: CGFloat, _ rad: CGFloat, _ from: Double, _ to: Double) {
            let steps = max(8, Int(abs(to - from) / 6))
            for i in 0...steps {
                let a = (from + (to - from) * Double(i) / Double(steps)) * .pi / 180
                let pt = p(cx + rad * CGFloat(cos(a)), cy + rad * CGFloat(sin(a)))
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
        }
        var body = Path(), detail = Path()
        switch glyph {
        case .listenNow:
            circle(&body, 12, 12, 9)
            detail.move(to: p(10, 8.2)); detail.addLine(to: p(16, 12)); detail.addLine(to: p(10, 15.8)); detail.closeSubpath()
        case .explore:
            circle(&body, 12, 12, 9)
            detail.move(to: p(15.6, 8.4)); detail.addLine(to: p(13.2, 13.2)); detail.addLine(to: p(8.4, 15.6)); detail.addLine(to: p(10.8, 10.8)); detail.closeSubpath()
        case .recentlyAdded:
            circle(&body, 12, 12, 9)
            detail.move(to: p(12, 7)); detail.addLine(to: p(12, 12)); detail.addLine(to: p(15.6, 14.2))
        case .search:
            circle(&body, 10.5, 10.5, 7.5)
            detail.move(to: p(16, 16)); detail.addLine(to: p(21, 21))
        case .library:
            body.addRoundedRect(in: r(3, 4, 5.5, 16), cornerSize: CGSize(width: s, height: s))
            body.addRoundedRect(in: r(10, 4, 5.5, 16), cornerSize: CGSize(width: s, height: s))
            detail.addRoundedRect(in: r(17, 4, 4, 16), cornerSize: CGSize(width: s, height: s))
        case .radio:
            circle(&body, 12, 12, 1.9)
            for rad in [CGFloat(5), 8.8] { arc(&detail, 12, 12, rad, -58, 58); arc(&detail, 12, 12, rad, 122, 238) }
        case .downloads:
            body.addRoundedRect(in: r(3, 14, 18, 7), cornerSize: CGSize(width: 2 * s, height: 2 * s))
            detail.move(to: p(12, 3)); detail.addLine(to: p(12, 15))
            detail.move(to: p(7.5, 10.5)); detail.addLine(to: p(12, 15)); detail.addLine(to: p(16.5, 10.5))
        case .devices:
            body.addRoundedRect(in: r(2.5, 5, 14, 10), cornerSize: CGSize(width: 1.5 * s, height: 1.5 * s))
            detail.move(to: p(2.5, 18.5)); detail.addLine(to: p(16.5, 18.5))
            detail.addRoundedRect(in: r(14.5, 9.5, 6.5, 11.5), cornerSize: CGSize(width: 1.5 * s, height: 1.5 * s))
        case .listenTogether:
            circle(&body, 7.5, 11, 2.7); circle(&body, 16.5, 11, 2.7)
            detail.move(to: p(3, 20)); detail.addQuadCurve(to: p(7.5, 15.5), control: p(3, 15.5)); detail.addQuadCurve(to: p(12, 20), control: p(12, 15.5))
            detail.move(to: p(12, 20)); detail.addQuadCurve(to: p(16.5, 15.5), control: p(12, 15.5)); detail.addQuadCurve(to: p(21, 20), control: p(21, 15.5))
            arc(&detail, 12, 9, 3.2, -135, -45)
            arc(&detail, 12, 9, 6.4, -135, -45)
        case .settings:
            for (y, x) in [(CGFloat(6), CGFloat(8)), (12, 16), (18, 10)] {
                circle(&body, x, y, 2.3)
                detail.move(to: p(3, y)); detail.addLine(to: p(x - 2.3, y))
                detail.move(to: p(x + 2.3, y)); detail.addLine(to: p(21, y))
            }
        case .nowPlaying:
            circle(&body, 12, 12, 9)
            circle(&detail, 12, 12, 2.4)
            arc(&detail, 12, 12, 5.6, 200, 290)
        case .queue:
            detail.move(to: p(3, 6)); detail.addLine(to: p(21, 6))
            detail.move(to: p(3, 12)); detail.addLine(to: p(11.5, 12))
            detail.move(to: p(3, 18)); detail.addLine(to: p(11.5, 18))
            body.move(to: p(15, 11)); body.addLine(to: p(15, 19)); body.addLine(to: p(21, 15)); body.closeSubpath()
        case .lyrics:
            circle(&body, 5.2, 6.4, 1.5); circle(&body, 10.2, 6.4, 1.5)
            detail.move(to: p(6.4, 7.6)); detail.addLine(to: p(5, 10.5))
            detail.move(to: p(11.4, 7.6)); detail.addLine(to: p(10, 10.5))
            detail.move(to: p(14.5, 7)); detail.addLine(to: p(21, 7))
            detail.move(to: p(3, 14)); detail.addLine(to: p(21, 14))
            detail.move(to: p(3, 20)); detail.addLine(to: p(15, 20))
        case .related:
            circle(&body, 9, 12, 6); circle(&body, 15, 12, 6)
        case .credits:
            // A person (head, shoulders) beside two lines of credit text.
            circle(&body, 7.5, 7.7, 2.7)
            detail.move(to: p(3, 17.5)); detail.addQuadCurve(to: p(7.5, 12.5), control: p(3, 12.5)); detail.addQuadCurve(to: p(12, 17.5), control: p(12, 12.5))
            detail.move(to: p(15, 8)); detail.addLine(to: p(21, 8))
            detail.move(to: p(15, 13.5)); detail.addLine(to: p(21, 13.5))
        case .info:
            circle(&body, 12, 12, 9)
            detail.move(to: p(12, 11)); detail.addLine(to: p(12, 16.5))
            detail.addEllipse(in: r(11.3, 7, 1.4, 1.4))
        case .close:
            detail.move(to: p(5.5, 5.5)); detail.addLine(to: p(18.5, 18.5))
            detail.move(to: p(18.5, 5.5)); detail.addLine(to: p(5.5, 18.5))
        }
        if part == .body { return body }
        var full = body
        full.addPath(detail)
        return full
    }
}

/// A navigation glyph in its fixed box. Outline when idle; selected is heavier, with the body filled in a tint of the accent. The change
/// is a short toggle animation, and none under Reduce Motion.
struct MusicNavIcon: View {
    /// The one box every navigation glyph sits in, so the icon column and the tab row stay even.
    static let box: CGFloat = MusicIconSize.row
    /// How much heavier the selected stroke is, as a share of the outline stroke.
    static let selectedWeight: CGFloat = 1.18
    /// Strength of the body fill in the selected look.
    static let selectedFill: Double = 0.22

    let glyph: MusicNavGlyph
    var selected = false
    var tint: MusicIconTint = .primary
    var label: String?
    @Environment(\.reddyAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let color = MusicIconColor.resolve(selected ? .accent : tint, accent: accent)
        let width = MusicIconGrid.strokeWidth(size: Self.box) * (selected ? Self.selectedWeight : 1)
        ZStack {
            MusicNavGlyphShape(glyph: glyph, part: .body).fill(color.opacity(selected ? Self.selectedFill : 0))
            MusicNavGlyphShape(glyph: glyph).stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
        .frame(width: Self.box, height: Self.box)
        .musicAnimation(.toggle, reduce: reduceMotion, value: selected)
        .musicIconAccessibility(label)
    }
}
