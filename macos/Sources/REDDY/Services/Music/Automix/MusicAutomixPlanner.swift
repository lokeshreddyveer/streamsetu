import Foundation

// The decision ladder: given what the analyzer knows about the song that is ending and the one that follows, choose how to join them.
// It is a pure function. Every rung exists to keep a bad mix from happening: when in doubt it steps down to the plain fade, and the plain
// fade steps down to what the player already did before Automix existed. The outgoing song is never time-stretched (a song the listener is
// hearing must keep its own pulse); only the incoming song, which has not been heard yet, may be nudged to match.

enum MusicAutomixStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Fades only, but placed at the real end of each song (after trailing silence). No tempo matching or filtering.
    case fadeOnly
    /// Beat-matched overlaps with a gentle hand-over of the low end.
    case smooth
    /// Beat-matched overlaps with a sharper, shorter low-end swap on a bar line.
    case club

    var id: String { rawValue }
    var title: String {
        switch self { case .fadeOnly: "Fade at the true end"; case .smooth: "Smooth"; case .club: "Club" }
    }
    var detail: String {
        switch self {
        case .fadeOnly: "A plain crossfade that starts when the music really ends, not when the file does."
        case .smooth: "Matches the beat and blends the bass over several bars."
        case .club: "Matches the beat and swaps the bass on a bar line."
        }
    }
}

struct MusicAutomixSettings: Codable, Equatable, Sendable {
    var enabled = false
    var style: MusicAutomixStyle = .smooth
    /// 0...1: how long the overlaps run and how far the next song's tempo may be stretched.
    var strength = 0.5

    init() {}
    init(enabled: Bool = false, style: MusicAutomixStyle = .smooth, strength: Double = 0.5) {
        self.enabled = enabled; self.style = style; self.strength = min(1, max(0, strength))
    }

    private enum CodingKeys: String, CodingKey { case enabled, style, strength }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        style = (try? c.decodeIfPresent(MusicAutomixStyle.self, forKey: .style)) ?? .smooth
        let s = try c.decodeIfPresent(Double.self, forKey: .strength) ?? 0.5
        strength = s.isFinite ? min(1, max(0, s)) : 0.5
    }
}

/// What the planner needs to know about a song beyond its audio.
struct MusicTrackFacts: Equatable, Sendable {
    var title = ""
    var album = ""
    var artist = ""
    var duration: Double = 0
}

struct MusicMixPlan: Equatable, Sendable {
    enum Kind: String, Sendable { case beatMatched, filterRide }
    var kind: Kind
    /// Outgoing-file second at which the overlap begins, and how many real seconds it lasts (the outgoing song plays at its own speed).
    var outStart: Double
    var overlap: Double
    /// Incoming-file second that plays at the start of the overlap, and the playback rate it plays at during it (1 = untouched).
    var inCue: Double
    var inRate: Double
    /// Length of one outgoing beat, or 0 when no trusted grid.
    var beatSeconds: Double
    /// One grid unit of the incoming song in its own seconds (its beat, or half or double of it after octave folding).
    var inUnit: Double
    /// Fraction (0...1) of the overlap at which the low end changes hands.
    var bassSwapAt: Double
    /// How abrupt the swap is: the fraction of the overlap it takes.
    var bassSwapWidth: Double
    /// Grid units over which the incoming tempo eases back to normal after the overlap.
    var easeUnits: Int
    var reasons: [String]

    var outEnd: Double { outStart + overlap }
    /// Incoming-file second reached when the overlap ends.
    var inEnd: Double { inCue + overlap * inRate }
    /// Incoming-file second where the player takes over, after the tempo has eased back to 1.
    var handoverMedia: Double { inEnd + Double(easeUnits) * inUnit }
    /// Real seconds the incoming deck keeps playing after the overlap while the tempo eases back.
    var easeSeconds: Double { MusicRateEase.wallSeconds(startRate: inRate, units: easeUnits, unit: inUnit) }
}

enum MusicAutomixDecision: Equatable, Sendable {
    /// Let the player do what it would have done without Automix.
    case fallback(String)
    /// A plain equal-power fade timed to the real end of the song: `contentEnd` is where the music stops.
    case trueEndFade(contentEnd: Double, reason: String)
    case mix(MusicMixPlan)
}

