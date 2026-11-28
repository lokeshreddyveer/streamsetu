import Foundation

/// The volume slider's perceptual curve and the tempo-aware time display. Pure maths, no audio.
enum MusicVolumeCurve {
    /// The slider keeps full steps at the loud end and finer ones at the quiet end: attenuation in dB is -60 * (1 - s)^1.5.
    /// 1.0 gives 0 dB, 0.5 about -21.2 dB, 0.25 about -39 dB, 0.01 about -59.1 dB. 0 is a hard mute.
    static func attenuationDB(slider s: Double) -> Double {
        let x = min(1, max(0, s))
        guard x > 0 else { return -.infinity }
        return -60 * pow(1 - x, 1.5)
    }

    /// The linear amplitude to give the audio engine for a slider position in 0...1.
    static func amplitude(slider s: Double) -> Float {
        let x = min(1, max(0, s))
        guard x > 0 else { return 0 }
        return Float(pow(10, attenuationDB(slider: x) / 20))
    }

    /// Step for keyboard and wheel nudges: 5 percent of the slider.
    static let nudgeStep: Float = 0.05
    /// How long after the last nudge the level is written to disk.
    static let persistDelay: TimeInterval = 0.4

    /// The slider value after a nudge, clamped to 0...1 and rounded to whole percent so repeated nudges never drift.
    static func nudged(_ v: Float, by delta: Float) -> Float {
        let pct = ((v + delta) * 100).rounded()
        return min(1, max(0, pct / 100))
    }

    // MARK: listening time

    /// Seconds the person hears for a span of the file at a tempo ("listening seconds").
    static func listening(_ trackSeconds: TimeInterval, tempo: Double) -> TimeInterval {
        guard trackSeconds.isFinite else { return 0 }
        return trackSeconds / max(0.5, min(2, tempo.isFinite ? tempo : 1))
    }

    /// The file position for a position typed or dragged on the listening-time bar.
    static func trackSeconds(fromListening s: TimeInterval, tempo: Double) -> TimeInterval {
        guard s.isFinite else { return 0 }
        return s * max(0.5, min(2, tempo.isFinite ? tempo : 1))
    }
}

/// Mute with memory. The in-app mute button and the global hotkey share one instance, so both return to the same level.
struct MusicMuteMemory: Sendable, Equatable {
    private(set) var lastNonZero: Float = 1

    /// Call whenever the volume changes by any route.
    mutating func observe(_ volume: Float) { if volume > 0 { lastNonZero = volume } }

    /// The level a mute toggle should set: 0 when sound is on, the remembered level (100 percent if the person dragged to 0 themselves) when muted.
    func toggled(from volume: Float) -> Float { volume > 0 ? 0 : (lastNonZero > 0 ? lastNonZero : 1) }
}
