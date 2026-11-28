import Foundation
#if os(macOS)
import AVFoundation
import CChromaprint

/// Fingerprints a song inside the app: the file is decoded by AVFoundation, the first two minutes go through the vendored Chromaprint (the same algorithm
/// and length `fpcalc` uses), and the result is the same compact fingerprint string plus the song's length in seconds. Nothing is installed, no helper process runs,
/// the audio never leaves the device, and a cancelled task stops between blocks.
enum ChromaprintLibrary {
    static let seconds = 120
    private static let block: AVAudioFrameCount = 16_384

    enum Failure: Error, Equatable, Sendable { case unreadable, tooShort }

    static func fingerprint(_ url: URL) async throws -> (duration: Int, fingerprint: String) {
        try await Task.detached(priority: .utility) { try make(url) }.value
    }

    private static func make(_ url: URL) throws -> (duration: Int, fingerprint: String) {
        guard let file = try? AVAudioFile(forReading: url) else { throw Failure.unreadable }
        let inFormat = file.processingFormat
        let rate = inFormat.sampleRate
        guard rate >= 1000, file.length > 0 else { throw Failure.unreadable }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inFormat, to: target),
              let ctx = chromaprint_new(Int32(CHROMAPRINT_ALGORITHM_DEFAULT.rawValue)) else { throw Failure.unreadable }
        defer { chromaprint_free(ctx) }
        guard chromaprint_start(ctx, Int32(rate), 1) == 1 else { throw Failure.unreadable }

        let wanted = AVAudioFramePosition(Double(seconds) * rate)
        var fed: AVAudioFramePosition = 0
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: block),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: block) else { throw Failure.unreadable }
        while fed < wanted, file.framePosition < file.length {
            try Task.checkCancellation()
            inBuffer.frameLength = 0
            do { try file.read(into: inBuffer, frameCount: block) } catch { throw Failure.unreadable }
            if inBuffer.frameLength == 0 { break }
            outBuffer.frameLength = 0
            var consumed = false
            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error) { _, flag in
                if consumed { flag.pointee = .noDataNow; return nil }
                consumed = true; flag.pointee = .haveData; return inBuffer
            }
            if status == .error || error != nil { throw Failure.unreadable }
            let n = Int(outBuffer.frameLength)
            guard n > 0, let data = outBuffer.int16ChannelData?[0] else { continue }
            let take = min(n, Int(wanted - fed))
            guard chromaprint_feed(ctx, data, Int32(take)) == 1 else { throw Failure.unreadable }
            fed += AVAudioFramePosition(take)
        }
        guard chromaprint_finish(ctx) == 1 else { throw Failure.unreadable }
        var raw: UnsafeMutablePointer<CChar>?
        guard chromaprint_get_fingerprint(ctx, &raw) == 1, let raw else { throw Failure.unreadable }
        defer { chromaprint_dealloc(raw) }
        let fp = String(cString: raw)
        guard !fp.isEmpty else { throw Failure.tooShort }
        return (Int((Double(file.length) / rate).rounded()), fp)
    }
}
#endif

/// The one way the app fingerprints a file: the built-in Chromaprint first, and the person's own `fpcalc` only if the built-in one cannot read the file.
enum ChromaprintEngine {
    static func fingerprint(_ url: URL) async throws -> (duration: Int, fingerprint: String) {
        #if os(macOS)
        do { return try await ChromaprintLibrary.fingerprint(url) }
        catch is CancellationError { throw CancellationError() }
        catch { if ChromaprintTool.locate() == nil { throw ChromaprintTool.Failure.unreadable } }
        #endif
        return try await ChromaprintTool.fingerprint(url)
    }
}
