import Foundation

// Small transport rules as plain values, so each can be tested with a manual clock and no audio:
// seek coalescing, the stale-pause reload and the play/pause echo guard.

// MARK: seek coalescing

/// One seek in flight at a time. A seek asked for meanwhile replaces any earlier waiting one and goes out when the first lands, so a burst
/// of clicks costs two engine seeks, not one per click. Position reports that were already on their way before a seek are ignored.
struct MusicSeekCoalescer: Sendable, Equatable {
    /// Reports far from the target that are tolerated while a seek is in flight; one more means the player never left the old place.
    static let staleTolerance = 2
    /// A report this close before the target (and not past it) is shown as the target, so a click on a lyric line lands on that line.
    static let snapWindow: TimeInterval = 0.1

    private(set) var inFlight: TimeInterval?
    private(set) var waiting: TimeInterval?
    private(set) var staleSeen = 0
    /// Where the last seek landed, until the first report after it has been shown.
    private(set) var landedAt: TimeInterval?

    var isBusy: Bool { inFlight != nil }

    /// A seek was asked for. Returns the target to send now, or nil when one is already in flight (this one waits, replacing any earlier waiting seek).
    mutating func request(_ target: TimeInterval) -> TimeInterval? {
        landedAt = nil
        if inFlight == nil { inFlight = target; staleSeen = 0; return target }
        waiting = target
        return nil
    }

    /// The seek in flight finished. Returns the waiting seek to send next, if any.
    mutating func landed() -> TimeInterval? {
        landedAt = inFlight
        inFlight = nil
        staleSeen = 0
        guard let w = waiting else { return nil }
        waiting = nil
        inFlight = w
        landedAt = nil
        return w
    }

    /// Forget everything (a new track, a stop).
    mutating func reset() { self = MusicSeekCoalescer() }

    enum Report: Equatable, Sendable {
        /// Use this position.
        case accept(TimeInterval)
        /// A report that was already on its way before the seek: drop it.
        case ignore
        /// Too many old reports while a seek was in flight: send this seek again.
        case resend(TimeInterval)
    }

    /// What to do with a position report from the player.
    mutating func report(_ p: TimeInterval) -> Report {
        if let t = inFlight {
            // A report at the target means the seek is already audible, even if its completion has not arrived.
            if abs(p - t) <= Self.snapWindow { return .accept(t) }
            staleSeen += 1
            if staleSeen > Self.staleTolerance { staleSeen = 0; return .resend(waiting ?? t) }
            return .ignore
        }
        if let t = landedAt {
            landedAt = nil
            if p < t, t - p <= Self.snapWindow { return .accept(t) }
        }
        return .accept(p)
    }
}

// MARK: stale pause

/// A stream that was paused for a long time is dead (signed addresses expire, buffers go stale), so play reloads the track at the saved
/// position instead of resuming it. Time asleep counts, because the wall clock keeps running; a clock set back counts as stale.
struct MusicStalePause: Sendable, Equatable {
    static let limit: TimeInterval = 300
    private(set) var since: Date?

    /// The track was paused. A second pause call keeps the earlier moment.
    mutating func paused(at now: Date) { if since == nil { since = now } }

    /// Playing again (or a new load): the pause is over.
    mutating func clear() { since = nil }

    func isStale(at now: Date) -> Bool {
        guard let s = since else { return false }
        let gap = now.timeIntervalSince(s)
        return gap >= Self.limit || gap < 0
    }
}

// MARK: play and pause echo

/// After a person presses play or pause here, an outside command saying the opposite within two seconds is the echo of that press (the
/// system's now-playing view answering back), not a new wish. After two seconds it is believed again.
struct MusicPlayPauseEcho: Sendable, Equatable {
    static let window: TimeInterval = 2
    private var last: (playing: Bool, at: Date, remote: Bool)?

    static func == (a: Self, b: Self) -> Bool { a.last?.playing == b.last?.playing && a.last?.at == b.last?.at && a.last?.remote == b.last?.remote }

    /// A press happened. `remote` is true when it came from an outside command.
    mutating func pressed(playing: Bool, at now: Date, remote: Bool = false) { last = (playing, now, remote) }

    /// Whether an outside command that wants `playing` is the echo of a recent local press.
    func isEcho(wantsPlaying playing: Bool, at now: Date) -> Bool {
        guard let l = last, !l.remote else { return false }
        let gap = now.timeIntervalSince(l.at)
        return gap >= 0 && gap < Self.window && l.playing != playing
    }
}
