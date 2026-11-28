import Foundation
import Accelerate

// The numbers behind every visualizer, from the latest samples. Pure: samples in, numbers out.

struct MusicVisualFrame: Sendable {
    /// Log-spaced band levels 0...1 (low to high pitch).
    var bands: [Float]
    var waveform: [Float]
    var leftPoints: [Float], rightPoints: [Float]
    var peakL: Float, peakR: Float, rmsL: Float, rmsR: Float
    /// Left/right correlation, -1 (out of phase) ... 1 (mono).
    var correlation: Float
    static let silent = MusicVisualFrame(bands: [], waveform: [], leftPoints: [], rightPoints: [], peakL: 0, peakR: 0, rmsL: 0, rmsR: 0, correlation: 0)
}

final class MusicVisualizerAnalyzer: @unchecked Sendable {
    static let fftSize = 2048
    let bandCount: Int
    private let setup: FFTSetup
    private let log2n: vDSP_Length
    private var window: [Float]
    private var smoothed: [Float]
    private var peakHold: (l: Float, r: Float) = (0, 0)

    init(bands: Int = 56) {
        bandCount = bands
        log2n = vDSP_Length(log2(Double(Self.fftSize)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        smoothed = [Float](repeating: 0, count: bands)
    }
    deinit { vDSP_destroy_fftsetup(setup) }

    /// `sensitivity` scales levels (1 is neutral); `smoothing` 0...0.95 is how slowly bars fall.
    func analyse(left: [Float], right: [Float], sampleRate: Double, sensitivity: Float = 1, smoothing: Float = 0.7) -> MusicVisualFrame {
        let n = Self.fftSize
        guard left.count >= n, right.count >= n else { return .silent }
        let l = Array(left.suffix(n)), r = Array(right.suffix(n))
        var mono = [Float](repeating: 0, count: n)
        vDSP_vadd(l, 1, r, 1, &mono, 1, vDSP_Length(n))
        var half: Float = 0.5
        vDSP_vsmul(mono, 1, &half, &mono, 1, vDSP_Length(n))
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(mono, 1, window, 1, &windowed, 1, vDSP_Length(n))
        var real = [Float](repeating: 0, count: n / 2), imag = real
        var mags = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { rp in imag.withUnsafeMutableBufferPointer { ip in
            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            windowed.withUnsafeBufferPointer { wp in wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2)) } }
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(n / 2))
        } }
        var scale = 2 / Float(n)
        vDSP_vsmul(mags, 1, &scale, &mags, 1, vDSP_Length(n / 2))
        // Log-spaced bands from 30 Hz to 16 kHz; each band is the loudest bin in it, in decibels mapped to 0...1 over a 60 dB range.
        let nyquist = Float(sampleRate / 2), lo: Float = 30, hi = min(16_000, nyquist * 0.98)
        var bands = [Float](repeating: 0, count: bandCount)
        for b in 0..<bandCount {
            let f0 = lo * pow(hi / lo, Float(b) / Float(bandCount)), f1 = lo * pow(hi / lo, Float(b + 1) / Float(bandCount))
            let i0 = max(1, Int(f0 / nyquist * Float(n / 2))), i1 = max(i0 + 1, min(n / 2, Int(f1 / nyquist * Float(n / 2)) + 1))
            var m: Float = 0
            for i in i0..<i1 { m = max(m, mags[i]) }
            let db = 20 * log10(max(m * sensitivity, 1e-7))
            bands[b] = min(1, max(0, (db + 60) / 60))
        }
        for b in 0..<bandCount { smoothed[b] = bands[b] > smoothed[b] ? bands[b] : smoothed[b] * smoothing + bands[b] * (1 - smoothing) }
        var peakL: Float = 0, peakR: Float = 0, rmsL: Float = 0, rmsR: Float = 0
        vDSP_maxmgv(l, 1, &peakL, vDSP_Length(n)); vDSP_maxmgv(r, 1, &peakR, vDSP_Length(n))
        vDSP_rmsqv(l, 1, &rmsL, vDSP_Length(n)); vDSP_rmsqv(r, 1, &rmsR, vDSP_Length(n))
        var dot: Float = 0, el: Float = 0, er: Float = 0
        vDSP_dotpr(l, 1, r, 1, &dot, vDSP_Length(n)); vDSP_dotpr(l, 1, l, 1, &el, vDSP_Length(n)); vDSP_dotpr(r, 1, r, 1, &er, vDSP_Length(n))
        let corr = el > 1e-9 && er > 1e-9 ? dot / (el * er).squareRoot() : 0
        peakHold = (max(peakL, peakHold.l * 0.96), max(peakR, peakHold.r * 0.96))
        let step = max(1, n / 512)
        let wave = stride(from: 0, to: n, by: step).map { mono[$0] * sensitivity }
        let pts = stride(from: 0, to: n, by: 4)
        return MusicVisualFrame(bands: smoothed, waveform: wave, leftPoints: pts.map { l[$0] * sensitivity }, rightPoints: pts.map { r[$0] * sensitivity },
                                peakL: peakHold.l, peakR: peakHold.r, rmsL: rmsL * sensitivity, rmsR: rmsR * sensitivity, correlation: corr)
    }
}

enum MusicVisualizerMode: String, CaseIterable, Identifiable, Sendable {
    case spectrum, oscilloscope, spectrogram, meters, radial, phase, vectorscope
    var id: String { rawValue }
    var title: String {
        switch self {
        case .spectrum: Localized.string("Spectrum")
        case .oscilloscope: Localized.string("Oscilloscope")
        case .spectrogram: Localized.string("Spectrogram")
        case .meters: Localized.string("Level meters")
        case .radial: Localized.string("Radial")
        case .phase: Localized.string("Phase")
        case .vectorscope: Localized.string("Vectorscope")
        }
    }
}

/// A saved look: the mode, the colours, how lively it is, and how often it draws.
struct MusicVisualizerPreset: Codable, Equatable, Identifiable, Sendable {
    enum Colour: String, Codable, CaseIterable, Sendable { case theme, fire, ocean, mono }
    var id: String
    var name: String
    var mode: String
    var colour: Colour
    var sensitivity: Double
    var smoothing: Double

    static let builtIn: [MusicVisualizerPreset] = [
        .init(id: "calm", name: "Calm spectrum", mode: "spectrum", colour: .theme, sensitivity: 1, smoothing: 0.85),
        .init(id: "club", name: "Club", mode: "radial", colour: .fire, sensitivity: 1.4, smoothing: 0.55),
        .init(id: "studio", name: "Studio meters", mode: "meters", colour: .mono, sensitivity: 1, smoothing: 0.7),
        .init(id: "scope", name: "Scope", mode: "vectorscope", colour: .ocean, sensitivity: 1.2, smoothing: 0.7),
    ]
}

enum MusicVisualizerPrefs {
    static let modeKey = "music.visualizer.mode", fpsKey = "music.visualizer.fps", colourKey = "music.visualizer.colour"
    static let sensitivityKey = "music.visualizer.sensitivity", smoothingKey = "music.visualizer.smoothing"
    static let fpsChoices = [15, 30, 60]
}
