import Foundation
import Accelerate
import AVFoundation

// Finds the pulse, the bars, the key and the loud and quiet parts of a song, from audio alone. Everything that touches samples is a plain
// function on [Float], so it is tested with synthetic click tracks, tones and silence. Only `decode` touches AVFoundation.
//
// The method is the textbook one: an onset-strength curve from the change in the log spectrum, a tempo search over that curve (an
// autocorrelation to find the neighbourhood, then a fine scan of how strongly the curve rings at each candidate rate), a forward beat
// tracker that corrects its phase a little at every beat, and a key estimate from pitch-class energy against the two public
// major and minor profiles. The numbers below were chosen for this app and checked against synthetic audio; none are copied from another product.

// MARK: spectral measurements

struct MusicSpectralFrames: Sendable {
    /// Frames per second of the curves below.
    var frameRate: Double
    /// Onset strength: how much the log spectrum rose since the previous frame, summed over 30 Hz to 8 kHz.
    var flux: [Float]
    /// The same measured below 200 Hz only (kicks and bass notes).
    var lowFlux: [Float]
    /// Summed energy per pitch class, C first.
    var chroma: [Float]
}

enum MusicSpectralAnalysis {
    /// 1024 samples is 46 ms at 22.05 kHz: long enough to resolve a bass note from a kick, short enough to place an onset to a few ms.
    static let frameLength = 1024
    /// A quarter of the window: a flux frame every 11.6 ms, which puts a 1 BPM tempo error at under one frame over a whole bar.
    static let hop = 256
    /// How steeply loud bins are compressed before differencing. A bin must be roughly 30 dB under full scale before it counts, so hiss
    /// does not drive the onset curve while a real hit still does.
    static let compression: Float = 0.02
    /// Time from the start of a flux frame to the onset it reports. A click in the middle of a frame is first seen by the frames whose
    /// window it enters, so the curve peaks a little before the window centre; a click placed at a known time is reported 25 ms after the frame start, which is what this constant corrects.
    static let latencySamples = 560

    static func measure(samples: [Float], sampleRate: Double) -> MusicSpectralFrames {
        let n = frameLength, half = n / 2
        let empty = MusicSpectralFrames(frameRate: sampleRate / Double(hop), flux: [], lowFlux: [], chroma: [Float](repeating: 0, count: 12))
        guard samples.count >= n * 2, let setup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2)) else { return empty }
        defer { vDSP_destroy_fftsetup(setup) }
        let frames = (samples.count - n) / hop + 1
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let binHz = sampleRate / Double(n)
        let lowTop = max(2, min(half - 1, Int(200 / binHz)))
        let highTop = max(lowTop + 1, min(half - 1, Int(8000 / binHz)))
        // Pitch class of each bin between 80 Hz and 4 kHz, or -1.
        let pitchClass: [Int] = (0..<half).map { k in
            let f = Double(k) * binHz
            guard f >= 80, f <= 4000 else { return -1 }
            let semis = 12 * log2(f / 440) + 9
            return ((Int(semis.rounded()) % 12) + 12) % 12
        }
        var flux = [Float](repeating: 0, count: frames)
        var low = [Float](repeating: 0, count: frames)
        var chroma = [Float](repeating: 0, count: 12)
        var real = [Float](repeating: 0, count: half), imag = [Float](repeating: 0, count: half)
        var framed = [Float](repeating: 0, count: n)
        var power = [Float](repeating: 0, count: half), mag = [Float](repeating: 0, count: half)
        var logNow = [Float](repeating: 0, count: half), logPrev = [Float](repeating: 0, count: half)
        var diff = [Float](repeating: 0, count: half)
        var zero: Float = 0
        var one = Float(1)
        var count = Int32(half)
        var scale = compression
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                guard let rb = rp.baseAddress, let ib = ip.baseAddress else { return }
                var split = DSPSplitComplex(realp: rb, imagp: ib)
                for f in 0..<frames {
                    samples.withUnsafeBufferPointer { sp in
                        guard let base = sp.baseAddress else { return }
                        vDSP_vmul(base + f * hop, 1, window, 1, &framed, 1, vDSP_Length(n))
                    }
                    framed.withUnsafeBufferPointer { fp in
                        guard let base = fp.baseAddress else { return }
                        base.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) }
                    }
                    vDSP_fft_zrip(setup, &split, 1, 10, FFTDirection(kFFTDirection_Forward))
                    ip[0] = 0
                    vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
                    vvsqrtf(&mag, power, &count)
                    // log(1 + c * magnitude)
                    vDSP_vsmul(mag, 1, &scale, &logNow, 1, vDSP_Length(half))
                    vDSP_vsadd(logNow, 1, &one, &logNow, 1, vDSP_Length(half))
                    vvlogf(&logNow, logNow, &count)
                    if f > 0 {
                        vDSP_vsub(logPrev, 1, logNow, 1, &diff, 1, vDSP_Length(half))
                        vDSP_vthr(diff, 1, &zero, &diff, 1, vDSP_Length(half))
                        var total: Float = 0, lowTotal: Float = 0
                        diff.withUnsafeBufferPointer { dp in
                            guard let d = dp.baseAddress else { return }
                            vDSP_sve(d + 1, 1, &total, vDSP_Length(highTop))
                            vDSP_sve(d + 1, 1, &lowTotal, vDSP_Length(lowTop))
                        }
                        flux[f] = total
                        low[f] = lowTotal
                    }
                    if f % 4 == 0 {
                        for k in 0..<half where pitchClass[k] >= 0 { chroma[pitchClass[k]] += power[k] }
                    }
                    swap(&logNow, &logPrev)
                }
            }
        }
        return MusicSpectralFrames(frameRate: sampleRate / Double(hop), flux: flux, lowFlux: low, chroma: chroma)
    }
}

