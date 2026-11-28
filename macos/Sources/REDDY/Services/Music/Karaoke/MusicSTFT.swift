import Accelerate
import Foundation

/// Transform sizes of one separation model. A wrong n_fft or stem does not crash, it only leaves more vocals in, so the values travel with the model, never with the UI.
struct MusicSTFTConfig: Sendable, Hashable, Codable {
    var nFFT: Int
    var hop: Int
    var dimF: Int
    var dimT: Int
    /// Multiplier applied to the model output once the chunks are blended.
    var compensate: Float

    /// Samples one model call covers: hop x (dimT - 1).
    var chunk: Int { hop * (dimT - 1) }
    /// Half a window of silence in front of the song, so the first real sample is inside a full window.
    var trim: Int { nFFT / 2 }
    /// Samples of a chunk that are free of window edges.
    var gen: Int { chunk - 2 * trim }
    var bins: Int { nFFT / 2 + 1 }
    /// Distance between chunk starts. The overlap is exactly one FFT window.
    var step: Int { chunk - nFFT }
    /// Floats in the model tensor [1, 4, dimF, dimT].
    var tensorCount: Int { 4 * dimF * dimT }
    var isValid: Bool {
        nFFT >= 64 && hop > 0 && dimT > 2 && dimF > 3 && dimF <= nFFT / 2 + 1 && chunk > nFFT && nFFT % 2 == 0 && Self.isSupportedFFTSize(nFFT)
    }

    /// vDSP's real DFT takes f x 2^n with f in {1, 3, 5, 15} and n >= 4.
    static func isSupportedFFTSize(_ n: Int) -> Bool {
        for f in [1, 3, 5, 15] where n % f == 0 {
            let p = n / f
            if p >= 16 && p & (p - 1) == 0 { return true }
        }
        return false
    }
}

/// What the model emits: the vocals (instrumental is then mixture minus output) or the instrumental itself.
enum MusicKaraokeStem: String, Sendable, Codable { case vocals, instrumental }

/// The three quality tiers. The tier stores only a key; the transform values are the published ones for the model family.
enum MusicKaraokeTier: String, CaseIterable, Identifiable, Sendable, Codable {
    case light, balanced, best
    var id: String { rawValue }

    static func from(key: String?) -> MusicKaraokeTier { key.flatMap(MusicKaraokeTier.init(rawValue:)) ?? .light }

    var title: String {
        switch self { case .light: "Light"; case .balanced: "Balanced"; case .best: "Best" }
    }
    var detail: String {
        switch self {
        case .light: "Fastest, but can leave a little of the vocals in. Keeps up with playback on a processor."
        case .balanced: "Nearly as clean as Best, and quicker. Keeps up with playback on a fast processor."
        case .best: "Best quality, but slow. On a processor it cannot keep up with playback, so it is meant for a graphics chip."
        }
    }
    var bars: Int { switch self { case .light: 1; case .balanced: 2; case .best: 3 } }
    var config: MusicSTFTConfig {
        switch self {
        case .light: MusicSTFTConfig(nFFT: 6144, hop: 1024, dimF: 2048, dimT: 256, compensate: 1.035)
        case .balanced: MusicSTFTConfig(nFFT: 5120, hop: 1024, dimF: 2048, dimT: 256, compensate: 1.025)
        case .best: MusicSTFTConfig(nFFT: 6144, hop: 1024, dimF: 3072, dimT: 256, compensate: 1.022)
        }
    }
    var stem: MusicKaraokeStem { self == .light ? .vocals : .instrumental }
}

