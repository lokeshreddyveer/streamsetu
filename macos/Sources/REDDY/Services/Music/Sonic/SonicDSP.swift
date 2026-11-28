import Foundation
import Accelerate

/// The signal processing behind sonic analysis. Plain functions over mono samples: no files, no player, no network, so each can be checked on synthesised audio.
enum SonicDSP {
    static let sampleRate = 22_050.0

    // MARK: spectra

    /// Short-time magnitude spectra of `x` (frame size a power of two, Hann window), as `frames x (n/2)` rows.
    static func spectra(_ x: [Float], n: Int, hop: Int) -> [[Float]] {
        guard x.count >= n, let setup = vDSP_create_fftsetup(vDSP_Length(log2(Double(n))), FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let half = n / 2
        var real = [Float](repeating: 0, count: half), imag = [Float](repeating: 0, count: half)
        var frame = [Float](repeating: 0, count: n)
        var out: [[Float]] = []
        var start = 0
        while start + n <= x.count {
            vDSP_vmul(Array(x[start..<start + n]), 1, window, 1, &frame, 1, vDSP_Length(n))
            var mags = [Float](repeating: 0, count: half)
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) }
                    }
                    vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2(Double(n))), FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
                }
            }
            var scale: Float = 1 / Float(n)
            vDSP_vsmul(mags, 1, &scale, &mags, 1, vDSP_Length(half))
            out.append(mags)
            start += hop
        }
        return out
    }

    // MARK: tempo

    /// The onset envelope: positive spectral change between frames, summed over bins (log-compressed), one value per frame.
    static func onsetEnvelope(_ spec: [[Float]]) -> [Float] {
        guard spec.count > 2 else { return [] }
        var env = [Float](repeating: 0, count: spec.count)
        var prev = spec[0].map { log1p(10 * $0) }
        for i in 1..<spec.count {
            let cur = spec[i].map { log1p(10 * $0) }
            var flux: Float = 0
            for k in 0..<cur.count { let d = cur[k] - prev[k]; if d > 0 { flux += d } }
            env[i] = flux
            prev = cur
        }
        return env
    }

    /// Tempo from the onset envelope by autocorrelation, with a mild preference for 70 to 160 BPM so a half-time or double-time pulse resolves to the felt tempo.
    /// Returns nil for a recording with no steady pulse.
    static func tempo(envelope env: [Float], frameRate: Double) -> (bpm: Double, confidence: Double, histogram: [Float])? {
        guard env.count > Int(frameRate * 6) else { return nil }
        var e = env
        var mean: Float = 0; vDSP_meanv(e, 1, &mean, vDSP_Length(e.count))
        var neg = -mean; vDSP_vsadd(e, 1, &neg, &e, 1, vDSP_Length(e.count))
        let minLag = max(2, Int(frameRate * 60 / 220)), maxLag = min(e.count / 2, Int(frameRate * 60 / 48))
        guard maxLag > minLag + 2 else { return nil }
        var ac = [Float](repeating: 0, count: maxLag + 2)
        for lag in minLag...(maxLag + 1) {
            var s: Float = 0
            let n = e.count - lag
            e.withUnsafeBufferPointer { p in vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + lag, 1, &s, vDSP_Length(n)) }
            ac[lag] = s / Float(n)
        }
        var zero: Float = 0
        e.withUnsafeBufferPointer { p in vDSP_dotpr(p.baseAddress!, 1, p.baseAddress!, 1, &zero, vDSP_Length(e.count)) }
        let norm = zero / Float(e.count)
        guard norm > 1e-6 else { return nil }
        var best = 0, bestScore: Float = 0
        var scores = [Float](repeating: 0, count: ac.count)
        for lag in minLag...maxLag {
            let bpm = 60 * frameRate / Double(lag)
            let prior = Float(exp(-pow(log2(bpm / 112), 2) / (2 * 0.6 * 0.6)))
            scores[lag] = ac[lag] / norm * (0.55 + 0.45 * prior)
            if scores[lag] > bestScore { bestScore = scores[lag]; best = lag }
        }
        guard best > 0, bestScore > 0.08 else { return nil }
        // Parabolic refinement around the peak.
        var lag = Double(best)
        if best > minLag, best < maxLag {
            let a = Double(ac[best - 1]), b = Double(ac[best]), c = Double(ac[best + 1])
            let d = a - 2 * b + c
            if abs(d) > 1e-9 { lag += 0.5 * (a - c) / d }
        }
        let bpm = 60 * frameRate / lag
        // A beat histogram: how much autocorrelation sits in eight tempo bands from 50 to 200 BPM.
        var hist = [Float](repeating: 0, count: 8)
        for l in minLag...maxLag {
            let b = 60 * frameRate / Double(l)
            let band = Int(max(0, min(7.999, 8 * log2(b / 50) / 2)))
            hist[band] += max(0, ac[l])
        }
        let total = hist.reduce(0, +)
        if total > 0 { hist = hist.map { $0 / total } }
        return (bpm, Double(min(1, bestScore)), hist)
    }

    // MARK: key

    /// A twelve-bin pitch-class profile summed over a spectrogram (frames of `n` samples at `sampleRate`), 65 Hz to 2 kHz.
    static func chromaProfile(_ spec: [[Float]], n: Int) -> [Float] {
        var chroma = [Float](repeating: 0, count: 12)
        guard let first = spec.first else { return chroma }
        let binHz = sampleRate / Double(n)
        var map = [Int](repeating: -1, count: first.count)
        for k in 1..<first.count {
            let f = Double(k) * binHz
            guard f >= 65, f <= 2000 else { continue }
            let midi = 69 + 12 * log2(f / 440)
            map[k] = ((Int(midi.rounded()) % 12) + 12) % 12
        }
        for row in spec { for k in 1..<row.count where map[k] >= 0 { chroma[map[k]] += sqrtf(row[k]) } }
        let total = chroma.reduce(0, +)
        return total > 0 ? chroma.map { $0 / total } : chroma
    }

    private static let majorProfile: [Float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private static let minorProfile: [Float] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    private static func correlation(_ a: [Float], _ b: [Float]) -> Float {
        let n = Float(a.count)
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var num: Float = 0, da: Float = 0, db: Float = 0
        for i in 0..<a.count { let x = a[i] - ma, y = b[i] - mb; num += x * y; da += x * x; db += y * y }
        let d = (da * db).squareRoot()
        return d > 0 ? num / d : 0
    }

    /// The key whose Krumhansl-Kessler profile best matches the pitch-class profile, with how much better it fits than the runner-up.
    static func key(chroma: [Float]) -> (tonic: Int, minor: Bool, confidence: Double)? {
        guard chroma.count == 12, chroma.reduce(0, +) > 0 else { return nil }
        var best = (tonic: 0, minor: false, r: Float(-2)), second: Float = -2
        for minor in [false, true] {
            let profile = minor ? minorProfile : majorProfile
            for t in 0..<12 {
                var rotated = [Float](repeating: 0, count: 12)
                for i in 0..<12 { rotated[(i + t) % 12] = profile[i] }
                let r = correlation(chroma, rotated)
                if r > best.r { second = best.r; best = (t, minor, r) } else if r > second { second = r }
            }
        }
        let conf = Double(max(0, min(1, (best.r - second) * 4 + max(0, best.r - 0.5))))
        return best.r > 0.45 ? (best.tonic, best.minor, conf) : nil
    }

    // MARK: level and dynamics

    /// Level in dB below full scale of every 400 ms block, ignoring digital silence.
    static func blockLevels(_ x: [Float]) -> [Double] {
        let size = Int(sampleRate * 0.4)
        guard x.count >= size else { return [] }
        var out: [Double] = []
        var i = 0
        while i + size <= x.count {
            var rms: Float = 0
            x.withUnsafeBufferPointer { p in vDSP_rmsqv(p.baseAddress! + i, 1, &rms, vDSP_Length(size)) }
            out.append(20 * log10(Double(max(rms, 1e-6))))
            i += size
        }
        return out
    }

    static func percentile(_ v: [Double], _ p: Double) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s[Int((Double(s.count - 1) * p).rounded())]
    }

    // MARK: structure

    /// Section boundaries from how the sound changes over time: features per second, a self-similarity matrix, and a checkerboard novelty curve.
    static func sections(chroma frames: [[Float]], energy: [Float], secondsPerFeature: Double, totalSeconds: Double) -> [SonicProfile.Section] {
        let n = frames.count
        guard n >= 24 else { return [] }
        var feats = [[Float]](repeating: [], count: n)
        let maxE = max(energy.max() ?? 1, 1e-6)
        for i in 0..<n {
            var f = frames[i]
            let norm = max(f.reduce(0) { $0 + $1 * $1 }.squareRoot(), 1e-6)
            f = f.map { $0 / norm }
            f.append(energy[i] / maxE)
            feats[i] = f
        }
        func sim(_ a: Int, _ b: Int) -> Float {
            var d: Float = 0; for k in 0..<feats[a].count { d += feats[a][k] * feats[b][k] }
            let na = feats[a].reduce(0) { $0 + $1 * $1 }.squareRoot(), nb = feats[b].reduce(0) { $0 + $1 * $1 }.squareRoot()
            return d / max(na * nb, 1e-6)
        }
        let half = min(8, n / 4)
        var novelty = [Float](repeating: 0, count: n)
        for t in half..<(n - half) {
            var s: Float = 0
            for i in 0..<half { for j in 0..<half {
                s += sim(t - 1 - i, t - 1 - j) + sim(t + i, t + j) - sim(t - 1 - i, t + j) - sim(t + i, t - 1 - j)
            } }
            novelty[t] = max(0, s)
        }
        var mean: Float = 0, sd: Float = 0
        vDSP_normalize(novelty, 1, nil, 1, &mean, &sd, vDSP_Length(n))
        let threshold = mean + sd
        let minGap = max(1, Int(10 / secondsPerFeature))
        var peaks: [Int] = []
        for t in half..<(n - half) where novelty[t] > threshold && novelty[t] >= novelty[t - 1] && novelty[t] >= novelty[t + 1] {
            if let last = peaks.last, t - last < minGap { if novelty[t] > novelty[last] { peaks[peaks.count - 1] = t } } else { peaks.append(t) }
        }
        var bounds = [0] + peaks + [n]
        bounds = Array(Set(bounds)).sorted()
        guard bounds.count >= 3 else { return [] }
        // Group segments that sound alike (same label letter).
        var means: [[Float]] = []
        for s in 0..<(bounds.count - 1) {
            var m = [Float](repeating: 0, count: feats[0].count)
            for i in bounds[s]..<bounds[s + 1] { for k in 0..<m.count { m[k] += feats[i][k] } }
            let c = Float(max(1, bounds[s + 1] - bounds[s])); means.append(m.map { $0 / c })
        }
        var groups = [Int](repeating: -1, count: means.count)
        var next = 0
        for i in 0..<means.count where groups[i] < 0 {
            groups[i] = next
            for j in (i + 1)..<means.count where groups[j] < 0 && cosine(means[i], means[j]) > 0.97 { groups[j] = next }
            next += 1
        }
        var out: [SonicProfile.Section] = []
        for s in 0..<(bounds.count - 1) {
            let start = Double(bounds[s]) * secondsPerFeature
            let end = s == bounds.count - 2 ? totalSeconds : Double(bounds[s + 1]) * secondsPerFeature
            let unique = groups.filter { $0 == groups[s] }.count == 1
            var label = SonicProfile.Section.Label.section
            if s == 0, unique, end - start < totalSeconds * 0.25 { label = .intro }
            if s == bounds.count - 2, unique, end - start < totalSeconds * 0.25 { label = .outro }
            out.append(SonicProfile.Section(start: start, end: end, label: label, group: groups[s]))
        }
        return out
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var d: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { d += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        let m = (na * nb).squareRoot()
        return m > 0 ? d / m : 0
    }
}