// MARK: tempo and beats

enum MusicTempoEstimator {
    static let minBPM = 70.0
    static let maxBPM = 200.0
    /// A gentle pull toward the tempos most music uses, so a tie between a rate and its double goes to the likelier one. Centre 125 BPM,
    /// one standard deviation = 0.8 octave: at the edges of the range the pull is only about 0.6, so it breaks ties but never overrules a clear peak.
    static let priorCentre = 125.0
    static let priorWidthOctaves = 0.8

    struct Result: Sendable, Equatable {
        var bpm: Double
        /// Seconds from the start of the curve to a beat, within one beat interval.
        var phase: Double
        var periodicity: Double
    }

    /// Takes out the slow level changes so only the onsets remain: the curve minus a moving average of about 0.8 s, negatives clipped.
    static func detrend(_ x: [Float], frameRate: Double) -> [Float] {
        guard x.count > 4 else { return x }
        let w = max(3, Int(frameRate * 0.8))
        var prefix = [Double](repeating: 0, count: x.count + 1)
        for i in 0..<x.count { prefix[i + 1] = prefix[i] + Double(x[i]) }
        var out = [Float](repeating: 0, count: x.count)
        for i in 0..<x.count {
            let lo = max(0, i - w / 2), hi = min(x.count, i + w / 2 + 1)
            let mean = (prefix[hi] - prefix[lo]) / Double(hi - lo)
            out[i] = max(0, Float(Double(x[i]) - mean))
        }
        return out
    }

