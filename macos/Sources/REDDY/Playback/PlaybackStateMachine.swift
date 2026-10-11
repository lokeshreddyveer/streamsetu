import Foundation

/// Every state change goes through here, so the legal transitions are explicit and unit-testable.
/// Starting a new item or stopping is always allowed (instant channel switching); anything else illegal is rejected.
struct PlaybackStateMachine: Sendable {
    private(set) var state: PlaybackState = .idle

    @discardableResult
    mutating func send(_ event: PlaybackEvent) -> Bool {
        guard let next = Self.transition(from: state, event) else { return false }
        state = next
        return true
    }

    static func transition(from s: PlaybackState, _ e: PlaybackEvent) -> PlaybackState? {
        switch e {
        case .startResolving: return .resolving
        case .stop: return .idle
        case .failed(let err):
            return s == .idle ? nil : .failed(err)
        case .retry:
            if case .failed = s { return .resolving }
            return nil
        case .recover:
            switch s { case .idle, .ended: return nil; default: return .recovering }
        case .resolved:
            return s == .resolving || s == .recovering ? .preparing : nil
        case .buffering:
            switch s { case .preparing, .playing, .seeking, .buffering, .recovering: return .buffering; default: return nil }
        case .ready:
            switch s { case .preparing, .buffering, .seeking, .playing, .recovering: return .playing; default: return nil }
        case .pause:
            switch s { case .playing, .buffering, .preparing: return .paused; default: return nil }
        case .resume:
            return s == .paused ? .playing : nil
        case .seekBegan:
            switch s { case .playing, .paused, .buffering, .ended: return .seeking; default: return nil }
        case .seekEnded:
            return s == .seeking ? .buffering : nil
        case .reachedEnd:
            switch s { case .playing, .buffering, .paused: return .ended; default: return nil }
        }
    }
}
