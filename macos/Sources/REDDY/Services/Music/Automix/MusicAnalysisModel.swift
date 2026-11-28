import Foundation

/// What the analyzer learned about one song. Plain data so it can be cached, tested and handed to the planner. All times are seconds on
/// the song's own timeline, measured on the copy that was decoded (the planner rejects a copy whose length differs by more than a second).
struct MusicTrackAnalysis: Codable, Equatable, Sendable {
    /// Bump when any stored number is computed differently. An old entry is dropped, never migrated: a wrong beat grid is worse than none.
    static let schemaVersion = 1

    enum PointKind: String, Codable, Sendable { case firstBar, introEnd, phrase, outroStart, contentEnd, lastPhrase }

    /// A place where a mix may begin (on an incoming song) or end (on an outgoing one), with the analyzer's own opinion of it (0...1).
    struct MixPoint: Codable, Equatable, Sendable {
        var time: Double
        var kind: PointKind
        var score: Double
    }

    var schema = MusicTrackAnalysis.schemaVersion
    var duration: Double = 0
    /// Beats per minute, or 0 when no steady pulse was found.
    var bpm: Double = 0
    /// How much to trust the beat grid, 0...1.
    var confidence: Double = 0
    /// Beat times in seconds, rounded to a millisecond.
    var beats: [Double] = []
    /// Which beat (0...3) counts as the first of a bar.
    var downbeatOffset = 0
    /// Pitch class of the key, 0 = C ... 11 = B, or nil when unknown.
    var keyRoot: Int?
    var keyIsMinor = false
    var keyConfidence: Double = 0
    /// First moment the song is audible, and the last (the true end, after any trailing silence).
    var audibleStart: Double = 0
    var contentEnd: Double = 0
    /// Where a fade-out or quiet outro begins, when there is one.
    var outroStart: Double?
    /// Loudness every half second, 0...1 against the song's own loud level.
    var energy: [Float] = []
    var mixIn: [MixPoint] = []
    var mixOut: [MixPoint] = []
    /// True when the file could not be decoded or was too short: the entry exists so the work is not repeated.
    var failed = false

    var beatInterval: Double { bpm > 0 ? 60 / bpm : 0 }
    var hasGrid: Bool { bpm > 0 && beats.count >= 8 }

    /// Bar starts: every fourth beat from the downbeat offset.
    var downbeats: [Double] {
        guard hasGrid else { return [] }
        return stride(from: min(max(0, downbeatOffset), 3), to: beats.count, by: 4).map { beats[$0] }
    }

    /// Half-second energy at time `t`, or 0 outside the curve.
    func energy(at t: Double) -> Float {
        let i = Int(t / MusicBeatAnalyzer.energyStep)
        return i >= 0 && i < energy.count ? energy[i] : 0
    }

    static func failedEntry(duration: Double) -> MusicTrackAnalysis {
        var a = MusicTrackAnalysis(); a.duration = duration; a.failed = true; return a
    }
}
