import Foundation
#if os(macOS)
import AVFoundation
import Accelerate

/// Measures one recording: decodes at most three minutes to mono, then runs the signal processing once. Runs off the main thread, checks for cancellation between
/// blocks, and never reads more than it needs. Instrument recognition and vocal classification are not part of it: neither can be measured honestly without a
/// trained model, so the profile simply has no such field.
enum SonicAnalyzer {
    static let maxSeconds = 180.0
    enum Failure: Error, Equatable, Sendable { case unreadable, tooShort }

    static func analyse(_ url: URL) async throws -> SonicProfile {
        try await Task.detached(priority: .background) { try run(url) }.value
    }

    /// Decodes up to `maxSeconds` of the file to mono Float at the analysis rate.
    static func decode(_ url: URL) throws -> [Float] {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { throw Failure.unreadable }
        let inFormat = file.processingFormat
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: SonicDSP.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: target),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: 16_384),
              let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 16_384) else { throw Failure.unreadable }
        var out: [Float] = []
        let wanted = Int(maxSeconds * SonicDSP.sampleRate)
        out.reserveCapacity(min(wanted, Int(Double(file.length) / inFormat.sampleRate * SonicDSP.sampleRate) + 1024))
        while out.count < wanted, file.framePosition < file.length {
            try Task.checkCancellation()
            inBuf.frameLength = 0
            do { try file.read(into: inBuf, frameCount: 16_384) } catch { throw Failure.unreadable }
            if inBuf.frameLength == 0 { break }
            var fed = false
            var error: NSError?
            outBuf.frameLength = 0
            let status = converter.convert(to: outBuf, error: &error) { _, flag in
                if fed { flag.pointee = .noDataNow; return nil }
                fed = true; flag.pointee = .haveData; return inBuf
            }
            if status == .error || error != nil { throw Failure.unreadable }
            if let data = outBuf.floatChannelData?[0] { out.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(outBuf.frameLength))) }
        }
        return out
    }

    private static func run(_ url: URL) throws -> SonicProfile {
        let x = try decode(url)
        return try profile(of: x)
    }

    /// The analysis of decoded mono samples at `SonicDSP.sampleRate` (separate from decoding so it can be tested on synthesised signals).
    static func profile(of x: [Float]) throws -> SonicProfile {
        let rate = SonicDSP.sampleRate
        guard Double(x.count) / rate >= 8 else { throw Failure.tooShort }
        var p = SonicProfile()
        p.analysedSeconds = Double(x.count) / rate

        // level and dynamics
        let levels = SonicDSP.blockLevels(x).filter { $0 > -70 }
        var peak: Float = 0
        x.withUnsafeBufferPointer { vDSP_maxmgv($0.baseAddress!, 1, &peak, vDSP_Length(x.count)) }
        p.peakDB = 20 * log10(Double(max(peak, 1e-6)))
        if !levels.isEmpty {
            p.levelDB = levels.reduce(0, +) / Double(levels.count)
            p.dynamicRangeDB = max(0, SonicDSP.percentile(levels, 0.95) - SonicDSP.percentile(levels, 0.10))
        }
        try Task.checkCancellation()

        // tempo from a fine spectrogram
        let fineHop = 256
        let fine = SonicDSP.spectra(x, n: 1024, hop: fineHop)
        let env = SonicDSP.onsetEnvelope(fine)
        let frameRate = rate / Double(fineHop)
        if let t = SonicDSP.tempo(envelope: env, frameRate: frameRate) {
            p.bpm = (t.bpm * 10).rounded() / 10; p.bpmConfidence = t.confidence; p.rhythm = t.histogram
        } else { p.rhythm = [Float](repeating: 0, count: 8) }
        try Task.checkCancellation()

        // key and timbre from a coarse spectrogram
        let n = 4096
        let coarse = SonicDSP.spectra(x, n: n, hop: n / 2)
        let chroma = SonicDSP.chromaProfile(coarse, n: n)
        if let k = SonicDSP.key(chroma: chroma) { p.keyTonic = k.tonic; p.keyIsMinor = k.minor; p.keyConfidence = k.confidence }
        let binHz = rate / Double(n)
        var centroids: [Double] = [], rolloffs: [Double] = []
        for row in coarse {
            var num = 0.0, den = 0.0
            for (k, m) in row.enumerated() { num += Double(k) * binHz * Double(m); den += Double(m) }
            centroids.append(den > 0 ? num / den : 0)
            var acc = 0.0, roll = 0.0
            for (k, m) in row.enumerated() { acc += Double(m); if acc >= 0.85 * den { roll = Double(k) * binHz; break } }
            rolloffs.append(roll)
        }
        p.brightnessHz = centroids.isEmpty ? 0 : centroids.reduce(0, +) / Double(centroids.count)
        let onsetDensity = env.isEmpty ? 0 : Double(env.reduce(0, +)) / Double(env.count)

        // energy: level, activity, brightness and tempo, each mapped to 0...1
        func clamp(_ v: Double) -> Double { max(0, min(1, v)) }
        let levelPart = clamp((p.levelDB + 40) / 32)
        let activity = clamp(onsetDensity / 6)
        let bright = clamp(p.brightnessHz / 3500)
        let tempoPart = clamp(((p.bpm ?? 90) - 60) / 110)
        p.energy = (0.35 * levelPart + 0.25 * activity + 0.2 * bright + 0.2 * tempoPart * (p.bpmConfidence > 0.15 ? 1 : 0.5))
        try Task.checkCancellation()

        // structure: one feature per second from the coarse frames
        let perFeature = max(1, Int((1.0 / (Double(n / 2) / rate)).rounded()))
        var feats: [[Float]] = [], e: [Float] = []
        var i = 0
        while i + perFeature <= coarse.count {
            let slice = Array(coarse[i..<i + perFeature])
            feats.append(SonicDSP.chromaProfile(slice, n: n))
            var s: Float = 0; for r in slice { for m in r { s += m } }
            e.append(s); i += perFeature
        }
        p.sections = SonicDSP.sections(chroma: feats, energy: e, secondsPerFeature: Double(perFeature) * Double(n / 2) / rate, totalSeconds: p.analysedSeconds)

        // the sound vector
        var v: [Float] = [
            Float(p.brightnessHz / 4000), Float((rolloffs.reduce(0, +) / Double(max(1, rolloffs.count))) / 8000), Float(onsetDensity / 6),
            Float((p.levelDB + 60) / 60), Float(p.dynamicRangeDB / 30), Float((p.bpm ?? 0) / 200), Float(p.energy)
        ]
        v += chroma.map { $0 * 3 }
        p.vector = v
        return p
    }
}
#endif
