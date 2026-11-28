import Foundation
import CoreGraphics
import Observation

// Pure logic behind the player's finishing touches: the wheel volume gesture, the windowed queue, the marquee and wavy seek bar maths, the
// guard against foreign drags, zoom and page reload. No views and no AppKit, so all of it is shared with iOS and tested without a screen.

// MARK: wheel volume

/// Turns scroll-wheel and trackpad scrolling into whole volume steps of five percent. A wheel notch is one step; a trackpad has to travel
/// a fixed distance per step, and the left-over distance carries to the next event so slow scrolling still moves the volume.
struct MusicWheelVolume: Sendable, Equatable {
    /// Points of trackpad travel for one step.
    static let preciseTravel: CGFloat = 14
    /// A single event never moves more than this many steps.
    static let maxStepsPerEvent = 4

    private(set) var carry: CGFloat = 0

    /// Whole steps for one scroll event: positive raises the volume (scrolling up). `precise` is true for trackpads and smooth mice.
    mutating func steps(delta: CGFloat, precise: Bool) -> Int {
        guard delta.isFinite, delta != 0 else { return 0 }
        if !precise {
            carry = 0
            let n = min(Self.maxStepsPerEvent, max(1, Int(abs(delta).rounded())))
            return delta > 0 ? n : -n
        }
        // Reversing direction drops what was built up the other way.
        if (carry > 0 && delta < 0) || (carry < 0 && delta > 0) { carry = 0 }
        carry += delta
        let whole = Int(carry / Self.preciseTravel)
        guard whole != 0 else { return 0 }
        carry -= CGFloat(whole) * Self.preciseTravel
        return min(Self.maxStepsPerEvent, max(-Self.maxStepsPerEvent, whole))
    }

    mutating func reset() { carry = 0 }

    /// The volume after `steps` steps of five percent.
    static func volume(from v: Float, steps: Int) -> Float { MusicVolumeCurve.nudged(v, by: MusicVolumeCurve.nudgeStep * Float(steps)) }
}

// MARK: windowed queue

/// Which rows of a long queue are drawn. Rows are 56 points; the "Autoplay" heading before the first endless-playback row is 40. Only
/// rows near the viewport (plus ten above and below) exist as views; two spacers stand for the rest, so scrolling to the end still works.
enum MusicQueueWindow {
    static let threshold = 200
    static let overscan = 10
    static let rowHeight: CGFloat = MusicQueueDrag.rowHeight
    static let headingHeight: CGFloat = 40

    struct Layout: Equatable, Sendable {
        var range: Range<Int>
        var topPad: CGFloat
        var bottomPad: CGFloat
        var showHeading: Bool
    }

    static func isWindowed(rowCount: Int) -> Bool { rowCount > threshold }

    /// Top edge of a row, counting the heading when the row comes after it.
    static func rowY(_ i: Int, headingAt h: Int?) -> CGFloat {
        CGFloat(i) * rowHeight + (h.map { i >= $0 } ?? false ? headingHeight : 0)
    }

    static func totalHeight(rowCount: Int, headingAt h: Int?) -> CGFloat {
        CGFloat(rowCount) * rowHeight + (h != nil ? headingHeight : 0)
    }

    /// The row under a vertical offset. The heading's own strip belongs to the row that follows it.
    static func row(atOffset y: CGFloat, rowCount: Int, headingAt h: Int?) -> Int {
        guard rowCount > 0 else { return 0 }
        let off = max(0, y)
        var i: Int
        if let h, off >= CGFloat(h) * rowHeight {
            i = h + Int(max(0, off - CGFloat(h) * rowHeight - headingHeight) / rowHeight)
        } else {
            i = Int(off / rowHeight)
        }
        return min(rowCount - 1, max(0, i))
    }

    static func layout(rowCount: Int, headingAt h: Int?, offset: CGFloat, viewport: CGFloat) -> Layout {
        guard rowCount > 0 else { return Layout(range: 0..<0, topPad: 0, bottomPad: 0, showHeading: false) }
        let first = row(atOffset: offset, rowCount: rowCount, headingAt: h)
        let last = row(atOffset: offset + max(0, viewport), rowCount: rowCount, headingAt: h)
        let lower = max(0, first - overscan)
        let upper = min(rowCount, last + 1 + overscan)
        let range = lower..<upper
        let drawn = h.map { range.contains($0) } ?? false
        // The heading, when drawn, sits inside the rows; when it is above the window the top spacer already includes it.
        let top = rowY(lower, headingAt: h) - (drawn && h == lower ? headingHeight : 0)
        let bottom = max(0, totalHeight(rowCount: rowCount, headingAt: h) - (rowY(upper - 1, headingAt: h) + rowHeight))
        return Layout(range: range, topPad: top, bottomPad: bottom, showHeading: drawn)
    }
}

// MARK: foreign drags

/// Tells our own drags from anything else dropped on the window (a file, a link, text from another app). Only a drag that carries the
/// queue-row type is accepted by the queue; the payload text must also be well formed.
enum MusicDragGuard {
    /// The row index inside a payload written by `payload(row:)`, or nil for anything that is not ours.
    static func row(inPayload text: String) -> Int? {
        let prefix = MusicQueueDrag.mime + ":"
        guard text.hasPrefix(prefix), let n = Int(text.dropFirst(prefix.count)), n >= 0 else { return nil }
        return n
    }

    static func payload(row: Int) -> String { MusicQueueDrag.mime + ":\(row)" }

