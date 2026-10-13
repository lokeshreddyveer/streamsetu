import Foundation

enum RecoveryAction: Equatable, Sendable {
    case retry(after: TimeInterval, reResolve: Bool)
    case switchEngine(PlaybackEngineKind)
    case giveUp
}

/// Decides what to do when playback fails. Bounded and conservative:
/// - transient network problems are retried a few times with backoff, re-resolving the stream URL each time
///   (provider tokens may have expired);
/// - an unsupported format may be offered once to the other engine;
/// - authorization failures are never retried and never worked around.
struct PlaybackRecoveryService: Sendable {
    var maxRetries = 3
    var baseDelay: TimeInterval = 1
    var maxDelay: TimeInterval = 8

    static func busyWaits(isLive: Bool, recentlyRefused: Bool = false) -> [TimeInterval] {
        if isLive { return [3, 5, 8, 12] }
        // A movie the provider refused a few minutes ago is almost always still refused: one more try, then the plain message.
        return recentlyRefused ? [3] : [3, 5, 8]
    }

    func decide(error: PlaybackError, attempt: Int, current: PlaybackEngineKind, available: Set<PlaybackEngineKind>, isLive: Bool, recentlyRefused: Bool = false) -> RecoveryAction {
        switch error.kind {
        case .authorization:
            return .giveUp
        case .unsupportedFormat, .engineUnavailable:
            if attempt == 0, let alt = EngineSelector.fallback(from: current, available: available) { return .switchEngine(alt) }
            return .giveUp
        case .notFound:
            return attempt == 0 ? .retry(after: 0.5, reResolve: true) : .giveUp
        case .providerBusy:
            // The provider still counts the previous stream. It lets go after a few seconds, so wait longer each time (about 30 s in all).
            // A movie that is refused for longer than that is a title the provider isn't serving, which more waiting does not fix.
            let waits = Self.busyWaits(isLive: isLive, recentlyRefused: recentlyRefused)
            guard attempt < waits.count else { return .giveUp }
            return .retry(after: waits[attempt], reResolve: true)
        case .network, .nameLookup, .timeout, .providerUnavailable, .unknown:
            // Providers hand out a different edge server on each try, and only some of those may be blocked, so a blocked name is worth the
            // full set of retries; an unknown error gets one.
            guard attempt < (error.kind == .unknown ? min(1, maxRetries) : maxRetries) else { return .giveUp }
            return .retry(after: min(maxDelay, baseDelay * pow(2, Double(attempt))), reResolve: true)
        }
    }
}
