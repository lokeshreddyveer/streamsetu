import Testing
import Foundation
#if os(macOS)
import AVFoundation
@testable import REDDY

@Suite("Built-in fingerprinting")
struct ChromaprintLibraryTests {
    /// A real audio file: a two-tone melody written as a WAV by AVFoundation, so the whole path (decode, resample, FFT, fingerprint) runs on actual audio.
    private func wav(rate: Double, seconds: Double, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).wav")
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true))
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let frames = AVAudioFrameCount(rate * seconds)
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buf.frameLength = frames
        let p = try #require(buf.int16ChannelData?[0])
        let notes: [Double] = [262, 330, 392, 494, 349, 440, 523, 294]
        for i in 0..<Int(frames) {
            let t = Double(i) / rate
            let f = notes[Int(t * 2) % notes.count]
            p[i] = Int16(9000 * sin(2 * .pi * f * t) + 4000 * sin(2 * .pi * f * 2 * t))
        }
        try file.write(from: buf)
        return url
    }

    @Test func realAudioGivesAFingerprintAndItsLengthAndTheSameAudioGivesTheSameOne() async throws {
        let url = try wav(rate: 44_100, seconds: 12, name: "melody")
        defer { try? FileManager.default.removeItem(at: url) }
        let a = try await ChromaprintLibrary.fingerprint(url)
        let b = try await ChromaprintLibrary.fingerprint(url)
        #expect(a.duration == 12)
        #expect(a.fingerprint.count > 20)
        #expect(a.fingerprint == b.fingerprint)
        #expect(ChromaprintOutput.parse(Data(#"{"duration":12,"fingerprint":"\#(a.fingerprint)"}"#.utf8))?.fingerprint == a.fingerprint)
    }

    @Test func differentAudioGivesADifferentFingerprint() async throws {
        let a = try wav(rate: 44_100, seconds: 12, name: "a")
        let url2 = FileManager.default.temporaryDirectory.appendingPathComponent("noise-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: url2) }
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44_100, channels: 1, interleaved: true))
        do {      // the writer is closed (and the file finished) when this block ends
            let file = try AVAudioFile(forWriting: url2, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            let buf = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100 * 12)); buf.frameLength = 44_100 * 12
            let p = try #require(buf.int16ChannelData?[0])
            var g = SystemRandomNumberGenerator()
            for i in 0..<Int(buf.frameLength) { p[i] = Int16.random(in: -6000...6000, using: &g) }
            try file.write(from: buf)
        }
        let fa = try await ChromaprintLibrary.fingerprint(a)
        let fb = try await ChromaprintLibrary.fingerprint(url2)
        #expect(fa.fingerprint != fb.fingerprint)
    }

    @Test func aFileThatIsNotAudioIsUnreadableNotACrash() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-audio-\(UUID().uuidString).wav")
        try? Data("not audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        do { _ = try await ChromaprintLibrary.fingerprint(url); Issue.record("expected a failure") } catch { #expect(error as? ChromaprintLibrary.Failure == .unreadable) }
    }

    @Test func aCancelledFingerprintStops() async throws {
        let url = try wav(rate: 44_100, seconds: 30, name: "long")
        defer { try? FileManager.default.removeItem(at: url) }
        let task = Task { try await ChromaprintLibrary.fingerprint(url) }
        task.cancel()
        do { _ = try await task.value } catch { #expect(error is CancellationError) }
    }
}
#endif