/// Forward and inverse short-time transforms for one channel of one chunk, built on vDSP's real DFT.
/// Not thread safe: make one per worker.
final class MusicSTFT {
    let config: MusicSTFTConfig
    private let forwardSetup: vDSP_DFT_Setup
    private let inverseSetup: vDSP_DFT_Setup
    private let window: [Float]
    private let windowSquared: [Float]
    private let n: Int
    private let half: Int
    // Scratch, allocated once because a song runs hundreds of chunks.
    private let framePtr: UnsafeMutablePointer<Float>
    private let splitRe: UnsafeMutablePointer<Float>
    private let splitIm: UnsafeMutablePointer<Float>
    private let outRe: UnsafeMutablePointer<Float>
    private let outIm: UnsafeMutablePointer<Float>

    init?(config: MusicSTFTConfig) {
        guard config.isValid,
              let f = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(config.nFFT), .FORWARD),
              let b = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(config.nFFT), .INVERSE) else { return nil }
        self.config = config
        forwardSetup = f; inverseSetup = b
        n = config.nFFT; half = config.nFFT / 2
        // Periodic Hann: 0.5 - 0.5 cos(2 pi i / n).
        var w = [Float](repeating: 0, count: config.nFFT)
        for i in 0..<config.nFFT { w[i] = Float(0.5 - 0.5 * cos(2.0 * Double.pi * Double(i) / Double(config.nFFT))) }
        window = w
        windowSquared = w.map { $0 * $0 }
        framePtr = .allocate(capacity: config.nFFT)
        splitRe = .allocate(capacity: config.nFFT / 2); splitIm = .allocate(capacity: config.nFFT / 2)
        outRe = .allocate(capacity: config.nFFT / 2); outIm = .allocate(capacity: config.nFFT / 2)
    }

    deinit {
        vDSP_DFT_DestroySetup(forwardSetup); vDSP_DFT_DestroySetup(inverseSetup)
        framePtr.deallocate(); splitRe.deallocate(); splitIm.deallocate(); outRe.deallocate(); outIm.deallocate()
    }

    var frameCount: Int { config.dimT }

    /// Centred framing: the signal is extended by n/2 on each side by mirroring without repeating the edge sample.
    static func reflectPadded(_ x: [Float], by pad: Int) -> [Float] {
        let len = x.count
        var out = [Float](repeating: 0, count: len + 2 * pad)
        guard len > 1 else { return out }
        for i in 0..<len { out[pad + i] = x[i] }
        for i in 1...pad {
            out[pad - i] = x[min(i, len - 1)]
            out[pad + len - 1 + i] = x[max(len - 1 - i, 0)]
        }
        return out
    }

    /// Spectrum of `x` (exactly one chunk). Result layout: index `bin * frames + frame`, `bins` rows. No scaling and no magnitude transform.
    func forward(_ x: [Float]) -> (re: [Float], im: [Float]) {
        let frames = config.dimT
        var re = [Float](repeating: 0, count: config.bins * frames)
        var im = re
        guard x.count == config.chunk else { return (re, im) }
        let padded = Self.reflectPadded(x, by: half)
        // vDSP's real transform returns twice the textbook DFT; halve it to get the plain spectrum.
        let scale: Float = 0.5
        padded.withUnsafeBufferPointer { p in
            window.withUnsafeBufferPointer { win in
                for t in 0..<frames {
                    vDSP_vmul(p.baseAddress! + t * config.hop, 1, win.baseAddress!, 1, framePtr, 1, vDSP_Length(n))
                    var split = DSPSplitComplex(realp: splitRe, imagp: splitIm)
                    UnsafeRawPointer(framePtr).withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                    vDSP_DFT_Execute(forwardSetup, splitRe, splitIm, outRe, outIm)
                    re[t] = outRe[0] * scale                       // DC
                    re[half * frames + t] = outIm[0] * scale       // Nyquist is packed into the DC imaginary slot
                    for k in 1..<half {
                        re[k * frames + t] = outRe[k] * scale
                        im[k * frames + t] = outIm[k] * scale
                    }
                }
            }
        }
        return (re, im)
    }

    /// Back to samples. `re`/`im` use the same layout as `forward`; rows past what the model produced must already be zero.
    func inverse(re: [Float], im: [Float]) -> [Float] {
        let frames = config.dimT
        let total = (frames - 1) * config.hop + n
        var acc = [Float](repeating: 0, count: total)
        var norm = [Float](repeating: 0, count: total)
        guard re.count == config.bins * frames, im.count == re.count else { return [Float](repeating: 0, count: config.chunk) }
        let inv = 1 / Float(n)
        acc.withUnsafeMutableBufferPointer { a in
            norm.withUnsafeMutableBufferPointer { nrm in
                window.withUnsafeBufferPointer { win in
                    windowSquared.withUnsafeBufferPointer { w2 in
                        for t in 0..<frames {
                            splitRe[0] = re[t]                    // DC, imaginary part forced to zero
                            splitIm[0] = re[half * frames + t]    // Nyquist, imaginary part forced to zero
                            for k in 1..<half {
                                splitRe[k] = re[k * frames + t]
                                splitIm[k] = im[k * frames + t]
                            }
                            vDSP_DFT_Execute(inverseSetup, splitRe, splitIm, outRe, outIm)
                            var split = DSPSplitComplex(realp: outRe, imagp: outIm)
                            UnsafeMutableRawPointer(framePtr).withMemoryRebound(to: DSPComplex.self, capacity: half) {
                                vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half))
                            }
                            var s = inv
                            vDSP_vsmul(framePtr, 1, &s, framePtr, 1, vDSP_Length(n))
                            vDSP_vmul(framePtr, 1, win.baseAddress!, 1, framePtr, 1, vDSP_Length(n))
                            let off = t * config.hop
                            vDSP_vadd(a.baseAddress! + off, 1, framePtr, 1, a.baseAddress! + off, 1, vDSP_Length(n))
                            vDSP_vadd(nrm.baseAddress! + off, 1, w2.baseAddress!, 1, nrm.baseAddress! + off, 1, vDSP_Length(n))
                        }
                    }
                }
            }
        }
        var out = [Float](repeating: 0, count: config.chunk)
        for i in 0..<config.chunk {
            let j = i + half
            let d = norm[j]
            out[i] = d >= 1e-8 ? acc[j] / d : acc[j]
        }
        return out
    }

    // MARK: Model tensor

    /// [1, 4, dimF, dimT] float: left real, left imaginary, right real, right imaginary. Bins 0...2 are forced to zero; bins at dimF and above are dropped.
    func tensor(left: (re: [Float], im: [Float]), right: (re: [Float], im: [Float])) -> [Float] {
        let frames = config.dimT, dimF = config.dimF
        var t = [Float](repeating: 0, count: config.tensorCount)
        let planes = [left.re, left.im, right.re, right.im]
        for (c, plane) in planes.enumerated() {
            let base = c * dimF * frames
            for f in 3..<dimF {
                let src = f * frames, dst = base + f * frames
                for i in 0..<frames { t[dst + i] = plane[src + i] }
            }
        }
        return t
    }

    /// Rebuilds full-width spectra from a model output tensor; bins past dimF are zero.
    func spectra(from tensor: [Float]) -> (left: (re: [Float], im: [Float]), right: (re: [Float], im: [Float])) {
        let frames = config.dimT, dimF = config.dimF
        var planes = [[Float]](repeating: [Float](repeating: 0, count: config.bins * frames), count: 4)
        guard tensor.count == config.tensorCount else { return ((planes[0], planes[1]), (planes[2], planes[3])) }
        for c in 0..<4 {
            let base = c * dimF * frames
            planes[c].withUnsafeMutableBufferPointer { dst in
                tensor.withUnsafeBufferPointer { src in
                    for f in 0..<dimF {
                        let o = f * frames
                        for i in 0..<frames { dst[o + i] = src[base + o + i] }
                    }
                }
            }
        }
        return ((planes[0], planes[1]), (planes[2], planes[3]))
    }
}
