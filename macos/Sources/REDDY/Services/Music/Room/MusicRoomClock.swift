import Foundation

// Working out how far a guest's clock is from the host's, the way NTP does it: a guest sends a ping stamped t0 (its own clock), the host
// stamps when it received it (t1) and when it answered (t2), and the guest stamps the answer's arrival (t3). Both sides use their own
// monotonic uptime, so a person changing the wall clock never matters.

struct MusicRoomClockSample: Equatable, Sendable {
    /// Host clock minus guest clock, in seconds.
    var offset: Double
    /// Time the round trip spent on the network, in seconds.
    var rtt: Double
}

enum MusicRoomClockMath {
    /// One ping/pong round. Nil when a number is not finite or the timestamps cannot be true (a negative or absurd round trip).
    static func sample(t0: Double, t1: Double, t2: Double, t3: Double) -> MusicRoomClockSample? {
        guard t0.isFinite, t1.isFinite, t2.isFinite, t3.isFinite else { return nil }
        let rtt = (t3 - t0) - (t2 - t1)
        guard rtt >= -0.001, rtt < 10 else { return nil }
        return MusicRoomClockSample(offset: ((t1 - t0) + (t2 - t3)) / 2, rtt: max(0, rtt))
    }
}

/// Collects the samples of one round of pings and keeps the offset of the best one: the lowest round trip is the least disturbed by queuing.
struct MusicRoomClockEstimator: Sendable {
    static let roundsPerMeasurement = 5
    static let remeasureInterval: TimeInterval = 60

    private(set) var pending: [MusicRoomClockSample] = []
    private(set) var current: MusicRoomClockSample?

    var hasOffset: Bool { current != nil }
    var offset: Double? { current?.offset }
    var isRoundComplete: Bool { pending.count >= Self.roundsPerMeasurement }

    /// Starts a new measurement. The previous offset stays in use until the new one is ready.
    mutating func beginMeasurement() { pending = [] }

    mutating func add(_ s: MusicRoomClockSample) { pending.append(s) }

    /// Ends the measurement. Returns false when no sample arrived, in which case the old offset stays.
    @discardableResult
    mutating func finishMeasurement() -> Bool {
        defer { pending = [] }
        guard let best = pending.min(by: { $0.rtt < $1.rtt }) else { return false }
        current = best
        return true
    }

    /// The host's clock at a moment of this device's clock.
    func hostTime(forLocal local: Double) -> Double? { offset.map { local + $0 } }

    /// Re-measure once a minute, and only while music is playing: a paused room has nothing to keep in step.
    static func shouldRemeasure(lastMeasuredAt: Double, now: Double, isPlaying: Bool) -> Bool {
        isPlaying && now - lastMeasuredAt >= remeasureInterval
    }
}
