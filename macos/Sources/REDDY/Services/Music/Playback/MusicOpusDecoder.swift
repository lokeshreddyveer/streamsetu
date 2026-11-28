import Foundation
import AVFoundation
import AudioToolbox

/// Decodes Opus packets with the decoder that ships in the operating system (Core Audio, `kAudioFormatOpus`). No Opus code is bundled.
///
/// One instance belongs to one pipeline and is used from one thread at a time. The output is 48 kHz, Float32, non-interleaved, with the
/// channel count of the stream (1 or 2). The pre-skip and the output gain from OpusHead are applied here, and a missing packet can be
/// concealed with the decoder's own loss concealment.
final class MusicOpusDecoder: @unchecked Sendable {
    /// Whether this system can decode Opus at all. Checked once: the answer cannot change while the app runs.
    static let isAvailable: Bool = {
        guard let f = format(channels: 2, framesPerPacket: 960) else { return false }
        return AVAudioConverter(from: f, to: pcmFormat(channels: 2)) != nil
    }()

    static func pcmFormat(channels: Int) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: AVAudioChannelCount(channels), interleaved: false)
            ?? AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: AVAudioChannelCount(channels))!
    }

    static func format(channels: Int, framesPerPacket: Int) -> AVAudioFormat? {
        var d = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
                                            mFramesPerPacket: UInt32(framesPerPacket), mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
                                            mBitsPerChannel: 0, mReserved: 0)
        return AVAudioFormat(streamDescription: &d)
    }

    let head: MusicOpusHead
    let outputFormat: AVAudioFormat
    private var converters: [Int: AVAudioConverter] = [:]
    private var skipRemaining: Int
    /// Frames the system decoder drops from its first output after it is created (it reports fewer frames than the packet holds).
    private var firstOutputPending = true
    private var lastSamples = 960

    init(head: MusicOpusHead) throws {
        guard head.channels == 1 || head.channels == 2 else { throw MusicOpusError.unsupported("\(head.channels)-channel Opus") }
        guard head.mappingFamily == 0 else { throw MusicOpusError.unsupported("Opus channel mapping \(head.mappingFamily)") }
        guard Self.isAvailable else { throw MusicOpusError.unavailable }
        self.head = head
        self.outputFormat = Self.pcmFormat(channels: head.channels)
        self.skipRemaining = head.preSkip
        _ = try converter(for: 960)
    }

    /// Forget decoder state, for a seek. No pre-skip applies after a seek: the caller decodes a short run-in and discards it.
    func reset(applyPreSkip: Bool = false) {
        converters = [:]
        skipRemaining = applyPreSkip ? head.preSkip : 0
        firstOutputPending = true
    }

    private func converter(for samples: Int) throws -> AVAudioConverter {
        if let c = converters[samples] { return c }
        guard let f = Self.format(channels: head.channels, framesPerPacket: samples), let c = AVAudioConverter(from: f, to: outputFormat) else { throw MusicOpusError.unavailable }
        converters[samples] = c
        return c
    }

    /// Decodes one packet. Returns nil when the whole packet is trimmed away (pre-skip) or when `keep` is false (run-in after a seek).
    func decode(_ packet: MusicOpusPacket, keep: Bool = true) throws -> AVAudioPCMBuffer? {
        lastSamples = packet.samples
        let raw = try run(packet.data, samples: packet.samples)
        return finish(raw, expected: packet.samples, discardEnd: packet.discardEnd, keep: keep)
    }

    /// Fills a gap of one packet with the decoder's concealment: the same call with no data.
    func conceal(samples: Int? = nil) throws -> AVAudioPCMBuffer? {
        let n = samples ?? lastSamples
        let raw = try run([], samples: n)
        return finish(raw, expected: n, discardEnd: 0, keep: true)
    }

    private func run(_ data: [UInt8], samples: Int) throws -> AVAudioPCMBuffer {
        let conv = try converter(for: samples)
        let maxBytes = max(data.count, 1)
        let cb = AVAudioCompressedBuffer(format: conv.inputFormat, packetCapacity: 1, maximumPacketSize: maxBytes)
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(samples)) else { throw MusicOpusError.malformed("buffer") }
        var used = false
        var failure: NSError?
        let status = conv.convert(to: out, error: &failure) { _, state in
            if used { state.pointee = .noDataNow; return nil }
            used = true
            data.withUnsafeBytes { if let base = $0.baseAddress { cb.data.copyMemory(from: base, byteCount: data.count) } }
            cb.packetCount = 1
            cb.byteLength = UInt32(data.count)
            cb.packetDescriptions?[0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(data.count))
            state.pointee = .haveData
            return cb
        }
        if status == .error { throw MusicOpusError.malformed(failure?.localizedDescription ?? "decode failed") }
        return out
    }

    private func finish(_ buf: AVAudioPCMBuffer, expected: Int, discardEnd: Int, keep: Bool) -> AVAudioPCMBuffer? {
        var start = 0
        var count = Int(buf.frameLength)
        if firstOutputPending {
            firstOutputPending = false
            // What the system decoder already removed counts toward the pre-skip.
            let alreadyDropped = max(0, expected - count)
            skipRemaining = max(0, skipRemaining - alreadyDropped)
        }
        if skipRemaining > 0 {
            let n = min(skipRemaining, count)
            start += n; count -= n; skipRemaining -= n
        }
        if discardEnd > 0 { count = max(0, count - discardEnd) }
        guard keep, count > 0, let ch = buf.floatChannelData else { return nil }
        let gain = head.gainLinear
        if start > 0 || count != Int(buf.frameLength) {
            guard let trimmed = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(count)), let dst = trimmed.floatChannelData else { return nil }
            for c in 0..<Int(outputFormat.channelCount) { dst[c].update(from: ch[c] + start, count: count) }
            trimmed.frameLength = AVAudioFrameCount(count)
            applyGain(trimmed, gain)
            return trimmed
        }
        applyGain(buf, gain)
        return buf
    }

    private func applyGain(_ b: AVAudioPCMBuffer, _ g: Float) {
        guard g != 1, let ch = b.floatChannelData else { return }
        for c in 0..<Int(b.format.channelCount) { for i in 0..<Int(b.frameLength) { ch[c][i] *= g } }
    }
}
