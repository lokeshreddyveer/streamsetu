import SwiftUI

// The two icons that move on their own clock. Both use MusicFrameClock, pause when inactive or when Reduce Motion is on, and draw a still
// frame in those cases, so an idle screen costs no CPU.

/// Equalizer bar heights over time. Pure: the same time always gives the same bars.
enum MusicEqualizerBarMath {
    static let barCount = 3
    /// Heights (0...1) used when the bars are still.
    static let restLevels: [CGFloat] = [0.45, 0.8, 0.6]
    static let minLevel: CGFloat = 0.2
    /// Seconds per cycle of each bar; different periods keep the bars out of step.
    static let periods: [Double] = [0.9, 0.7, 1.1]

    static func levels(time: Double, active: Bool) -> [CGFloat] {
        guard active, time.isFinite else { return restLevels }
        return (0..<barCount).map { i in
            let phase = time / periods[i] * 2 * .pi + Double(i) * 1.7
            let unit = (sin(phase) + 1) / 2
            return minLevel + (1 - minLevel) * CGFloat(unit)
        }
    }
}

struct MusicEqualizerShape: Shape {
    var levels: [CGFloat]
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let s = side / MusicIconGrid.units
        let ox = rect.midX - side / 2, oy = rect.midY - side / 2
        var path = Path()
        let xs: [CGFloat] = [6, 12, 18]
        for (i, level) in levels.prefix(xs.count).enumerated() {
            let top = 20 - 16 * min(max(level, 0), 1)
            path.move(to: CGPoint(x: ox + xs[i] * s, y: oy + 20 * s))
            path.addLine(to: CGPoint(x: ox + xs[i] * s, y: oy + top * s))
        }
        return path
    }
}


/// A spinning arc while something loads. With Reduce Motion it is a still arc.
struct MusicLoadingIcon: View {
    var size: CGFloat = MusicIconGrid.defaultSize
    var tint: MusicIconTint = .secondary
    var label: String?
    /// Seconds for one turn.
    static let period: Double = 1.0
    @Environment(\.reddyAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Rotation in degrees for a time (pure).
    static func rotation(time: Double) -> Double {
        guard time.isFinite else { return 0 }
        return (time.truncatingRemainder(dividingBy: period) / period) * 360
    }

    var body: some View {
        MusicFrameClock(minimumInterval: 1.0 / 30.0, paused: reduceMotion) { ctx in
            MusicGlyphShape(glyph: .loading, rotation: reduceMotion ? 0 : Self.rotation(time: ctx.date.timeIntervalSinceReferenceDate))
                .stroke(MusicIconColor.resolve(tint, accent: accent), style: StrokeStyle(lineWidth: MusicIconGrid.strokeWidth(size: size), lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .musicIconAccessibility(label)
    }
}
