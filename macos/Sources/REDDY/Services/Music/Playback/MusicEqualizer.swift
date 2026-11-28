import Foundation
import AVFoundation

// A seven-band equalizer, a bass and treble pad, and a stereo widener. The settings are plain data; the response maths is plain functions
// so presets can be checked without sound; `MusicEqualizerUnit` is the only part that touches AVAudioUnitEQ.

// MARK: settings

/// One band the person places by hand: where it sits, how much it lifts or cuts, and how wide it is.
struct MusicParametricBand: Codable, Equatable, Sendable, Identifiable {
    enum Shape: String, Codable, Sendable, CaseIterable { case bell, lowShelf, highShelf }
    var id = UUID()
    var shape = Shape.bell
    var hz = 1_000.0
    var gainDB = 0.0
    var q = 1.0
    var enabled = true

    static let hzRange = 20.0...20_000.0
    static let gainRange = -12.0...12.0
    static let qRange = 0.3...10.0
    static let slots = 6

    var isValid: Bool {
        hz.isFinite && gainDB.isFinite && q.isFinite && Self.hzRange.contains(hz) && Self.gainRange.contains(gainDB) && Self.qRange.contains(q)
    }
    var isAudible: Bool { enabled && abs(gainDB) >= 0.05 }
}

struct MusicSpatialSettings: Codable, Equatable, Sendable {
    var enabled = false
    /// 0...1: how much the side signal is boosted (0 = off, 1 = 2.5 times).
    var amount = 0.5
    static let range = 0.0...1.0
    init() {}

    private enum CodingKeys: String, CodingKey { case enabled, amount }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        let a = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0.5
        amount = a.isFinite ? min(1, max(0, a)) : 0.5
    }
    var isAudible: Bool { enabled && amount > 0.001 }
}

struct MusicEqualizerSettings: Codable, Equatable, Sendable {
    var enabled = false
    /// Gains in dB for the seven bands, each -12...12.
    var bands: [Double] = Array(repeating: 0, count: MusicEqualizerMath.bandCentres.count)
    /// The tone pad: -1...1 on each axis. Bass is the horizontal axis, treble the vertical one; the corners are +/-9 dB.
    var padBass = 0.0
    var padTreble = 0.0
    var spatial = MusicSpatialSettings()
    /// Lower the whole curve by its highest boost so a boost never clips. On unless the person turns it off.
    var autoPreamp = true
    /// Bands placed by hand, after the seven fixed ones (up to `MusicParametricBand.slots`).
    var parametric: [MusicParametricBand] = []
    /// -1 (left only) ... 1 (right only). Works with or without the curve.
    var balance = 0.0
    /// Both ears hear the same mix: the sides are folded into the middle.
    var mono = false

    static let gainRange = -12.0...12.0
    static let padRange = -1.0...1.0
    init() {}

