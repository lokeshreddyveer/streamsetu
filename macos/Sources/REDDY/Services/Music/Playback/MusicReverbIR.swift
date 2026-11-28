import Foundation

// Our own room impulse responses. Nothing is loaded from disk: each room is synthesised from a short recipe (a few discrete early
// reflections, then a dense noise tail that falls 60 dB over the requested decay and darkens as it goes). The chosen decay, damping,
// pre-delay and early-reflection level are baked into the response, so the audio side only has to convolve.

/// The few numbers that describe a room's character.
struct MusicRoomProfile: Equatable, Sendable {
    /// Natural decay time in seconds.
    var rt60: Double
    /// Delay of the first discrete reflection in milliseconds; the tail starts here too.
    var firstReflectionMs: Double
    /// Initial high-frequency damping coefficient of the tail's one-pole low-pass, 0 (bright) to 1 (dark).
    var damping: Double
    /// Rooms other than the plate add four discrete reflections; the plate is dense and bright from the start.
    var hasDiscreteReflections: Bool
}

extension MusicReverbRoom {
    var profile: MusicRoomProfile {
        switch self {
        case .smallRoom: MusicRoomProfile(rt60: 0.4, firstReflectionMs: 8, damping: 0.55, hasDiscreteReflections: true)
        case .mediumRoom: MusicRoomProfile(rt60: 0.7, firstReflectionMs: 14, damping: 0.60, hasDiscreteReflections: true)
        case .largeRoom: MusicRoomProfile(rt60: 1.1, firstReflectionMs: 22, damping: 0.65, hasDiscreteReflections: true)
        case .mediumHall: MusicRoomProfile(rt60: 1.8, firstReflectionMs: 30, damping: 0.70, hasDiscreteReflections: true)
        case .largeHall: MusicRoomProfile(rt60: 3.2, firstReflectionMs: 45, damping: 0.75, hasDiscreteReflections: true)
        case .plate: MusicRoomProfile(rt60: 1.8, firstReflectionMs: 6, damping: 0.90, hasDiscreteReflections: false)
        }
    }
}

/// Everything that shapes one impulse response. Equatable so the audio side can skip a rebuild when nothing changed.
struct MusicReverbSpec: Equatable, Sendable {
    var room: MusicReverbRoom
    /// Seconds for the tail to fall 60 dB.
    var decay: Double
    var preDelayMs: Double
    var dampingHz: Double
    /// Level of the first 80 ms relative to the tail, 0 to 100 percent.
    var reflections: Double

    init(room: MusicReverbRoom, decay: Double, preDelayMs: Double = 0, dampingHz: Double = 20_000, reflections: Double = 100) {
        self.room = room; self.decay = decay; self.preDelayMs = preDelayMs; self.dampingHz = dampingHz; self.reflections = reflections
    }

    init(_ r: MusicReverbSettings) {
        self.init(room: r.room, decay: r.decay, preDelayMs: r.preDelay, dampingHz: r.damping, reflections: r.reflections)
    }
}

enum MusicReverbIR {
    /// The discrete reflections, as multiples of the first reflection delay, with their gains.
    static let reflectionMultiples: [Double] = [1, 1.6, 2.4, 3.7]
    static let reflectionGains: [Float] = [0.7, -0.5, 0.35, -0.25]
    /// The right channel's reflections arrive this much later, which widens the image.
    static let rightChannelOffsetMs = 1.0
    /// The span the "reflections" control scales.
    static let earlyWindowMs = 80.0
    /// A decay of the maximum length gives a response of about 15 seconds; this caps the memory.
    static let maxSeconds = 16.0

    /// Length in frames of the response without pre-delay: first reflection plus one and a half decays.
    static func bodyFrames(_ spec: MusicReverbSpec, sampleRate: Double) -> Int {
        let p = spec.room.profile
        return max(1, Int(((p.firstReflectionMs / 1000) + 1.5 * spec.decay) * sampleRate))
    }

