import Foundation

// The pure rules for keeping a guest in step with the host. Nothing here touches a player, a network or a timer, so every band can be tested.

enum MusicRoomDriftAction: Equatable, Sendable {
    /// Close enough: leave the player alone.
    case none
    /// Play slightly slower or faster until the gap closes.
    case setRate(Float)
    /// Too far off to nudge: jump to this second.
    case seek(TimeInterval)
}

enum MusicRoomSync {
    /// Below this gap nobody can hear it.
    static let ignoreBelow = 0.08
    /// Above this gap a nudge would take too long, so the guest jumps.
    static let seekAbove = 2.0
    static let slowRate: Float = 0.97
    static let fastRate: Float = 1.03
    /// A nudge lasts at most this long before the gap is measured again.
    static let maxNudgeSeconds = 10.0

    /// `drift` is where the guest is minus where it should be (positive: the guest is ahead). `currentRate` is the rate it plays at now.
    static func decide(drift: Double, currentRate: Float) -> MusicRoomDriftAction {
        guard drift.isFinite else { return .none }
        let size = abs(drift)
        if size < ignoreBelow { return currentRate == 1 ? .none : .setRate(1) }
        if size > seekAbove { return .seek(0) }
        let wanted = drift > 0 ? slowRate : fastRate
        return currentRate == wanted ? .none : .setRate(wanted)
    }

    /// The seek decision with the target filled in.
    static func decide(drift: Double, currentRate: Float, expected: Double) -> MusicRoomDriftAction {
        if case .seek = decide(drift: drift, currentRate: currentRate) { return .seek(max(0, expected)) }
        return decide(drift: drift, currentRate: currentRate)
    }

    /// How long to wait before measuring the gap again after a nudge: the time the nudge needs, never more than the cap.
    static func recheckDelay(forDrift drift: Double) -> TimeInterval {
        let needed = abs(drift) / Double(1 - slowRate) + 0.2
        return min(maxNudgeSeconds, max(0.5, needed))
    }
}

/// Host side: decides when the player's state has changed enough to tell the guests. Between changes nothing is sent but the heartbeat.
struct MusicRoomAnchorTracker: Sendable {
    /// A jump bigger than this between where the host is and where the last anchor said it would be counts as a seek.
    static let seekThreshold = 1.0

    private(set) var last: MusicRoomAnchor?
    private var nextID = 1

    /// A new anchor when the song, the play state or the position changed (or `force`), otherwise nil.
    mutating func observe(track: MusicRoomTrack?, position: Double, isPlaying: Bool, hostNow: Double, force: Bool = false) -> MusicRoomAnchor? {
        let pos = max(0, position.isFinite ? position : 0)
        let isPlaying = isPlaying && track != nil
        if !force, let last {
            let sameTrack = last.track?.key == track?.key
            let samePlay = last.isPlaying == isPlaying
            let expected = last.expectedPosition(atHostTime: hostNow)
            if sameTrack, samePlay, abs(expected - pos) <= Self.seekThreshold { return nil }
        }
        let a = MusicRoomAnchor(id: nextID, track: track, position: pos, hostTime: hostNow, rate: 1, isPlaying: isPlaying)
        nextID += 1
        last = a
        return a
    }

    mutating func reset() { last = nil }
}