struct MusicAutomixInput: Sendable {
    var outgoing: MusicTrackFacts
    var incoming: MusicTrackFacts
    var outgoingAnalysis: MusicTrackAnalysis?
    var incomingAnalysis: MusicTrackAnalysis?
    /// Where the outgoing song is now, in its own seconds.
    var position: Double
    /// The listener's own tempo; Automix only runs at 1.
    var listenerTempo: Double = 1
    var settings: MusicAutomixSettings
}

enum MusicAutomixPlanner {
    // MARK: constants (each with its reason)

    /// A song under 40 s is a sketch or an interlude; nothing is mixed around it.
    static let minTrackSeconds = 40.0
    /// The grid is trusted for beat matching at this confidence...
    static let matchFloor = 0.5
    /// ...and for any tempo-aware behaviour at all above this one. If both songs are under it the pair is joined with a plain fade.
    static let assistFloor = 0.25
    /// The next song's tempo may be sped up by up to `4% + 8% * strength` and slowed by half of that: speeding up stays clean further
    /// than slowing down, which smears. At the default strength that is +8% and -4%.
    static func stretchWindow(strength: Double) -> ClosedRange<Double> {
        let up = 0.04 + 0.08 * strength
        return (1 - up / 2)...(1 + up)
    }
    /// Never leave a song early if that throws away more than this many seconds of music that is still audible.
    static let maxSkippedMusic = 10.0
    /// An overlap runs from 4 s to 20 s, and never more than 35% of either song.
    static let minOverlap = 4.0, maxOverlap = 20.0, maxOverlapShare = 0.35
    /// The incoming song may not be entered later than a quarter of the way into it.
    static let maxCueShare = 0.25
    /// The planner needs this much time before the overlap starts to prepare; a plan that is already this late is dropped.
    static let leadSeconds = 1.0
    /// A song may be this much late (seconds) and the renderer will skip into the plan instead of dropping it.
    static let lateTolerance = 1.5
    /// Tempo of the incoming song eases back toward normal by this much per grid unit (about a 1.5 s audible glide per 1%).
    static let easeStep = 0.005

    // MARK: metadata gates

    static func isSpokenWord(_ f: MusicTrackFacts) -> Bool {
        let hay = [f.title, f.album, f.artist].joined(separator: " ").lowercased()
        return ["podcast", "episode", "audiobook", "audio book", "sermon", "lecture", "stand-up", "standup", "interview"].contains { hay.contains($0) }
    }

    /// A live recording by its labels: "(Live)", "[Live at X]", "- Live", "Live: ...", or an album named "Live at/from/in/on ...".
    /// The bare word in "Live It Up" or an artist called Live does not count.
    static func isLive(_ f: MusicTrackFacts) -> Bool {
        func marked(_ s: String) -> Bool {
            let t = s.lowercased()
            if t.contains("(live") || t.contains("[live") || t.hasSuffix("- live") || t.contains(" - live ") || t.hasPrefix("live:") || t.contains(" live at ") || t.contains(" (live)") { return true }
            return ["live at ", "live from ", "live in ", "live on "].contains { t.hasPrefix($0) }
        }
        return marked(f.title) || marked(f.album)
    }

    // MARK: musical helpers

    /// Halves or doubles `bpm` until it is within 0.7...1.4 of `reference`, so 70 against 140 count as the same pulse.
    static func fold(_ bpm: Double, toward reference: Double) -> (bpm: Double, factor: Double) {
        guard bpm > 0, reference > 0 else { return (bpm, 1) }
        var b = bpm, f = 1.0
        while b / reference > 1.4 { b /= 2; f *= 2 }
        while b / reference < 0.7 { b *= 2; f /= 2 }
        return (b, f)
    }

    /// Two keys sit well together when they are the same, a fourth or fifth apart, or relative or parallel major and minor.
    static func keysCompatible(_ a: (root: Int, minor: Bool), _ b: (root: Int, minor: Bool)) -> Bool {
        let d = min((a.root - b.root + 12) % 12, (b.root - a.root + 12) % 12)
        if a.minor == b.minor { return [0, 1, 2, 5].contains(d) }
        let (maj, min_) = a.minor ? (b, a) : (a, b)
        return (maj.root + 9) % 12 == min_.root || d == 0
    }

    private static func keyIfTrusted(_ a: MusicTrackAnalysis) -> (root: Int, minor: Bool)? {
        guard let r = a.keyRoot, a.keyConfidence >= 0.3 else { return nil }
        return (r, a.keyIsMinor)
    }

