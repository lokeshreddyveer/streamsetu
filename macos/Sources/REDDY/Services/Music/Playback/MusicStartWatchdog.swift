import Foundation

/// Decides when a start or a stall has gone on too long. It never waits silently: first a plain notice, then the failure ladder is asked for
/// another path (a fresh lookup, the next candidate, the direct address instead of the loopback proxy). Pure policy: the player supplies the
/// phase and how long it has lasted.
enum MusicStartWatchdog {
    enum Phase: String, Sendable, Equatable, CaseIterable {
        /// Looking up a stream (search, candidates, check).
        case resolving
        /// A stream was found; the player has not reported sound yet.
        case awaitingSound
        /// Sound was heard and then the position stopped moving.
        case midSongStall

        var stage: MusicFailureStage {
            switch self { case .resolving: return .resolve; case .awaitingSound: return .playerItem; case .midSongStall: return .stall }
        }
    }

    struct Limits: Sendable, Equatable {
        var resolve: TimeInterval = 9
        var awaitingSound: TimeInterval = 12
        var midSongStall: TimeInterval = 15
        /// The notice appears at this share of the limit.
        var noticeShare = 0.5
        func limit(_ p: Phase) -> TimeInterval {
            switch p { case .resolving: return resolve; case .awaitingSound: return awaitingSound; case .midSongStall: return midSongStall }
        }
    }

    enum Verdict: Equatable, Sendable {
        case wait
        /// Say once that this is taking longer than usual.
        case notice(String)
        /// Give up on this path; the log line says which stage and how long.
        case fail(reason: String)
    }

    static func notice(_ p: Phase) -> String {
        switch p {
        case .resolving: return "Still looking for this song. Another source will be tried in a few seconds."
        case .awaitingSound: return "This is slow to start. Another source will be tried in a few seconds."
        case .midSongStall: return "The stream stalled. Trying another source shortly."
        }
    }

    static func reason(_ p: Phase, elapsed: TimeInterval) -> String {
        let s = Int(elapsed.rounded())
        switch p {
        case .resolving: return "No stream was found after \(s) s"
        case .awaitingSound: return "The stream did not start after \(s) s"
        case .midSongStall: return "The stream stalled for \(s) s"
        }
    }

    /// `noticed` is true once the notice for this phase has been shown. Offline, nothing is judged: the offline retry owns that case.
    static func verdict(phase: Phase, elapsed: TimeInterval, noticed: Bool, online: Bool = true, limits: Limits = Limits()) -> Verdict {
        guard online, elapsed.isFinite, elapsed >= 0 else { return .wait }
        let limit = limits.limit(phase)
        if elapsed >= limit { return .fail(reason: reason(phase, elapsed: elapsed)) }
        if !noticed, elapsed >= limit * limits.noticeShare { return .notice(notice(phase)) }
        return .wait
    }
}
