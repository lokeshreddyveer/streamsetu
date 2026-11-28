import Foundation

/// Crossfade maths. Off by default; the length is a whole number of seconds from 1 to 10 (default 5). All times here are listening seconds
/// (file seconds divided by tempo), so a fade lasts the same however fast the music plays.
enum MusicCrossfade {
    static let minSeconds = 1.0
    static let maxSeconds = 10.0
    static let defaultSeconds = 5.0
    static let stepSeconds = 0.05
    /// A fade needs a real, finite duration longer than this.
    static let minTrackSeconds = 1.0

    /// The effective length for a setting: 0 (off) when under 1 s, otherwise clamped to 1...10 and rounded to a whole second.
    static func length(setting: Double) -> Double {
        guard setting.isFinite, setting >= minSeconds else { return 0 }
        return min(maxSeconds, max(minSeconds, setting.rounded()))
    }

    /// The length at which a fade may start for a track: the setting, but never more than half the track.
    static func plannedLength(setting: Double, duration: TimeInterval, tempo: Double = 1) -> Double {
        let s = length(setting: setting)
        guard s > 0, duration.isFinite, duration > minTrackSeconds else { return 0 }
        return min(s, MusicVolumeCurve.listening(duration, tempo: tempo) / 2)
    }

    /// The ramp length to use when the fade starts, or nil when it must not start yet. The fade starts once the time left is at most
    /// the planned length, and the ramp is the planned length or the time left, whichever is shorter (starting late fades for what is left).
    static func rampLength(setting: Double, position: TimeInterval, duration: TimeInterval, tempo: Double = 1) -> Double? {
        let planned = plannedLength(setting: setting, duration: duration, tempo: tempo)
        guard planned > 0, position.isFinite else { return nil }
        let remaining = MusicVolumeCurve.listening(duration - position, tempo: tempo)
        guard remaining <= planned, remaining > 0 else { return nil }
        return min(planned, remaining)
    }

    /// The incoming track's ramp is also limited to half its own length (in listening seconds).
    static func incomingRamp(_ ramp: Double, incomingDuration: TimeInterval, tempo: Double = 1) -> Double {
        guard incomingDuration.isFinite, incomingDuration > 0 else { return ramp }
        return min(ramp, MusicVolumeCurve.listening(incomingDuration, tempo: tempo) / 2)
    }

    /// Number of 50 ms steps for a ramp.
    static func steps(for ramp: Double) -> Int { max(2, Int((ramp / stepSeconds).rounded())) }

    /// Equal-power gains for step `s` of `steps`: the angle runs 0 to 90 degrees, outgoing is cos, incoming is sin, so
    /// out^2 + in^2 is always 1 and there is no dip in the middle of the fade.
    static func gains(step s: Int, of steps: Int) -> (outgoing: Float, incoming: Float) {
        let t = (Double.pi / 2) * min(1, max(0, Double(s) / Double(max(1, steps))))
        return (Float(cos(t)), Float(sin(t)))
    }

    /// The engine's own volume control is cubic, so a wanted amplitude factor goes through its cube root.
    static func cubicControl(forAmplitude a: Float) -> Float { Float(cbrt(Double(max(0, a)))) }
}

/// Everything that must be true before the next track may be loaded into the second deck and a fade started.
struct MusicCrossfadeGate: Sendable, Equatable {
    var enabled: Bool
    var nextReady: Bool
    var fadeRunning: Bool
    var repeatOne: Bool
    var paused: Bool
    var live: Bool
    var inRoom: Bool

    var canStart: Bool { enabled && nextReady && !fadeRunning && !repeatOne && !paused && !live && !inRoom }
}
