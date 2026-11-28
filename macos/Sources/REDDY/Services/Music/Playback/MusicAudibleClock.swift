import Foundation

/// Whether sound is really coming out: the lyrics (and any other clock that must follow the audio) run only while the player's own position is
/// moving. "The person pressed play", "a song is loading" and "the player is buffering" are not sound. Pure value logic; the caller supplies
/// every time (a monotonic clock in seconds), so tests drive it with synthetic readings.
struct MusicAudibleClock: Sendable, Equatable {
    /// What the lyrics should show.
    enum State: Sendable, Equatable {
        case idle, loading, buffering, paused, playing

        /// The line is held (no advance) in every state but `.playing`.
        var holdsLine: Bool { self != .playing }
        /// A short plain phrase for the lyrics panel while the line is held for a reason the person should know about.
        var holdNote: String? {
            switch self {
            case .loading: return "Starting the song"
            case .buffering: return "Buffering"
            default: return nil
            }
        }
    }

    /// A position that has not moved for this long is not advancing. The player reports four times a second.
    static let staleSeconds = 1.2
    /// One report may move the position by at most this much and still be natural playback; a larger step is a seek and is confirmed by the next.
    static let naturalStepSeconds = 2.0
    /// Smaller than this is noise.
    static let noiseSeconds = 0.005

    private(set) var lastPosition: Double?
    private(set) var lastAdvanceAt: TimeInterval?

    init() {}

    mutating func reset() { lastPosition = nil; lastAdvanceAt = nil }

    /// The player reported `position` (seconds into the song) at monotonic time `at`.
    mutating func observe(position: Double, at: TimeInterval) {
        guard position.isFinite else { return }
        defer { lastPosition = position }
        guard let last = lastPosition else { return }
        let step = position - last
        if step > Self.noiseSeconds, step <= Self.naturalStepSeconds { lastAdvanceAt = at }
        else if step < -Self.noiseSeconds || step > Self.naturalStepSeconds { lastAdvanceAt = nil }   // a seek or a restart: wait for the next report
    }

    /// True when the position moved a moment ago (within `staleSeconds`).
    func isMoving(now: TimeInterval) -> Bool {
        guard let at = lastAdvanceAt else { return false }
        return now - at <= Self.staleSeconds
    }

    func state(wantsToPlay: Bool, loading: Bool, buffering: Bool, now: TimeInterval) -> State {
        if loading { return wantsToPlay ? .loading : .idle }
        guard wantsToPlay else { return .paused }
        // The position is the truth: a position that is moving beats a buffering flag that may be stale (a missed or reordered status change).
        return isMoving(now: now) ? .playing : .buffering
    }

    func advancing(wantsToPlay: Bool, loading: Bool, buffering: Bool, now: TimeInterval) -> Bool {
        state(wantsToPlay: wantsToPlay, loading: loading, buffering: buffering, now: now) == .playing
    }
}