    private enum CodingKeys: String, CodingKey { case enabled, bands, padBass, padTreble, spatial, autoPreamp, parametric, balance, mono }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        let b = try c.decodeIfPresent([Double].self, forKey: .bands) ?? []
        bands = b.count == MusicEqualizerMath.bandCentres.count ? b.map { $0.isFinite ? min(12, max(-12, $0)) : 0 } : Array(repeating: 0, count: MusicEqualizerMath.bandCentres.count)
        let pb = try c.decodeIfPresent(Double.self, forKey: .padBass) ?? 0
        let pt = try c.decodeIfPresent(Double.self, forKey: .padTreble) ?? 0
        padBass = pb.isFinite ? min(1, max(-1, pb)) : 0
        padTreble = pt.isFinite ? min(1, max(-1, pt)) : 0
        spatial = try c.decodeIfPresent(MusicSpatialSettings.self, forKey: .spatial) ?? MusicSpatialSettings()
        autoPreamp = try c.decodeIfPresent(Bool.self, forKey: .autoPreamp) ?? true
        parametric = Array(((try? c.decodeIfPresent([MusicParametricBand].self, forKey: .parametric)) ?? []).filter(\.isValid).prefix(MusicParametricBand.slots))
        let bal = try c.decodeIfPresent(Double.self, forKey: .balance) ?? 0
        balance = bal.isFinite ? min(1, max(-1, bal)) : 0
        mono = try c.decodeIfPresent(Bool.self, forKey: .mono) ?? false
    }

    func validate() throws {
        guard bands.count == MusicEqualizerMath.bandCentres.count, bands.allSatisfy({ $0.isFinite && Self.gainRange.contains($0) }),
              padBass.isFinite, padTreble.isFinite, Self.padRange.contains(padBass), Self.padRange.contains(padTreble),
              spatial.amount.isFinite, MusicSpatialSettings.range.contains(spatial.amount),
              parametric.count <= MusicParametricBand.slots, parametric.allSatisfy(\.isValid), balance.isFinite, (-1.0...1.0).contains(balance) else { throw MusicEffectError.invalidValues }
    }

    var isValid: Bool { (try? validate()) != nil }

    /// The curve changes the sound: on, and at least one band or pad value away from zero.
    var curveIsAudible: Bool { enabled && (bands.contains { abs($0) >= 0.05 } || parametric.contains(where: \.isAudible) || abs(padBass) >= 0.01 || abs(padTreble) >= 0.01) }

    /// The equalizer chain has work to do (curve or widening). Used to decide whether playback must go through the audio engine.
    var needsEngine: Bool { curveIsAudible || spatial.isAudible || mono || abs(balance) >= 0.01 }

    var presetID: String? { MusicEqualizerPresets.matching(bands)?.id }

    mutating func apply(_ p: MusicEqualizerPreset) { bands = p.gains; padBass = 0; padTreble = 0; parametric = []; enabled = true }
    mutating func reset() { self = MusicEqualizerSettings() }
}

// MARK: response maths

enum MusicEqualizerMath {
    /// Seven centres, about 1.3 octaves apart. The lowest and highest are shelves, the five between are bells.
    static let bandCentres: [Double] = [50, 125, 320, 800, 2_000, 5_000, 12_000]
    /// A bell this wide (in octaves) just touches its neighbours, so a flat boost across all bands stays smooth.
    static let bellOctaves = 1.2
    /// A bell's width in octaves for a given Q (the audio unit takes octaves).
    static func octaves(fromQ q: Double) -> Double { 2 * asinh(1 / (2 * max(0.05, q))) / log(2) }
    static let padBassHz = 120.0
    static let padTrebleHz = 7_000.0
    /// The pad corner is this many dB.
    static let padDB = 9.0
    /// Take off this share of the curve's peak boost as make-up gain. All of it would make every boost sound like the song got quieter;
    /// none would send boosts into the limiter. 60% leaves a small net lift that the limiter after the chain catches.
    static let makeupShare = 0.6

    enum Kind: Equatable, Sendable { case lowShelf, bell, highShelf }
    struct Section: Equatable, Sendable {
        var kind: Kind
        var hz: Double
        var gainDB: Double
        var q: Double
    }

