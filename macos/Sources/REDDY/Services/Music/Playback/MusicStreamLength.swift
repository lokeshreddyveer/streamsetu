import Foundation

// A song's catalogue length is the truth for the screen; a stream's own length is only evidence. This file holds the pure rules:
// how far a stream may differ from the catalogue, what the player shows and where it ends a song whose stream is reported longer than
// the song, and the silent-tail net for any stream whose sound ends before its clock does.

enum MusicLengthFit: Equatable, Sendable { case ok, tooLong, tooShort }

enum MusicStreamLength {
    /// The most a stream may differ from the catalogue before it is a different recording: the larger of 15 s and 12 percent of the song.
    static func tolerance(listed: Double) -> Double { max(15, listed * 0.12) }

    static func fit(listed: Double, declared: Double?) -> MusicLengthFit {
        guard listed > 0, let declared, declared > 0 else { return .ok }
        let tol = tolerance(listed: listed)
        if declared > listed + tol { return .tooLong }
        if declared < listed - tol { return .tooShort }
        return .ok
    }

    /// The length a stream states about itself. YouTube addresses carry it as `dur=` (seconds, fractional); other hosts say nothing.
    static func declaredSeconds(of stream: MusicStream) -> Double? { declaredSeconds(url: stream.url) }

    static func declaredSeconds(url: String) -> Double? {
        guard let items = URLComponents(string: url)?.queryItems,
              let v = items.first(where: { $0.name == "dur" })?.value, let d = Double(v), d.isFinite, d > 0 else { return nil }
        return d
    }

    /// A song that runs past its catalogue length is ended this long after it: the smaller of 5 s and 2 percent.
    static func endTolerance(listed: Double) -> Double { min(5, listed * 0.02) }

    /// What the player does with a loaded item whose reported length is `reported`.
    struct Plan: Equatable, Sendable {
        /// The length shown in the bar, the panel and the lock screen.
        var shown: Double
        /// Where the song is ended and the queue moves on; nil leaves the end to the file.
        var endAt: Double?
        /// True when the reported length is wrong for this stream (the stream itself says it is as long as the catalogue): the stream is kept.
        var playerMisreads: Bool
        /// True when the recording really is a different cut (the stream says so too): the old rule may try another candidate once.
        var differentCut: Bool
    }

    static func plan(listed: Double, reported: Double, declared: Double?) -> Plan {
        guard listed > 0, reported > 0 else { return Plan(shown: reported, endAt: nil, playerMisreads: false, differentCut: false) }
        let tol = tolerance(listed: listed)
        if abs(reported - listed) <= tol { return Plan(shown: reported, endAt: nil, playerMisreads: false, differentCut: false) }
        let streamAgrees = fit(listed: listed, declared: declared) == .ok && declared != nil
        let longer = reported > listed
        // The stream itself says it is longer than the catalogue (its own `dur` agrees with what the player reports): the catalogue length is the wrong one (an extended
        // cut, a wrong listing), and ending such a song at the catalogue length skipped real songs a few minutes in. With no such statement the old rule stands: a video
        // that runs past the song (an outro, black frames) is cut at the song's length.
        // (A file about twice as long is a different cut or a loop, not a longer version of the song.)
        let streamSaysLonger = declared.map { $0 > listed + tol && abs($0 - reported) <= tolerance(listed: reported) && reported <= listed * 1.6 } ?? false
        if streamSaysLonger { return Plan(shown: reported, endAt: nil, playerMisreads: false, differentCut: false) }
        return Plan(shown: listed, endAt: longer ? listed + endTolerance(listed: listed) : nil,
                    playerMisreads: streamAgrees, differentCut: !streamAgrees)
    }

    // MARK: seek bar

    static func fraction(position: Double, shown: Double) -> Double { shown > 0 ? min(1, max(0, position / shown)) : 0 }
    static func seekTarget(fraction: Double, shown: Double) -> Double { shown > 0 ? min(1, max(0, fraction)) * shown : 0 }
}

/// Safety net for any stream: the sound is silent for too long near or past the end of the song, while the clock keeps running.
/// Fed the level of the sound when something measures it; with no level (`nil`) only the clock rules apply, which is the trim in `plan`.
struct MusicSilentTail: Equatable, Sendable {
    var listed: Double
    var declared: Double?
    private(set) var silentSince: Double?
    /// Level (RMS, 0...1) under which sound counts as silent.
    static let floor: Float = 0.0015
    static let pastEndSeconds = 8.0
    static let lateSeconds = 12.0

    init(listed: Double, declared: Double?) { self.listed = listed; self.declared = declared }

    /// True when the song should end now. `position` is the playback position in seconds.
    mutating func feed(position: Double, level: Float?) -> Bool {
        guard listed > 0 else { return false }
        guard let level, level < Self.floor else { silentSince = nil; return false }
        if silentSince == nil { silentSince = position }
        let silent = position - (silentSince ?? position)
        if position >= listed, silent > Self.pastEndSeconds { return true }
        if let declared, declared > listed, position >= listed * 0.8, silent > Self.lateSeconds { return true }
        return false
    }
}

/// What the player keeps for the song that is playing: the plan for its reported length and the one-time end.
struct MusicLengthTrim: Equatable, Sendable {
    private(set) var plan: MusicStreamLength.Plan?
    private(set) var ended = false

    /// The length to show: the catalogue length when the player's own is wrong for this song, otherwise the player's.
    mutating func adopt(listed: Double, reported: Double, declared: Double?) -> Double {
        let p = MusicStreamLength.plan(listed: listed, reported: reported, declared: declared)
        plan = p
        return p.shown
    }

    /// True once, when the position has reached the trimmed end.
    mutating func shouldEnd(position: Double) -> Bool {
        guard !ended, let end = plan?.endAt, position >= end else { return false }
        ended = true
        return true
    }

    mutating func reset() { plan = nil; ended = false }
}

/// The resolver's choice between a video stream and its audio twin when the video's own length is off the catalogue.
enum MusicLengthGate {
    enum Choice: Equatable, Sendable { case keepVideo, useTwin }

    /// The twin wins only when it fits the catalogue length and the video does not; with no better version the video plays (and is trimmed).
    static func choose(listed: Double, videoDeclared: Double?, twinDeclared: Double?) -> Choice {
        guard MusicStreamLength.fit(listed: listed, declared: videoDeclared) != .ok else { return .keepVideo }
        guard let twinDeclared, MusicStreamLength.fit(listed: listed, declared: twinDeclared) == .ok else { return .keepVideo }
        return .useTwin
    }

    /// Whether the twin should be looked for at all.
    static func needsTwin(listed: Double, videoDeclared: Double?) -> Bool { MusicStreamLength.fit(listed: listed, declared: videoDeclared) != .ok }
}