    /// Autocorrelation at whole-frame lags 0...maxLag, scaled so lag 0 is 1 and a perfectly periodic curve stays near 1 at its period.
    static func autocorrelation(_ x: [Float], maxLag: Int) -> [Float] {
        let n = x.count
        guard n > 8 else { return [] }
        let top = min(maxLag, n / 2)
        var energy: Float = 0
        vDSP_dotpr(x, 1, x, 1, &energy, vDSP_Length(n))
        guard energy > 1e-9 else { return [] }
        var out = [Float](repeating: 0, count: top + 1)
        x.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress else { return }
            for lag in 0...top {
                var d: Float = 0
                vDSP_dotpr(base, 1, base + lag, 1, &d, vDSP_Length(n - lag))
                out[lag] = d / energy * Float(n) / Float(n - lag)
            }
        }
        return out
    }

    private static func value(_ ac: [Float], at lag: Double) -> Double {
        guard lag >= 0, lag < Double(ac.count - 1) else { return 0 }
        let i = Int(lag), f = lag - Double(i)
        return Double(ac[i]) * (1 - f) + Double(ac[i + 1]) * f
    }

    private static func prior(_ bpm: Double) -> Double {
        let z = log2(bpm / priorCentre) / priorWidthOctaves
        return exp(-0.5 * z * z)
    }

    /// How strongly the curve rings at `bpm`: the magnitude of its Fourier component at the beat rate plus its second and third harmonics.
    /// Returns the score and the phase of the fundamental (seconds to the first beat).
    static func ring(_ x: [Float], frameRate: Double, bpm: Double) -> (score: Double, phase: Double) {
        let n = x.count
        guard n > 8 else { return (0, 0) }
        let period = frameRate * 60 / bpm
        var ramp = [Float](repeating: 0, count: n)
        var s = [Float](repeating: 0, count: n), c = [Float](repeating: 0, count: n)
        var total = 0.0
        var phase = 0.0
        var cnt = Int32(n)
        for (h, weight) in [(1, 1.0), (2, 0.6), (3, 0.4)] {
            var w0: Float = 0
            var step = Float(2 * Double.pi * Double(h) / period)
            vDSP_vramp(&w0, &step, &ramp, 1, vDSP_Length(n))
            vvsincosf(&s, &c, ramp, &cnt)
            var re: Float = 0, im: Float = 0
            vDSP_dotpr(x, 1, c, 1, &re, vDSP_Length(n))
            vDSP_dotpr(x, 1, s, 1, &im, vDSP_Length(n))
            total += weight * Double(hypot(re, im))
            if h == 1 {
                // x peaks where cos(w n - theta) peaks, theta = atan2(im, re)
                var theta = atan2(Double(im), Double(re))
                if theta < 0 { theta += 2 * Double.pi }
                phase = theta / (2 * Double.pi) * period / frameRate
            }
        }
        return (total, phase)
    }

    /// The most likely tempo of an onset curve, or nil when it has no steady pulse in 70...200 BPM.
    static func estimate(onset raw: [Float], frameRate: Double) -> Result? {
        let x = detrend(raw, frameRate: frameRate)
        let minLag = frameRate * 60 / maxBPM, maxLag = frameRate * 60 / minBPM
        let ac = autocorrelation(x, maxLag: Int(maxLag * 4) + 2)
        guard ac.count > Int(maxLag) + 2 else { return nil }
        // Coarse: the lag whose own correlation, plus half of its double and a quarter of four times it, is largest.
        var best = 0.0, bestLag = 0.0
        var lag = minLag
        while lag <= maxLag {
            let s = value(ac, at: lag) + 0.5 * value(ac, at: lag * 2) + 0.25 * value(ac, at: lag * 4)
            let weighted = s * prior(frameRate * 60 / lag)
            if weighted > best { best = weighted; bestLag = lag }
            lag += 0.1
        }
        guard bestLag > 0 else { return nil }
        let coarse = frameRate * 60 / bestLag
        // Fine: scan 4% either side in 0.05 BPM steps for the strongest ring.
        var bestScore = 0.0, bestBPM = coarse, bestPhase = 0.0
        var b = coarse * 0.96
        while b <= coarse * 1.04 {
            if b >= minBPM - 2, b <= maxBPM + 2 {
                let r = ring(x, frameRate: frameRate, bpm: b)
                if r.score > bestScore { bestScore = r.score; bestBPM = b; bestPhase = r.phase }
            }
            b += 0.05
        }
        guard bestScore > 0 else { return nil }
        let periodicity = max(0, min(1, value(ac, at: frameRate * 60 / bestBPM)))
        return Result(bpm: bestBPM, phase: bestPhase, periodicity: periodicity)
    }

    /// Beat times from a forward tracker. It predicts the next beat one period ahead, looks for the strongest onset within 15% of a period
    /// of the prediction, and moves its phase by 25% of the miss and its period by 2% of the miss (clamped to 6% of the starting period).
    /// A beat with no onset near it is carried forward unchanged, so a breakdown does not pull the grid off.
    static func trackBeats(onset raw: [Float], frameRate: Double, bpm: Double, phase: Double) -> (beats: [Double], contrast: Double) {
        let x = detrend(raw, frameRate: frameRate)
        guard !x.isEmpty, bpm > 0 else { return ([], 0) }
        let basePeriod = frameRate * 60 / bpm
        var period = basePeriod
        var t = phase * frameRate
        while t - period >= 0 { t -= period }
        let radius = max(2, Int(period * 0.15))
        let reference = Double(x.max() ?? 0)
        var beats: [Double] = []
        var lastStrong = -1, firstStrong = -1
        var onBeat = 0.0, offBeat = 0.0, pairs = 0
        func peak(near centre: Double) -> (pos: Double, value: Float)? {
            let c = Int(centre.rounded())
            let lo = max(0, c - radius), hi = min(x.count - 1, c + radius)
            guard lo < hi else { return nil }
            var bestV: Float = -1, bestI = lo
            for i in lo...hi where x[i] > bestV { bestV = x[i]; bestI = i }
            return (Double(bestI), bestV)
        }
        while t < Double(x.count - 1) {
            if let p = peak(near: t) {
                let strong = Double(p.value) >= 0.2 * reference
                var shown = t
                if strong {
                    let miss = p.pos - t
                    shown = p.pos
                    lastStrong = beats.count
                    if firstStrong < 0 { firstStrong = beats.count }
                    t += 0.25 * miss
                    period = min(basePeriod * 1.06, max(basePeriod * 0.94, period + 0.02 * miss))
                }
                beats.append(max(0, shown) / frameRate)
                if let off = peak(near: t + period / 2) {
                    onBeat += Double(p.value); offBeat += Double(off.value); pairs += 1
                }
            }
            t += period
        }
        // Beats carried through a quiet stretch are kept, but none are invented before the first real onset or after the last.
        if lastStrong >= 0, lastStrong + 1 < beats.count { beats.removeLast(beats.count - lastStrong - 1) }
        if firstStrong > 0, firstStrong < beats.count { beats.removeFirst(firstStrong) }
        let contrast = pairs > 0 && onBeat + offBeat > 0 ? max(0, (onBeat - offBeat) / (onBeat + offBeat)) : 0
        return (beats, contrast)
    }
}

