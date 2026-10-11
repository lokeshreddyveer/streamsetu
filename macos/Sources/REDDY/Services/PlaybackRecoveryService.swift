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
        case .network, .timeout, .providerUnavailable, .unknown:
            guard attempt < (error.kind == .unknown ? min(1, maxRetries) : maxRetries) else { return .giveUp }
            return .retry(after: min(maxDelay, baseDelay * pow(2, Double(attempt))), reResolve: true)
        }
    }
}