    /// Every section of the curve in the fixed order the audio unit uses: seven bands, then the pad's bass and treble shelves.
    static func sections(_ s: MusicEqualizerSettings) -> [Section] {
        var out: [Section] = []
        for (i, hz) in bandCentres.enumerated() {
            let kind: Kind = i == 0 ? .lowShelf : (i == bandCentres.count - 1 ? .highShelf : .bell)
            let gain = s.enabled && i < s.bands.count ? s.bands[i] : 0
            out.append(Section(kind: kind, hz: hz, gainDB: gain, q: kind == .bell ? 1 / (2 * sinh(log(2) / 2 * bellOctaves)) : 0.7))
        }
        out.append(Section(kind: .lowShelf, hz: padBassHz, gainDB: s.enabled ? s.padBass * padDB : 0, q: 0.7))
        out.append(Section(kind: .highShelf, hz: padTrebleHz, gainDB: s.enabled ? s.padTreble * padDB : 0, q: 0.7))
        // The hand-placed bands always fill the same slots, so the audio unit never changes shape; an unused slot sits at 0 dB.
        for i in 0..<MusicParametricBand.slots {
            guard i < s.parametric.count else { out.append(Section(kind: .bell, hz: 1_000, gainDB: 0, q: 1)); continue }
            let p = s.parametric[i]
            let kind: Kind = p.shape == .bell ? .bell : (p.shape == .lowShelf ? .lowShelf : .highShelf)
            out.append(Section(kind: kind, hz: p.hz, gainDB: s.enabled && p.enabled ? p.gainDB : 0, q: kind == .bell ? p.q : min(1.2, max(0.3, p.q))))
        }
        return out
    }

    /// Magnitude in dB of one biquad section at `hz` (the standard audio-EQ shelf and peaking filters).
    static func magnitudeDB(_ sec: Section, at hz: Double, sampleRate: Double = 44_100) -> Double {
        guard abs(sec.gainDB) > 0.0001 else { return 0 }
        let a = pow(10, sec.gainDB / 40)
        let w0 = 2 * Double.pi * min(sec.hz, sampleRate * 0.45) / sampleRate
        let cw = cos(w0), alpha = sin(w0) / (2 * sec.q)
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
        switch sec.kind {
        case .bell:
            b0 = 1 + alpha * a; b1 = -2 * cw; b2 = 1 - alpha * a
            a0 = 1 + alpha / a; a1 = -2 * cw; a2 = 1 - alpha / a
        case .lowShelf:
            let t = 2 * a.squareRoot() * alpha
            b0 = a * ((a + 1) - (a - 1) * cw + t); b1 = 2 * a * ((a - 1) - (a + 1) * cw); b2 = a * ((a + 1) - (a - 1) * cw - t)
            a0 = (a + 1) + (a - 1) * cw + t; a1 = -2 * ((a - 1) + (a + 1) * cw); a2 = (a + 1) + (a - 1) * cw - t
        case .highShelf:
            let t = 2 * a.squareRoot() * alpha
            b0 = a * ((a + 1) + (a - 1) * cw + t); b1 = -2 * a * ((a - 1) + (a + 1) * cw); b2 = a * ((a + 1) + (a - 1) * cw - t)
            a0 = (a + 1) - (a - 1) * cw + t; a1 = 2 * ((a - 1) - (a + 1) * cw); a2 = (a + 1) - (a - 1) * cw - t
        }
        let w = 2 * Double.pi * min(hz, sampleRate * 0.499) / sampleRate
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = a0 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        let num = (nr * nr + ni * ni), den = (dr * dr + di * di)
        guard den > 0, num > 0 else { return 0 }
        return 10 * log10(num / den)
    }

    /// Summed response in dB at `hz`.
    static func responseDB(_ s: MusicEqualizerSettings, at hz: Double) -> Double {
        sections(s).reduce(0) { $0 + magnitudeDB($1, at: hz) }
    }

    /// The curve sampled at 96 log-spaced points from 20 Hz to 20 kHz.
    static func curve(_ s: MusicEqualizerSettings, points: Int = 96) -> [Double] {
        let secs = sections(s)
        return (0..<points).map { i in
            let hz = 20 * pow(1_000, Double(i) / Double(points - 1))
            return secs.reduce(0) { $0 + magnitudeDB($1, at: hz) }
        }
    }

    /// Negative dB applied after the curve. With the automatic preamp on it is the whole highest boost, so no steady tone can pass full scale;
    /// with it off, 60% of the highest peak, so a big boost does not arrive louder than a flat song.
    static func makeupGainDB(_ s: MusicEqualizerSettings) -> Double {
        if s.autoPreamp { return autoPreampDB(s) }
        let peak = curve(s).max() ?? 0
        return peak > 0 ? -min(12, peak * makeupShare) : 0
    }