    /// Seconds of still-audible music (energy at least 10%) after `t` and before the true end.
    static func audibleAfter(_ t: Double, in a: MusicTrackAnalysis) -> Double {
        var total = 0.0
        var s = t
        while s < a.contentEnd {
            if a.energy(at: s) >= 0.10 { total += MusicBeatAnalyzer.energyStep }
            s += MusicBeatAnalyzer.energyStep
        }
        return total
    }

    private static func meanEnergy(_ a: MusicTrackAnalysis, from: Double, to: Double) -> Double {
        guard to > from else { return 1 }
        var sum = 0.0, n = 0.0
        var t = from
        while t < to { sum += Double(a.energy(at: t)); n += 1; t += MusicBeatAnalyzer.energyStep }
        return n > 0 ? sum / n : 1
    }

    // MARK: the ladder

    static func decide(_ input: MusicAutomixInput) -> MusicAutomixDecision {
        let s = input.settings
        // 1. Off.
        guard s.enabled else { return .fallback("Automix is off") }
        // 2. Anything the listener changed that Automix does not model.
        guard abs(input.listenerTempo - 1) < 0.001 else { return .fallback("Tempo is not normal") }
        // 3. Unknown or short songs.
        let od = input.outgoing.duration, id = input.incoming.duration
        guard od > 0, id > 0 else { return .fallback("Length unknown") }
        guard od >= minTrackSeconds, id >= minTrackSeconds else { return .fallback("Song too short to mix") }
        // 4. Speech and live recordings are never mixed: a beat grid means nothing there.
        if isSpokenWord(input.outgoing) || isSpokenWord(input.incoming) { return .fallback("Spoken word") }
        if isLive(input.outgoing) || isLive(input.incoming) { return .fallback("Live recording") }
        // 5. Analysis must exist, have worked, and describe the copy that plays.
        guard let out = input.outgoingAnalysis, !out.failed, abs(out.duration - od) <= MusicAnalysisCache.lengthTolerance, out.contentEnd > 0 else {
            return .fallback("Not analysed yet")
        }
        let trueEnd = out.contentEnd
        let tailGap = od - trueEnd
        // 6. Fade-only style, or no usable next song: the fade still starts at the real end.
        func plain(_ why: String) -> MusicAutomixDecision {
            tailGap >= 0.5 ? .trueEndFade(contentEnd: trueEnd, reason: why) : .fallback(why)
        }
        if s.style == .fadeOnly { return plain("Fade style") }
        guard let inc = input.incomingAnalysis, !inc.failed, abs(inc.duration - id) <= MusicAnalysisCache.lengthTolerance else {
            return plain("Next song not analysed")
        }
        // 7. Is there a pulse to work with?
        guard out.hasGrid, inc.hasGrid, out.bpm >= 60, out.bpm <= 210, inc.bpm >= 60, inc.bpm <= 210 else { return plain("No steady beat") }
        if out.confidence < assistFloor, inc.confidence < assistFloor { return plain("Beat not clear") }
        // 8. Tempo relationship.
        let folded = fold(inc.bpm, toward: out.bpm)
        let rate = ((out.bpm / folded.bpm) * 10_000).rounded() / 10_000
        let window = stretchWindow(strength: s.strength)
        let reachable = window.contains(rate)
        let confident = out.confidence >= matchFloor && inc.confidence >= matchFloor
        let kind: MusicMixPlan.Kind
        if confident && reachable { kind = .beatMatched }
        else if min(out.confidence, inc.confidence) >= assistFloor { kind = .filterRide }
        else { return plain("Beat not clear enough to blend") }
        let useRate = kind == .beatMatched ? rate : 1.0
        let beat = out.beatInterval

        // 9. Overlap length: in whole bars of the outgoing song.
        var beats = 4 * (2 + Int((6 * s.strength).rounded()))                 // 8 ... 32 beats
        var reasons: [String] = [kind == .beatMatched ? "Beat matched" : "Filter blend"]
        if let ka = keyIfTrusted(out), let kb = keyIfTrusted(inc), !keysCompatible(ka, kb) {
            beats = min(beats, 8); reasons.append("Keys clash: short overlap")
        }
        let calm = meanEnergy(out, from: trueEnd - 8 * beat, to: trueEnd) < 0.5 && meanEnergy(inc, from: inc.audibleStart, to: inc.audibleStart + 8 * inc.beatInterval) < 0.5
        if calm { beats = min(32, beats * 2); reasons.append("Quiet join: longer overlap") }
        if kind == .filterRide { beats = min(beats, 16) }
        var overlap = Double(beats) * beat
        let cap = min(maxOverlap, maxOverlapShare * min(trueEnd, id))
        if overlap > cap {
            let bars = Int((cap / (4 * beat)).rounded(.down))
            guard bars >= 2 else { return plain("No room for a blend") }
            overlap = Double(bars * 4) * beat
        }
        if overlap < minOverlap {
            let bars = Int((minOverlap / (4 * beat)).rounded(.up))
            overlap = Double(bars * 4) * beat
        }

        // 10. Where the overlap ends on the outgoing song: its best exit, unless that would throw away too much music.
        var exit = out.mixOut.max { ($0.score, $0.time) < ($1.score, $1.time) }?.time ?? trueEnd
        exit = min(exit, trueEnd)
        if audibleAfter(exit, in: out) > maxSkippedMusic { exit = trueEnd; reasons.append("Waited for the end") }
        // The overlap ends a fraction of a second before the file does, so the player's own end-of-file never fires during a mix.
        exit = min(exit, od - 0.5)
        let bars = out.downbeats
        var start = exit - overlap
        if let bar = bars.last(where: { $0 <= start + 0.05 }) { start = bar }
        guard start >= 0 else { return plain("Song ends too soon for a blend") }
        // 11. Not in the past.
        if input.position > start + lateTolerance { return plain("Too late to blend") }
        guard start - input.position >= -lateTolerance else { return plain("Too late to blend") }

        // 12. Where the incoming song enters: its intro lands inside the overlap, on a bar line, never past a quarter of the song.
        let mediaOverlap = overlap * useRate
        let first = inc.mixIn.first { $0.kind == .firstBar }?.time ?? inc.audibleStart
        var cue = first
        if let intro = inc.mixIn.first(where: { $0.kind == .introEnd }) {
            let wanted = intro.time - mediaOverlap
            if wanted > first, let bar = inc.downbeats.last(where: { $0 <= wanted + 0.05 }) { cue = bar }
        }
        cue = min(cue, id * maxCueShare)
        if let bar = inc.downbeats.last(where: { $0 <= cue + 0.05 }), bar >= first - 0.05 { cue = bar }
        guard cue + mediaOverlap < id - 5 else { return plain("Next song too short for a blend") }

        // 13. The low end changes hands once, on a bar line about 70% of the way through.
        let swapBeat = max(4, Int((0.7 * Double(beats) / 4).rounded()) * 4)
        let swapAt = min(0.85, max(0.3, Double(swapBeat) * beat / overlap))
        let width = s.style == .club ? 0.5 * beat / overlap : min(0.4, 4 * beat / overlap)
        // 14. How long the incoming tempo takes to ease back.
        // Halved tempo (factor 2) means a grid unit is two beats; doubled (factor 0.5) means half a beat.
        let unit = inc.beatInterval * folded.factor
        let ease = abs(useRate - 1) < 0.0001 ? 0 : min(32, Int((abs(useRate - 1) / easeStep / 4).rounded(.up)) * 4)
        return .mix(MusicMixPlan(kind: kind, outStart: start, overlap: overlap, inCue: cue, inRate: useRate, beatSeconds: beat,
                                 inUnit: unit, bassSwapAt: swapAt, bassSwapWidth: width, easeUnits: ease, reasons: reasons))
    }
}

/// The incoming deck's tempo glides back to normal one grid unit at a time, so the pitch-preserving stretch is never held for long.
enum MusicRateEase {
    /// Rate during grid unit `k` (0-based) of the ease: the starting rate moved toward 1 by `step` per unit, stopping at 1.
    static func rate(startRate: Double, unit k: Int, step: Double = MusicAutomixPlanner.easeStep) -> Double {
        let delta = Double(k) * step
        return startRate > 1 ? max(1, startRate - delta) : min(1, startRate + delta)
    }

    /// Real seconds `units` grid units take while easing (each unit of `unit` media seconds plays at its own rate).
    static func wallSeconds(startRate: Double, units: Int, unit: Double, step: Double = MusicAutomixPlanner.easeStep) -> Double {
        guard units > 0 else { return 0 }
        return (0..<units).reduce(0) { $0 + unit / rate(startRate: startRate, unit: $1, step: step) }
    }
}
