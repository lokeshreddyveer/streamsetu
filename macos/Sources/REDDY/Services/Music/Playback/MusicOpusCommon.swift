import Foundation

// Shared pieces of the Opus path: the stream header, the packet length rules, the container sniffing and the events a demuxer produces.
// Apple's player cannot open WebM or Ogg, so these streams are demuxed here, decoded with the system Opus decoder and played through the
// audio engine (see MusicOpusPlayback). Everything in this file is pure and has no platform dependency.

enum MusicOpusError: Error, Equatable, LocalizedError, Sendable {
    /// The container or codec is one this path does not handle (Vorbis, video-only files, surround Opus).
    case unsupported(String)
    /// The bytes do not follow the container format.
    case malformed(String)
    /// This system has no Opus decoder.
    case unavailable
    case network(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let s): "This audio format is not supported (\(s))"
        case .malformed(let s): "The audio file is damaged (\(s))"
        case .unavailable: "This system cannot decode Opus audio"
        case .network(let s): "The audio could not be loaded (\(s))"
        }
    }
}

/// The OpusHead packet (RFC 7845 section 5.1), also the CodecPrivate of an A_OPUS Matroska track.
struct MusicOpusHead: Equatable, Sendable {
    var channels: Int
    /// Samples at 48 kHz to drop from the start of the decoded output.
    var preSkip: Int
    /// The rate of the original input; informational, output is always 48 kHz.
    var inputRate: Int
    /// Output gain in Q7.8 dB.
    var outputGainQ8: Int
    var mappingFamily: Int

    var gainLinear: Float { outputGainQ8 == 0 ? 1 : Float(pow(10.0, Double(outputGainQ8) / (20.0 * 256.0))) }

    static func parse(_ d: [UInt8]) -> MusicOpusHead? {
        guard d.count >= 19, Array(d[0..<8]) == Array("OpusHead".utf8), d[8] >> 4 == 0 else { return nil }
        let channels = Int(d[9])
        guard channels >= 1 else { return nil }
        let preSkip = Int(d[10]) | Int(d[11]) << 8
        let rate = Int(d[12]) | Int(d[13]) << 8 | Int(d[14]) << 16 | Int(d[15]) << 24
        let gain = Int(Int16(bitPattern: UInt16(d[16]) | UInt16(d[17]) << 8))
        return MusicOpusHead(channels: channels, preSkip: preSkip, inputRate: rate, outputGainQ8: gain, mappingFamily: Int(d[18]))
    }

    /// A header for a track whose CodecPrivate is missing or unreadable.
    static func fallback(channels: Int, codecDelayNs: Int64) -> MusicOpusHead {
        MusicOpusHead(channels: max(1, channels), preSkip: Int(max(0, codecDelayNs) * 48_000 / 1_000_000_000), inputRate: 48_000, outputGainQ8: 0, mappingFamily: 0)
    }

    /// Serialised form, used by the tests' own muxers.
    func bytes() -> [UInt8] {
        var b = Array("OpusHead".utf8)
        b.append(1); b.append(UInt8(channels))
        b.append(UInt8(preSkip & 0xFF)); b.append(UInt8((preSkip >> 8) & 0xFF))
        for i in 0..<4 { b.append(UInt8((inputRate >> (8 * i)) & 0xFF)) }
        let g = UInt16(bitPattern: Int16(truncatingIfNeeded: outputGainQ8))
        b.append(UInt8(g & 0xFF)); b.append(UInt8(g >> 8))
        b.append(UInt8(mappingFamily))
        return b
    }
}

/// One Opus packet with the time its first sample is due, in seconds on the container's own clock.
struct MusicOpusPacket: Sendable, Equatable {
    var data: [UInt8]
    var time: Double
    /// Samples at 48 kHz the packet decodes to.
    var samples: Int
    /// Samples to drop from the end of the last packet of a stream (Matroska DiscardPadding, or Ogg end-of-stream granule).
    var discardEnd = 0
}

struct MusicOpusCue: Equatable, Sendable {
    var time: Double
    /// Matroska: the byte offset of the cluster relative to the start of the segment payload.
    var position: Int64
}

struct MusicOpusTrackInfo: Equatable, Sendable {
    var head: MusicOpusHead
    var duration: Double?
}

enum MusicOpusEvent: Sendable, Equatable {
    case track(MusicOpusTrackInfo)
    case duration(Double)
    case cues([MusicOpusCue])
    case packet(MusicOpusPacket)
}

// MARK: packet length (RFC 6716 section 3.1)

enum MusicOpusTOC {
    /// Samples at 48 kHz in a packet, or nil when the packet is empty or malformed.
    static func samples(in p: [UInt8]) -> Int? {
        guard let toc = p.first else { return nil }
        let config = Int(toc >> 3)
        let perFrame: Int // samples at 48 kHz
        switch config {
        case 0...11: perFrame = [480, 960, 1920, 2880][config & 3]
        case 12...15: perFrame = (config & 1) == 0 ? 480 : 960
        default: perFrame = [120, 240, 480, 960][config & 3]
        }
        let frames: Int
        switch toc & 3 {
        case 0: frames = 1
        case 1, 2: frames = 2
        default:
            guard p.count >= 2 else { return nil }
            frames = Int(p[1] & 0x3F)
            guard frames >= 1 else { return nil }
        }
        let total = frames * perFrame
        return total <= 5760 ? total : nil
    }

    /// Channel count the TOC byte declares (bit 2 is the stereo flag).
    static func isStereo(_ p: [UInt8]) -> Bool? { p.first.map { $0 & 0x04 != 0 } }
}

// MARK: containers

enum MusicMediaContainer: Equatable, Sendable {
    case webm, ogg, mp4, other

    /// By magic bytes: EBML header, "OggS", or "ftyp" at offset 4.
    static func sniff(_ head: [UInt8]) -> MusicMediaContainer {
        if head.count >= 4, head[0] == 0x1A, head[1] == 0x45, head[2] == 0xDF, head[3] == 0xA3 { return .webm }
        if head.count >= 4, head[0] == 0x4F, head[1] == 0x67, head[2] == 0x67, head[3] == 0x53 { return .ogg }
        if head.count >= 8, head[4] == 0x66, head[5] == 0x74, head[6] == 0x79, head[7] == 0x70 { return .mp4 }
        return .other
    }

    /// By the MIME type a server sent, ignoring parameters.
    static func from(mime: String) -> MusicMediaContainer? {
        let m = mime.lowercased().split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        switch m {
        case "audio/webm", "video/webm", "audio/x-matroska", "video/x-matroska", "audio/matroska": return .webm
        case "audio/ogg", "application/ogg", "audio/opus", "audio/x-opus+ogg", "video/ogg": return .ogg
        case "audio/mp4", "video/mp4", "audio/x-m4a", "audio/aac": return .mp4
        default: return nil
        }
    }

    /// What a stream's own description says, when it says anything useful. Nil means "look at the bytes".
    static func declared(container: String, codec: String, url: URL?) -> MusicMediaContainer? {
        switch container.lowercased() {
        case "webm", "mkv", "matroska", "weba": return .webm
        case "ogg", "oga", "opus", "ogx": return .ogg
        case "mp4", "m4a", "aac", "mp3", "flac", "wav", "caf", "aiff", "m4b", "alac": return .mp4
        default: break
        }
        switch url?.pathExtension.lowercased() ?? "" {
        case "webm", "weba", "mkv": return .webm
        case "ogg", "oga", "opus", "ogx": return .ogg
        case "mp4", "m4a", "aac", "mp3", "flac", "wav", "caf", "aif", "aiff": return .mp4
        default: return nil
        }
    }
}
