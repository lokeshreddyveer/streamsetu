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

    func decide(error: PlaybackError, attempt: Int, current: PlaybackEngineKind, available: Set<PlaybackEngineKind>, isLive: Bool) -> RecoveryAction {
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
            let waits: [TimeInterval] = [3, 5, 8, 12]
            guard attempt < waits.count else { return .giveUp }
            return .retry(after: waits[attempt], reResolve: true)
        case .network, .nameLookup, .timeout, .providerUnavailable, .unknown:
            // A name that cannot be found rarely fixes itself in seconds (a DNS filter), so it gets one retry, then the explanation.
            guard attempt < (error.kind == .unknown || error.kind == .nameLookup ? min(1, maxRetries) : maxRetries) else { return .giveUp }
            return .retry(after: min(maxDelay, baseDelay * pow(2, Double(attempt))), reResolve: true)
        }
    }
}
