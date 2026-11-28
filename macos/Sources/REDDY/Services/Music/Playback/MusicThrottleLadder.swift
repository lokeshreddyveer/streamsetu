import Foundation

/// What to do when a source says "busy, retry later". The same track is tried again and is never skipped: the wait starts at 2 s and doubles
/// per refusal in a row up to 30 s. Only the first refusal is announced. After `maxRefusals` in a row the track is held until the person
/// presses play. A source's own "retry after" is honoured but never waits longer than the cap.
struct MusicThrottleLadder: Sendable, Equatable {
    static let firstWait: TimeInterval = 2
    static let cap: TimeInterval = 30
    static let maxRefusals = 6

    enum Step: Equatable, Sendable {
        case wait(TimeInterval, announce: Bool)
        case hold
    }

    private(set) var refusals = 0

    mutating func refused(retryAfter: TimeInterval? = nil) -> Step {
        refusals += 1
        guard refusals <= Self.maxRefusals else { return .hold }
        var wait = min(Self.cap, Self.firstWait * pow(2, Double(refusals - 1)))
        if let r = retryAfter, r.isFinite, r > wait { wait = min(Self.cap, r) }
        return .wait(wait, announce: refusals == 1)
    }

    /// A song played, the row changed, or the person pressed play.
    mutating func reset() { refusals = 0 }
}

/// Whether a failure at the tail of the queue wraps (repeat-all) instead of stopping: only when some other row is still playable.
/// If every other row is blocked or has failed this run, the queue stops, so a queue where nothing resolves never spins.
enum MusicWrapRule {
    static func wraps(repeatMode: MusicRepeat, current: Int, playable: [Bool]) -> Bool {
        guard repeatMode == .all, playable.indices.contains(current) else { return false }
        return playable.indices.contains { $0 != current && playable[$0] }
    }
}