    /// The discrete reflections of a channel: where they land (in frames) and with what gain. Empty for the plate.
    static func discreteReflections(_ spec: MusicReverbSpec, channel: Int, sampleRate: Double, includePreDelay: Bool = true) -> [(frame: Int, gain: Float)] {
        let p = spec.room.profile
        guard p.hasDiscreteReflections else { return [] }
        return (0..<reflectionMultiples.count).map { i in
            let ms = p.firstReflectionMs * reflectionMultiples[i] + (channel == 1 ? rightChannelOffsetMs : 0) + (includePreDelay ? spec.preDelayMs : 0)
            return (Int((ms / 1000 * sampleRate).rounded()), reflectionGains[i])
        }
    }

    /// One channel of the response (0 left, 1 right) at the given sample rate. The result has unit energy before the "reflections" scaling,
    /// so the wet level does not depend on the room or on how long it rings.
    static func synthesise(_ spec: MusicReverbSpec, channel: Int, sampleRate: Double) -> [Float] {
        let p = spec.room.profile
        let decay = min(MusicReverbSettings.decayRange.upperBound, max(MusicReverbSettings.decayRange.lowerBound, spec.decay))
        let fs = sampleRate
        let body = min(bodyFrames(spec, sampleRate: fs), Int(maxSeconds * fs))
        let start = Int((p.firstReflectionMs / 1000 * fs).rounded())
        var h = [Float](repeating: 0, count: body)

        // Dense tail: seeded noise, a one-pole low-pass whose coefficient shrinks with time, a 60 dB exponential envelope.
        var rng = SplitMix(seed: UInt64(spec.room.rawValue) &* 7919 &+ UInt64(channel) &* 104_729 &+ 12_345)
        let coefStep = exp(-1.0 / (decay * fs))
        var coef = p.damping
        var env = 1.0
        let envStep = pow(10.0, -3.0 / (decay * fs))
        var y: Double = 0
        if start < body {
            for n in start..<body {
                let x = rng.nextUniform()
                y = (1 - coef) * x + coef * y
                h[n] = Float(y * env)
                env *= envStep
                coef *= coefStep
            }
        }

        for r in discreteReflections(spec, channel: channel, sampleRate: fs, includePreDelay: false) where r.frame < body { h[r.frame] += r.gain }

        var energy: Double = 0
        for v in h { energy += Double(v) * Double(v) }
        if energy > 0 {
            let g = Float(1 / energy.squareRoot())
            for i in h.indices { h[i] *= g }
        }

        // The reflections control scales the first 80 ms (counted from the start of the room, before pre-delay).
        let early = min(body, Int(earlyWindowMs / 1000 * fs))
        let refl = Float(min(1, max(0, spec.reflections / 100)))
        if refl != 1 { for i in 0..<early { h[i] *= refl } }

        // Damping: a one-pole high cut on the whole response, which is the same as cutting the wet path.
        if spec.dampingHz < 0.45 * fs {
            let a = Float(exp(-2 * Double.pi * spec.dampingHz / fs))
            var z: Float = 0
            for i in h.indices {
                z = (1 - a) * h[i] + a * z
                h[i] = z
            }
        }

        // Pre-delay is leading silence.
        let pre = Int((spec.preDelayMs / 1000 * fs).rounded())
        if pre > 0 { h = [Float](repeating: 0, count: pre) + h }
        // Trailing frames below -90 dB of the peak carry no sound; dropping them keeps the convolution short.
        return trimmed(h)
    }

    static func trimmed(_ h: [Float]) -> [Float] {
        let peak = h.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 0 else { return [0] }
        let floor = peak * 3.2e-5
        var end = h.count
        while end > 1, abs(h[end - 1]) < floor { end -= 1 }
        return Array(h[0..<end])
    }

    /// The number of leading zero frames, which the convolver uses to cut its own latency to nothing.
    static func leadingSilence(_ h: [Float]) -> Int { h.firstIndex { $0 != 0 } ?? h.count }
}

/// A tiny seeded generator so a room sounds the same every time and tests are repeatable.
struct SplitMix: Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in -1...1.
    mutating func nextUniform() -> Double { Double(next() >> 11) / Double(1 << 52) - 1 }
}
