import Foundation
import AVFoundation
import AudioToolbox

// Audio conversion for the person's own files (or files they are allowed to convert). Nothing is uploaded; the original is never changed: every result is a new file.
// Built on the system's audio converter, so the formats are the ones this Mac can write: AAC, Apple Lossless, FLAC, WAV, AIFF and Opus. (MP3 and Ogg Vorbis cannot be written by the system.)

enum MusicConvertFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case aac, alac, flac, wav, aiff, opus
    var id: String { rawValue }
    var title: String {
        switch self {
        case .aac: "AAC"; case .alac: "Apple Lossless"; case .flac: "FLAC"; case .wav: "WAV"; case .aiff: "AIFF"; case .opus: "Opus"
        }
    }
    var fileExtension: String {
        switch self { case .aac, .alac: "m4a"; case .flac: "flac"; case .wav: "wav"; case .aiff: "aiff"; case .opus: "opus" }
    }
    var isLossy: Bool { self == .aac || self == .opus }
    /// Formats whose depth the person can choose.
    var hasBitDepth: Bool { self == .flac || self == .wav || self == .aiff || self == .alac }
    var formatID: AudioFormatID {
        switch self { case .aac: kAudioFormatMPEG4AAC; case .alac: kAudioFormatAppleLossless; case .flac: kAudioFormatFLAC; case .wav, .aiff: kAudioFormatLinearPCM; case .opus: kAudioFormatOpus }
    }
    var tagsCanBeWritten: Bool { self == .aac || self == .alac }
}

struct MusicConversionPreset: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var format: MusicConvertFormat
    /// nil keeps the source's rate / channels.
    var sampleRate: Double?
    var channels: Int?
    var bitDepth: Int = 16
    var bitrateKbps: Int = 256

    static let builtIn: [MusicConversionPreset] = [
        .init(id: "phone", name: "Phone or car (AAC 256 kbps)", format: .aac, sampleRate: 44100, channels: 2, bitrateKbps: 256),
        .init(id: "small", name: "Small files (AAC 128 kbps)", format: .aac, sampleRate: 44100, channels: 2, bitrateKbps: 128),
        .init(id: "archive", name: "Archive (FLAC, 24-bit)", format: .flac, sampleRate: nil, channels: nil, bitDepth: 24),
        .init(id: "apple", name: "Apple devices (Apple Lossless)", format: .alac, sampleRate: nil, channels: nil, bitDepth: 16),
        .init(id: "cd", name: "CD quality (WAV 16-bit 44.1 kHz)", format: .wav, sampleRate: 44100, channels: 2, bitDepth: 16),
        .init(id: "old", name: "Older players (WAV 16-bit, mono)", format: .wav, sampleRate: 44100, channels: 1, bitDepth: 16),
    ]
}

enum MusicConvertError: Error, Equatable, Sendable {
    case cannotRead, formatUnavailable(String), cannotWrite, cancelled, verification(String), exists
    var message: String {
        switch self {
        case .cannotRead: Localized.string("This file could not be read.")
        case .formatUnavailable(let f): Localized.string("This Mac cannot write %@.", f)
        case .cannotWrite: Localized.string("The new file could not be written.")
        case .cancelled: Localized.string("Cancelled.")
        case .verification(let s): Localized.string("The new file did not pass the check: %@", s)
        case .exists: Localized.string("A file with that name is already there.")
        }
    }
}

enum MusicConverter {
    /// The writer settings for a preset (pure).
    static func settings(for p: MusicConversionPreset, sourceRate: Double, sourceChannels: Int) -> [String: Any] {
        let rate = p.sampleRate ?? sourceRate
        let ch = p.channels ?? min(2, sourceChannels)
        var s: [String: Any] = [AVFormatIDKey: p.format.formatID, AVSampleRateKey: rate, AVNumberOfChannelsKey: ch]
        switch p.format {
        case .aac, .opus: s[AVEncoderBitRateKey] = p.bitrateKbps * 1000 * (ch == 1 ? 1 : 1)
        case .alac, .flac: s[AVEncoderBitDepthHintKey] = p.bitDepth
        case .wav, .aiff:
            s[AVLinearPCMBitDepthKey] = p.bitDepth; s[AVLinearPCMIsFloatKey] = p.bitDepth == 32
            s[AVLinearPCMIsBigEndianKey] = p.format == .aiff; s[AVLinearPCMIsNonInterleaved] = false
        }
        return s
    }