    /// Whether a drag offering these type identifiers is one of ours. Plain text and file types alone are not enough.
    static func isOurs(typeIdentifiers: [String], ours: String) -> Bool { typeIdentifiers.contains(ours) }
}

// MARK: marquee

enum MusicMarqueeMath {
    /// Space between the two copies of the text.
    static let gap: CGFloat = 40
    static let speed: CGFloat = 30
    /// The text rests at its start for this long before each pass.
    static let dwell: TimeInterval = 1.5

    static func overflows(textWidth: CGFloat, boxWidth: CGFloat) -> Bool { boxWidth > 0 && textWidth > boxWidth + 0.5 }

    /// Seconds for one full pass.
    static func period(textWidth: CGFloat) -> TimeInterval { dwell + TimeInterval((textWidth + gap) / speed) }

    /// Horizontal shift (zero or negative) after `elapsed` seconds of running.
    static func offset(elapsed: TimeInterval, textWidth: CGFloat) -> CGFloat {
        guard elapsed.isFinite, elapsed > 0, textWidth > 0 else { return 0 }
        let t = elapsed.truncatingRemainder(dividingBy: period(textWidth: textWidth))
        return t < dwell ? 0 : -CGFloat(t - dwell) * speed
    }

    /// Whether the text may move: it is too long, something is playing, the view is on screen and Reduce Motion is off.
    static func shouldRun(overflowing: Bool, playing: Bool, onScreen: Bool, reduceMotion: Bool) -> Bool {
        overflowing && playing && onScreen && !reduceMotion
    }
}

// MARK: wavy seek bar

enum MusicWaveMath {
    static let stroke: CGFloat = 3.5
    static let thumbWidth: CGFloat = 4
    static let thumbHeight: CGFloat = 18
    static let maxAmplitude: CGFloat = 2.8
    static let wavelength: CGFloat = 20
    static let taper: CGFloat = 10
    /// Clear space either side of the thumb.
    static var thumbGap: CGFloat { stroke + thumbWidth / 2 + 2 }
    /// How long the wave takes to grow or flatten when playback starts or stops.
    static let easeSeconds: TimeInterval = 0.3
    /// How fast the wave travels while playing, in points per second.
    static let travel: CGFloat = 24
    /// Steady animation is drawn at this rate; more is not visible.
    static let steadyInterval: TimeInterval = 1.0 / 24

    static func smoothstep(_ t: Double) -> Double { let x = min(1, max(0, t)); return x * x * (3 - 2 * x) }

    /// Wave height at `elapsed` seconds after the play state changed, easing between the two extremes with a smoothstep.
    static func amplitude(playing: Bool, elapsed: TimeInterval, from start: CGFloat) -> CGFloat {
        let target: CGFloat = playing ? maxAmplitude : 0
        return start + (target - start) * CGFloat(smoothstep(elapsed / easeSeconds))
    }

    /// Vertical displacement at `x` of the played section that ends at `end`: a sine that fades in over `taper` points at the start and out
    /// over `taper` points before the end.
    static func displacement(x: CGFloat, end: CGFloat, amplitude: CGFloat, phase: CGFloat) -> CGFloat {
        guard end > 0, x >= 0, x <= end else { return 0 }
        let fade = min(1, x / taper, (end - x) / taper)
        return amplitude * max(0, fade) * sin(2 * .pi * x / wavelength - phase)
    }

    /// Phase after `time` seconds of travelling.
    static func phase(time: TimeInterval) -> CGFloat { CGFloat(time) * travel / wavelength * 2 * .pi }

    /// The thumb's x for a fraction of the bar's width.
    static func thumbX(fraction: Double, width: CGFloat) -> CGFloat { CGFloat(min(1, max(0, fraction))) * width }
}

// MARK: zoom

/// Page zoom for Music (Command plus, minus and zero). Stored for the next launch.
@MainActor @Observable
final class MusicZoom {
    static let shared = MusicZoom()
    nonisolated static let steps: [CGFloat] = [0.7, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]
    private static let key = "music.zoom"

    private(set) var scale: CGFloat

    init(defaults: UserDefaults = .standard) {
        let saved = defaults.object(forKey: Self.key) as? Double
        scale = saved.map { Self.nearest(CGFloat($0)) } ?? 1
        self.defaults = defaults
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// The step closest to a stored value, so an edited preference file cannot produce an unusable scale.
    nonisolated static func nearest(_ v: CGFloat) -> CGFloat {
        guard v.isFinite else { return 1 }
        return steps.min { abs($0 - v) < abs($1 - v) } ?? 1
    }

    nonisolated static func next(from s: CGFloat, up: Bool) -> CGFloat {
        let i = steps.firstIndex(of: nearest(s)) ?? 3
        return steps[min(steps.count - 1, max(0, i + (up ? 1 : -1)))]
    }

    func zoomIn() { set(Self.next(from: scale, up: true)) }
    func zoomOut() { set(Self.next(from: scale, up: false)) }
    func reset() { set(1) }

    private func set(_ s: CGFloat) {
        guard s != scale else { return }
        scale = s
        defaults.set(Double(s), forKey: Self.key)
    }
}

// MARK: reload

/// F5 in Music: every page that reads from the network is rebuilt, so it fetches again. The Music view carries `generation` as its identity.
@MainActor @Observable
final class MusicReload {
    static let shared = MusicReload()
    private(set) var generation = 0
    func request() { generation += 1 }
}