// MARK: key

enum MusicKeyEstimator {
    /// Krumhansl and Kessler's published key profiles (listening-experiment averages), C major and C minor.
    static let major: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minor: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    static func estimate(chroma: [Float]) -> (root: Int, minor: Bool, confidence: Double)? {
        guard chroma.count == 12, chroma.contains(where: { $0 > 0 }) else { return nil }
        // Square-rooted so one loud partial does not decide the key.
        let v = chroma.map { Double($0).squareRoot() }
        var scores: [(Double, Int, Bool)] = []
        for root in 0..<12 {
            for isMinor in [false, true] {
                let profile = isMinor ? minor : major
                let rotated = (0..<12).map { profile[($0 - root + 12) % 12] }
                scores.append((correlation(v, rotated), root, isMinor))
            }
        }
        scores.sort { $0.0 > $1.0 }
        guard let top = scores.first, scores.count > 1 else { return nil }
        let r = max(0, top.0), gap = top.0 - scores[1].0
        // A key counts as trusted when it fits well and clearly beats the runner-up (a relative key often runs close, so a small gap is normal).
        let confidence = min(1, r) * min(1, max(0, gap) / 0.08)
        return (top.1, top.2, confidence)
    }

    private static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let ma = a.reduce(0, +) / 12, mb = b.reduce(0, +) / 12
        var num = 0.0, da = 0.0, db = 0.0
        for i in 0..<12 { num += (a[i] - ma) * (b[i] - mb); da += (a[i] - ma) * (a[i] - ma); db += (b[i] - mb) * (b[i] - mb) }
        return da > 0 && db > 0 ? num / (da * db).squareRoot() : 0
    }
}

// MARK: the analyzer

enum MusicBeatAnalyzer {
    /// Decoded rate: 22.05 kHz mono keeps everything up to 11 kHz, which is all the onset and key work needs, at a quarter of the cost of 44.1 kHz stereo.
    static let analysisRate = 22_050.0
    static let energyStep = 0.5
    /// A song shorter than this is not analysed (the planner would never mix it anyway).
    static let minSeconds = 20.0
    /// The longest stretch decoded; a longer file is analysed from its first ten minutes (its tail is then unknown, so it is not mixed).
    static let maxSeconds = 600.0
    /// Below this level (dBFS, 50 ms blocks) a moment counts as silence. -50 dB sits above dither and tape hiss and below the quietest
    /// musical passage, so it marks where a song really starts and ends.
    static let silenceDB = -50.0
    /// An outro is the stretch at the end where the smoothed loudness stays under 30% of the song's loud level.
    static let outroLevel: Float = 0.30