    static let preampRates: [Double] = [44_100, 48_000, 96_000]
    static let preampLimitDB = 24.0

    /// The highest boost of the curve in dB (never below 0), looked for on a 2% log grid from 20 Hz to 20 kHz plus every section centre, at a few playing rates.
    static func peakBoostDB(_ s: MusicEqualizerSettings) -> Double {
        let secs = sections(s).filter { abs($0.gainDB) > 0.0001 }
        guard !secs.isEmpty else { return 0 }
        var grid: [Double] = secs.map(\.hz)
        var hz = 20.0
        while hz <= 20_000 { grid.append(hz); hz *= 1.02 }
        var peak = 0.0
        for rate in preampRates {
            for f in grid { peak = max(peak, secs.reduce(0) { $0 + magnitudeDB($1, at: f, sampleRate: rate) }) }
        }
        return peak
    }

    /// 0 or negative: minus the highest boost, down to -24 dB.
    static func autoPreampDB(_ s: MusicEqualizerSettings) -> Double {
        let peak = peakBoostDB(s)
        return peak > 0.01 ? -min(preampLimitDB, peak) : 0
    }
}

// MARK: glide

/// A change of gain is spread over 40 ms in equal steps so a slider move or a preset change never clicks (no zipper noise).
enum MusicEqualizerGlide {
    static let durationMs = 40
    static let stepCount = 8
    static var stepMs: Int { durationMs / stepCount }

    /// The values from `from` (exclusive) to `to` (inclusive) in `count` equal steps. The last one is exactly `to`.
    static func steps(from: Double, to: Double, count: Int = stepCount) -> [Double] {
        guard count > 1, from != to else { return [to] }
        return (1...count).map { $0 == count ? to : from + (to - from) * Double($0) / Double(count) }
    }
}

// MARK: stereo widening

/// Mid/side widening: the side signal is multiplied and the mid is left alone, so mono material is unchanged and only what is different
/// between the channels grows. The amount glides across each buffer so a slider move never clicks. It runs on whatever thread feeds the
/// engine, so the target is behind a lock.
final class MusicSpatialWidener: @unchecked Sendable {
    private let lock = NSLock()
    private var target = 0.0
    private var current = 0.0
    private var monoTarget = 0.0, monoCurrent = 0.0
    private var balanceTarget = 0.0, balanceCurrent = 0.0

    /// Left and right gains for a balance of -1...1: the far side is quietened, the near side stays at full level.
    static func balanceGains(_ b: Double) -> (left: Float, right: Float) {
        let c = min(1, max(-1, b))
        return (Float(c > 0 ? 1 - c : 1), Float(c < 0 ? 1 + c : 1))
    }

    /// Side-signal multiplier for an amount 0...1: 1 (unchanged) up to 2.5.
    static func sideGain(amount: Double) -> Double { 1 + 1.5 * min(1, max(0, amount)) }

    func set(_ s: MusicSpatialSettings) { lock.withLock { target = s.isAudible ? s.amount : 0 } }

    /// Widening, balance and mono from the equalizer settings, in one call.
    func set(_ e: MusicEqualizerSettings) {
        lock.withLock {
            target = e.spatial.isAudible ? e.spatial.amount : 0
            monoTarget = e.mono ? 1 : 0
            balanceTarget = e.balance
        }
    }