    /// A file name for the result that does not overwrite anything: "Song.m4a", then "Song 2.m4a".
    static func output(for source: URL, in folder: URL, format: MusicConvertFormat, name: String? = nil) -> URL {
        let base = MusicRenameTemplate.clean(name ?? source.deletingPathExtension().lastPathComponent)
        var url = folder.appendingPathComponent(base).appendingPathExtension(format.fileExtension)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(format.fileExtension); n += 1 }
        return url
    }

    /// Converts one or more files into one (joining), optionally only the part between `range` seconds of the first input.
    /// `progress` gets 0...1. Returns the number of seconds written.
    @discardableResult
    static func convert(inputs: [URL], to output: URL, preset: MusicConversionPreset, range: ClosedRange<Double>? = nil,
                        progress: @Sendable (Double) -> Void, isCancelled: @Sendable () -> Bool) async throws -> Double {
        guard let first = inputs.first, let probe = try? AVAudioFile(forReading: first) else { throw MusicConvertError.cannotRead }
        let src = probe.processingFormat
        let settings = settings(for: preset, sourceRate: src.sampleRate, sourceChannels: Int(src.channelCount))
        guard let outFile = try? AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false) else {
            throw MusicConvertError.formatUnavailable(preset.format.title)
        }
        let target = outFile.processingFormat
        var totalFrames = 0.0
        for u in inputs { if let f = try? AVAudioFile(forReading: u) { totalFrames += Double(f.length) / f.processingFormat.sampleRate * target.sampleRate } }
        totalFrames = max(1, totalFrames)
        var written: AVAudioFramePosition = 0
        do {
            for (index, url) in inputs.enumerated() {
                guard let file = try? AVAudioFile(forReading: url) else { throw MusicConvertError.cannotRead }
                let inFormat = file.processingFormat
                let sameFormat = inFormat.sampleRate == target.sampleRate && inFormat.channelCount == target.channelCount && inFormat.commonFormat == target.commonFormat
                let conv = sameFormat ? nil : AVAudioConverter(from: inFormat, to: target)
                if !sameFormat, conv == nil { throw MusicConvertError.formatUnavailable(preset.format.title) }
                var startFrame: AVAudioFramePosition = 0, endFrame = file.length
                if index == 0, let r = range {
                    startFrame = AVAudioFramePosition(max(0, r.lowerBound) * inFormat.sampleRate)
                    endFrame = min(file.length, AVAudioFramePosition(r.upperBound * inFormat.sampleRate))
                    totalFrames = max(1, Double(endFrame - startFrame) / inFormat.sampleRate * target.sampleRate)
                }
                file.framePosition = startFrame
                let chunk: AVAudioFrameCount = 16384
                guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk) else { throw MusicConvertError.cannotRead }
                var remaining = endFrame - startFrame
                // The source already has the output's sample rate, channels and sample type: its frames are written as they are (the converter has nothing to do, and asked to
                // convert nothing it never reports the end).
                if sameFormat {
                    while remaining > 0 {
                        if isCancelled() { throw MusicConvertError.cancelled }
                        inBuf.frameLength = 0
                        do { try file.read(into: inBuf, frameCount: AVAudioFrameCount(min(AVAudioFramePosition(chunk), remaining))) } catch { break }
                        if inBuf.frameLength == 0 { break }
                        remaining -= AVAudioFramePosition(inBuf.frameLength)
                        do { try outFile.write(from: inBuf) } catch { throw MusicConvertError.cannotWrite }
                        written += AVAudioFramePosition(inBuf.frameLength)
                        progress(min(1, Double(written) / totalFrames))
                        await Task.yield()
                    }
                    continue
                }
                guard let conv else { throw MusicConvertError.formatUnavailable(preset.format.title) }
                var ended = false
                var idle = 0
                while !ended {
                    if isCancelled() { throw MusicConvertError.cancelled }
                    let outCap = AVAudioFrameCount(Double(chunk) * target.sampleRate / inFormat.sampleRate) + 4096
                    guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) else { throw MusicConvertError.cannotWrite }
                    var convError: NSError?
                    let status = conv.convert(to: outBuf, error: &convError) { _, inStatus in
                        if remaining <= 0 { inStatus.pointee = .endOfStream; return nil }
                        let want = AVAudioFrameCount(min(AVAudioFramePosition(chunk), remaining))
                        inBuf.frameLength = 0
                        do { try file.read(into: inBuf, frameCount: want) } catch { inStatus.pointee = .endOfStream; return nil }
                        if inBuf.frameLength == 0 { inStatus.pointee = .endOfStream; return nil }
                        remaining -= AVAudioFramePosition(inBuf.frameLength)
                        inStatus.pointee = .haveData
                        return inBuf
                    }
                    if status == .error { throw MusicConvertError.cannotWrite }
                    if outBuf.frameLength > 0 {
                        do { try outFile.write(from: outBuf) } catch { throw MusicConvertError.cannotWrite }
                        written += AVAudioFramePosition(outBuf.frameLength)
                        progress(min(1, Double(written) / totalFrames))
                    }
                    // A converter that has nothing left but does not say so must not hold the job: three empty answers in a row, with the input used up, end it.
                    if outBuf.frameLength == 0 { idle += 1 } else { idle = 0 }
                    if status == .endOfStream || (remaining <= 0 && idle >= 3) { ended = true }
                    await Task.yield()
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return Double(written) / target.sampleRate
    }

    /// Opens the result and checks that it is audio of about the length it should be.
    static func verify(_ url: URL, expectedSeconds: Double) -> MusicConvertError? {
        guard let f = try? AVAudioFile(forReading: url) else { return .verification(Localized.string("it cannot be opened")) }
        let seconds = Double(f.length) / f.processingFormat.sampleRate
        if seconds < 0.1 { return .verification(Localized.string("it is empty")) }
        if abs(seconds - expectedSeconds) > max(0.5, expectedSeconds * 0.01) { return .verification(Localized.string("its length is %@ s instead of %@ s", String(Int(seconds.rounded())), String(Int(expectedSeconds.rounded())))) }
        return nil
    }

    /// Writes the tags and cover of the source into a converted AAC or Apple Lossless file. Other formats carry no tags the system can write.
    static func carryOver(_ entry: LocalEntry?, to output: URL, format: MusicConvertFormat) async {
        guard let e = entry, format.tagsCanBeWritten else { return }
        let patch = LocalEntryPatch(title: e.title, artist: e.artist, album: e.album, albumArtist: e.albumArtist, genre: e.genre, year: e.year, trackNumber: e.trackNumber, discNumber: e.discNumber)
        _ = await LocalTagFileWriter.write(patch, to: output)
    }
}