    /// Pure analysis of mono samples. Never throws: a clip too short comes back marked failed.
    static func analyze(samples: [Float], sampleRate: Double) -> MusicTrackAnalysis {
        let duration = Double(samples.count) / sampleRate
        guard duration >= minSeconds else { return .failedEntry(duration: duration) }
        var a = MusicTrackAnalysis()
        a.duration = duration

        // Levels: the true start and end.
        let block = max(1, Int(sampleRate * 0.05))
        var levels: [Float] = []
        samples.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress else { return }
            var i = 0
            while i < samples.count {
                let len = min(block, samples.count - i)
                var rms: Float = 0
                vDSP_rmsqv(base + i, 1, &rms, vDSP_Length(len))
                levels.append(rms)
                i += block
            }
        }
        let floor = Float(pow(10, silenceDB / 20))
        let firstLoud = levels.firstIndex { $0 >= floor }
        let lastLoud = levels.lastIndex { $0 >= floor }
        guard let first = firstLoud, let last = lastLoud, last > first else { return .failedEntry(duration: duration) }
        a.audibleStart = Double(first) * 0.05
        a.contentEnd = min(duration, Double(last + 1) * 0.05)

        // Loudness every half second against the song's own 90th-percentile level.
        let per = Int(energyStep / 0.05)
        var halves: [Float] = []
        var i = 0
        while i < levels.count {
            let slice = levels[i..<min(levels.count, i + per)]
            halves.append((slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count)).squareRoot())
            i += per
        }
        let audible = halves.filter { $0 >= floor }.sorted()
        let reference = audible.isEmpty ? 0 : audible[min(audible.count - 1, Int(Double(audible.count) * 0.9))]
        a.energy = reference > 0 ? halves.map { min(1, $0 / reference) } : halves.map { _ in 0 }
        a.outroStart = outro(energy: a.energy, contentEnd: a.contentEnd, duration: duration)

        // Pulse, bars and key.
        let frames = MusicSpectralAnalysis.measure(samples: samples, sampleRate: sampleRate)
        if let k = MusicKeyEstimator.estimate(chroma: frames.chroma) {
            a.keyRoot = k.root; a.keyIsMinor = k.minor; a.keyConfidence = k.confidence
        }
        if frames.flux.count > 64, let t = MusicTempoEstimator.estimate(onset: frames.flux, frameRate: frames.frameRate) {
            let tracked = MusicTempoEstimator.trackBeats(onset: frames.flux, frameRate: frames.frameRate, bpm: t.bpm, phase: t.phase)
            let latency = Double(MusicSpectralAnalysis.latencySamples) / sampleRate
            let beats = tracked.beats.map { $0 + latency }.filter { $0 < duration }
            if beats.count >= 8 {
                a.bpm = (t.bpm * 100).rounded() / 100
                a.beats = beats.map { ($0 * 1000).rounded() / 1000 }
                // Half the weight on how well the curve repeats at the beat lag, half on how much stronger beats are than the gaps between them.
                let raw = 0.5 * min(1, t.periodicity / 0.6) + 0.5 * min(1, tracked.contrast / 0.6)
                // Random noise still scores about 0.25 on the raw measure, so that much is taken off before scaling back to 0...1.
                a.confidence = max(0, min(1, (raw - 0.25) / 0.75))
                a.downbeatOffset = downbeatOffset(beats: beats, flux: frames.flux, low: frames.lowFlux, frameRate: frames.frameRate, latency: latency)
            }
        }
        (a.mixIn, a.mixOut) = mixPoints(a)
        return a
    }

    /// Bar position: the beat of each four whose onset (kick band counted double) is strongest.
    static func downbeatOffset(beats: [Double], flux: [Float], low: [Float], frameRate: Double, latency: Double) -> Int {
        var sums = [Double](repeating: 0, count: 4), counts = [Double](repeating: 0, count: 4)
        for (i, b) in beats.enumerated() {
            let f = Int(((b - latency) * frameRate).rounded())
            guard f >= 1, f < flux.count - 1 else { continue }
            let v = Double(max(flux[f - 1], flux[f], flux[f + 1])) + 2 * Double(max(low[f - 1], low[f], low[f + 1]))
            sums[i % 4] += v; counts[i % 4] += 1
        }
        let means = (0..<4).map { counts[$0] > 0 ? sums[$0] / counts[$0] : 0 }
        return means.enumerated().max { $0.element < $1.element }?.offset ?? 0
    }

    /// First time from which the 2 s smoothed loudness never rises above `outroLevel` up to the end; nil under 3 s of it or in the first half.
    static func outro(energy: [Float], contentEnd: Double, duration: Double) -> Double? {
        guard energy.count > 8 else { return nil }
        let endIndex = min(energy.count - 1, Int(contentEnd / energyStep))
        func smooth(_ i: Int) -> Float {
            let lo = max(0, i - 3)
            return energy[lo...i].reduce(0, +) / Float(i - lo + 1)
        }
        var start = endIndex + 1
        var j = endIndex
        while j >= 0, smooth(j) < outroLevel { start = j; j -= 1 }
        // The smoothing looks backwards, so the crossing is seen about a second after it happened.
        let t = max(0, Double(start) * energyStep - 1.0)
        guard start <= endIndex, contentEnd - t >= 3, t > contentEnd * 0.5 else { return nil }
        return t
    }

    /// Candidate places to enter and leave a song, all on bar lines when a grid exists.
    static func mixPoints(_ a: MusicTrackAnalysis) -> (in: [MusicTrackAnalysis.MixPoint], out: [MusicTrackAnalysis.MixPoint]) {
        let bars = a.downbeats
        func snapForward(_ t: Double) -> Double { bars.first { $0 >= t - 0.05 } ?? t }
        func snapBack(_ t: Double) -> Double { bars.last { $0 <= t + 0.05 } ?? t }
        var ins: [MusicTrackAnalysis.MixPoint] = []
        var outs: [MusicTrackAnalysis.MixPoint] = []
        let first = snapForward(a.audibleStart)
        ins.append(.init(time: first, kind: .firstBar, score: 0.6))
        // The intro ends at the first bar whose following second is loud (70% of the song's loud level).
        if let d = bars.first(where: { $0 >= first && a.energy(at: $0 + 1) >= 0.7 }), d <= a.duration * 0.25, d > first + 1 {
            ins.append(.init(time: d, kind: .introEnd, score: 0.8))
        }
        let beatsPerPhrase = 16.0
        if a.hasGrid {
            var k = 1.0
            while let t = bars.first(where: { $0 >= first + k * beatsPerPhrase * a.beatInterval - 0.05 }), t <= a.duration * 0.25 {
                ins.append(.init(time: t, kind: .phrase, score: 0.5)); k += 1
                if k > 8 { break }
            }
        }
        if let o = a.outroStart { outs.append(.init(time: snapBack(o), kind: .outroStart, score: 0.9)) }
        outs.append(.init(time: a.contentEnd, kind: .contentEnd, score: 0.7))
        if a.hasGrid, let t = bars.last(where: { $0 <= a.contentEnd - 6 }), t > a.contentEnd * 0.5 {
            outs.append(.init(time: t, kind: .lastPhrase, score: 0.6))
        }
        return (ins.sorted { $0.time < $1.time }, outs.sorted { $0.time < $1.time })
    }

    // MARK: decoding

    enum DecodeError: Error { case noAudio, cannotRead(String) }

    /// Decodes `url` to mono float samples at 22.05 kHz. The reader does the sample-rate conversion. Runs off the main actor.
    static func decode(_ url: URL, maxSeconds: Double = MusicBeatAnalyzer.maxSeconds) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw DecodeError.noAudio }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: maxSeconds, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: analysisRate, AVNumberOfChannelsKey: 1,
        ])
        guard reader.canAdd(output) else { throw DecodeError.cannotRead("unsupported audio") }
        reader.add(output)
        guard reader.startReading() else { throw DecodeError.cannotRead(reader.error?.localizedDescription ?? "cannot start reading") }
        var samples: [Float] = []
        samples.reserveCapacity(Int(analysisRate * 300))
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = chunk.withUnsafeMutableBytes { buffer -> OSStatus in
                guard let destination = buffer.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: destination)
            }
            if status == noErr { samples.append(contentsOf: chunk) }
        }
        if reader.status == .failed { throw DecodeError.cannotRead(reader.error?.localizedDescription ?? "read failed") }
        return samples
    }

    /// Decodes and analyses. A file that cannot be read comes back as a failed entry so the same file is not retried.
    static func analyze(url: URL) async -> MusicTrackAnalysis {
        do {
            let samples = try await decode(url)
            return await Task.detached(priority: .utility) { analyze(samples: samples, sampleRate: analysisRate) }.value
        } catch {
            return .failedEntry(duration: 0)
        }
    }
}