    /// Widens one stereo buffer in place.
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        let (goal, monoGoal, balGoal) = lock.withLock { (target, monoTarget, balanceTarget) }
        let idle = goal == 0 && current == 0 && monoGoal == 0 && monoCurrent == 0 && balGoal == 0 && balanceCurrent == 0
        guard frames > 0, !idle else { return }
        let start = current, monoStart = monoCurrent, balStart = balanceCurrent
        for i in 0..<frames {
            let t = Double(i + 1) / Double(frames)
            let a = start + (goal - start) * t
            let m = monoStart + (monoGoal - monoStart) * t
            let bal = Self.balanceGains(balStart + (balGoal - balStart) * t)
            let g = Float(Self.sideGain(amount: a) * (1 - m))
            let l = left[i], r = right[i]
            let mid = (l + r) * 0.5, side = (l - r) * 0.5 * g
            left[i] = (mid + side) * bal.left
            right[i] = (mid - side) * bal.right
        }
        current = goal; monoCurrent = monoGoal; balanceCurrent = balGoal
    }
}

// MARK: the audio unit

/// Nine bands of Apple's EQ: the seven manual bands and the pad's two shelves. The cascade never changes shape: a band at 0 dB is bypassed,
/// so moving a slider from zero is a gain change, not a rebuild. `globalGain` carries the make-up.
@MainActor
final class MusicEqualizerUnit {
    let unit = AVAudioUnitEQ(numberOfBands: MusicEqualizerMath.bandCentres.count + 2 + MusicParametricBand.slots)
    private(set) var settings = MusicEqualizerSettings()
    /// The gains now on the unit: nine bands, then the make-up. A glide starts from here.
    private var shown: [Double] = []
    private var glide: Task<Void, Never>?

    init() { try? write(MusicEqualizerSettings(), animated: false) }

    /// Applies new settings as one unit. If writing fails the previous settings are written back and the error is thrown.
    func apply(_ s: MusicEqualizerSettings) throws {
        try s.validate()
        let previous = settings
        do { try write(s) } catch {
            try? write(previous)
            throw error
        }
    }

    private func write(_ s: MusicEqualizerSettings, animated: Bool = true) throws {
        try s.validate()
        let secs = MusicEqualizerMath.sections(s)
        guard secs.count == unit.bands.count else { throw MusicEffectError.invalidValues }
        for (band, sec) in zip(unit.bands, secs) {
            switch sec.kind {
            case .lowShelf: band.filterType = .lowShelf
            case .highShelf: band.filterType = .highShelf
            case .bell:
                band.filterType = .parametric
                // bandwidth in octaves from Q
                band.bandwidth = Float(MusicEqualizerMath.octaves(fromQ: sec.q))
            }
            band.frequency = Float(sec.hz)
        }
        settings = s
        let target = secs.map(\.gainDB) + [MusicEqualizerMath.makeupGainDB(s)]
        glide?.cancel()
        glide = nil
        if !animated || shown.count != target.count || shown == target || unit.bypass && !s.curveIsAudible {
            place(target, final: true)
            return
        }
        // Bands that move are switched on for the glide; the final step restores the bypass of bands left at 0 dB.
        if s.curveIsAudible { unit.bypass = false }
        let start = shown
        let ramps = zip(start, target).map { MusicEqualizerGlide.steps(from: $0, to: $1) }
        glide = Task { [weak self] in
            for k in 0..<MusicEqualizerGlide.stepCount {
                try? await Task.sleep(for: .milliseconds(MusicEqualizerGlide.stepMs))
                if Task.isCancelled { return }
                self?.place(ramps.map { $0[min(k, $0.count - 1)] }, final: k == MusicEqualizerGlide.stepCount - 1)
            }
        }
    }

    /// Writes gains to the unit. Nine bands then the make-up. On the last step the bypass flags follow the settings.
    private func place(_ gains: [Double], final: Bool) {
        shown = gains
        for (i, band) in unit.bands.enumerated() where i < gains.count - 1 {
            band.gain = Float(gains[i])
            band.bypass = final ? abs(gains[i]) < 0.05 : false
        }
        unit.globalGain = Float(gains[gains.count - 1])
        if final { unit.bypass = !settings.curveIsAudible }
    }
}
