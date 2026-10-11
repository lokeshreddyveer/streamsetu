import Foundation

/// Counts stalls (playback waiting on data after it had started) and total time spent waiting.
struct BufferingMonitor: Sendable {
    private(set) var stalls = 0
    private(set) var stalledSeconds: Double = 0
    private var stallStart: Date?
    private var hasStartedPlaying = false
    private(set) var startedWaitingAt: Date?
    private(set) var startupSeconds: Double?

    mutating func reset() { self = BufferingMonitor() ; startedWaitingAt = Date() }

    mutating func bufferingBegan(now: Date = Date()) {
        if hasStartedPlaying, stallStart == nil { stallStart = now; stalls += 1 }
    }

    mutating func playing(now: Date = Date()) {
        if !hasStartedPlaying {
            hasStartedPlaying = true
            if let s = startedWaitingAt { startupSeconds = now.timeIntervalSince(s) }
        }
        if let s = stallStart { stalledSeconds += now.timeIntervalSince(s); stallStart = nil }
    }
}
