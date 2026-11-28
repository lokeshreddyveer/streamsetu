import Foundation

/// One reading of the player: where the song was, when that was measured (not when it arrived), whether the song is advancing, and a
/// token that changes on every announced jump (a seek, a skip, a restart or a change of the lyric offset).
struct MusicLyricClockReading: Sendable, Equatable {
    var positionMs: Double
    /// A monotonic time in seconds, from the moment the position was read.
    var takenAt: TimeInterval
    var token: Int
    var advancing: Bool

    init(positionMs: Double, takenAt: TimeInterval, token: Int = 0, advancing: Bool = true) {
        self.positionMs = positionMs; self.takenAt = takenAt; self.token = token; self.advancing = advancing
    }
}

/// The clock the lyrics are drawn from. The player reports about twice a second; the clock is asked for its position on every frame and
/// is steered by the readings, never set by them. Nothing but an announced jump moves the position backwards, a reading that disagrees
/// is held until a second one agrees, and the playback rate (1.25x, 1.5x) is learned from the readings so the lyrics stay in step.
/// Pure value logic: the caller supplies every time, so tests drive it with synthetic readings.
struct MusicLyricClock: Sendable {
    enum Tuning {
        /// A reading may differ from the prediction by this much plus a share of the time since the anchor.
        static let outlierBaseMs = 250.0
        static let outlierShare = 0.20
        static let outlierShareUnsettled = 0.75
        /// Refused readings in a row after which the next one is taken whatever it says.
        static let maxRefused = 2
        /// The display closes a gap with this time constant, at most 25% faster and at most 50% slower than the song runs.
        static let correctionSeconds = 0.6
        static let maxSlew = 1.25
        static let minSlew = 0.5
        /// Behind by this much: glide forward over 260 ms instead of running fast.
        static let glideThresholdMs = 300.0
        static let glideSeconds = 0.26
        /// Off by this much either way (confirmed): jump.
        static let lostMs = 3_000.0
        /// An announced jump within this distance rolls over; farther is at once.
        static let rollLimitMs = 2_000.0
        static let rateWindowSeconds = 4.0
        static let rateMinSpanSeconds = 0.9
        static let rateHistory = 16
        static let rateNudgePairSeconds = 0.3
        static let minRate = 0.25
        static let maxRate = 4.0
    }

    private struct Sample { var positionMs: Double; var at: TimeInterval }
    private struct Roll { var from: Double; var start: TimeInterval; var seconds: Double }

    private(set) var rate: Double = 1
    private(set) var rateSettled = false
    private var anchor: Sample?
    private var history: [Sample] = []
    private var held: Sample?
    private var refused = 0
    private var token = 0
    private var playing = false
    private var display: Double = 0
    private var lastFrame: TimeInterval?
    private var roll: Roll?

    init() {}

    var isRunning: Bool { playing }
    /// The position of the last frame, without advancing.
    var currentMs: Double { display }

    mutating func reset() { self = MusicLyricClock() }

    // MARK: readings

    mutating func ingest(_ r: MusicLyricClockReading) {
        guard r.positionMs.isFinite else { return }
        guard let a = anchor else { startRun(r); return }
        if !r.advancing {
            playing = false
            display = r.positionMs
            anchor = Sample(positionMs: r.positionMs, at: r.takenAt)
            history = []; held = nil; refused = 0; roll = nil
            token = r.token
            return
        }
        if !playing { startRun(r); return }
        if r.token != token {
            token = r.token
            let target = r.positionMs
            history = [Sample(positionMs: target, at: r.takenAt)]
            anchor = history[0]
            held = nil; refused = 0
            if let f = lastFrame, abs(target - display) <= Tuning.rollLimitMs, abs(target - display) > 0.5 {
                roll = Roll(from: display, start: f, seconds: Tuning.glideSeconds)
            } else { display = target; roll = nil }
            return
        }
        let sample = Sample(positionMs: r.positionMs, at: r.takenAt)
        let elapsedMs = max(0, (r.takenAt - a.at) * 1000)
        let share = rateSettled ? Tuning.outlierShare : Tuning.outlierShareUnsettled
        let tolerance = Tuning.outlierBaseMs + share * elapsedMs
        let predicted = a.positionMs + elapsedMs * rate
        if abs(sample.positionMs - predicted) <= tolerance { believe(sample); return }
        if refused > Tuning.maxRefused { startAnchor(sample); return }
        if let h = held {
            let hElapsed = max(0, (sample.at - h.at) * 1000)
            let hPredicted = h.positionMs + hElapsed * rate
            if abs(sample.positionMs - hPredicted) <= Tuning.outlierBaseMs + share * hElapsed {
                startAnchor(h, then: sample)
                return
            }
        }
        held = sample
        refused += 1
    }

    private mutating func startRun(_ r: MusicLyricClockReading) {
        token = r.token
        playing = r.advancing
        display = r.positionMs
        let s = Sample(positionMs: r.positionMs, at: r.takenAt)
        anchor = s
        history = r.advancing ? [s] : []
        held = nil; refused = 0; roll = nil; lastFrame = nil
    }

    /// Both samples become the new anchor (a confirmed disagreement, or a forced take).
    private mutating func startAnchor(_ first: Sample, then second: Sample? = nil) {
        history = [first]
        if let second { history.append(second) }
        anchor = second ?? first
        held = nil; refused = 0
        if history.count == 2 { learnRate() }
    }

    private mutating func believe(_ s: Sample) {
        let previous = history.last
        history.append(s)
        if history.count > Tuning.rateHistory { history.removeFirst(history.count - Tuning.rateHistory) }
        anchor = s
        held = nil; refused = 0
        learnRate(previous: previous)
    }

    private mutating func learnRate(previous: Sample? = nil) {
        guard let newest = history.last else { return }
        let window = history.filter { newest.at - $0.at <= Tuning.rateWindowSeconds }
        if let oldest = window.first, newest.at - oldest.at >= Tuning.rateMinSpanSeconds {
            rate = clampRate((newest.positionMs - oldest.positionMs) / ((newest.at - oldest.at) * 1000))
            rateSettled = true
        } else if let p = previous ?? (history.count >= 2 ? history[history.count - 2] : nil), newest.at - p.at >= Tuning.rateNudgePairSeconds {
            let measured = (newest.positionMs - p.positionMs) / ((newest.at - p.at) * 1000)
            rate = clampRate(rate + (measured - rate) / 2)
        }
    }

    private func clampRate(_ r: Double) -> Double { min(Tuning.maxRate, max(Tuning.minRate, r)) }

    // MARK: frames

    /// Advances the clock to `now` and returns the position to draw, in milliseconds.
    mutating func positionMs(at now: TimeInterval) -> Double {
        // Several timelines (the 15 Hz driver and the rows) ask with their own dates, which can arrive out of order: the clock never goes back,
        // so an older date gets the position already computed and the song's own movement is never counted twice.
        if let last = lastFrame, now < last { return display }
        defer { lastFrame = now }
        guard playing, let a = anchor else { return display }
        let target = a.positionMs + max(0, (now - a.at) * 1000) * rate
        guard let last = lastFrame else { return display }
        let dt = max(0, now - last)
        if let r = roll {
            let t = min(1, max(0, (now - r.start) / r.seconds))
            let s = t * t * (3 - 2 * t)
            display = r.from + (target - r.from) * s
            if t >= 1 { roll = nil }
            return display
        }
        // The gap is measured after the song's own movement since the last frame, so a long pause between frames is not mistaken for lag.
        let natural = dt * 1000 * rate
        let gap = target - (display + natural)
        if abs(gap) >= Tuning.lostMs { display = target; return display }
        if gap >= Tuning.glideThresholdMs {
            roll = Roll(from: display, start: now, seconds: Tuning.glideSeconds)
            return display
        }
        let desired = natural + gap * (1 - exp(-dt / Tuning.correctionSeconds))
        display += min(natural * Tuning.maxSlew, max(natural * Tuning.minSlew, desired))
        return display
    }

    /// Whole milliseconds for line lookup.
    mutating func lyricMs(at now: TimeInterval) -> Int64 { Int64(positionMs(at: now).rounded(.down)) }
}
