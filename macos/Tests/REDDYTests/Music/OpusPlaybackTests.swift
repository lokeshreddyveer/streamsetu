import Foundation
import AVFoundation
import AudioToolbox
import Testing
@testable import REDDY

// MARK: fixture writers (test-only muxers) and a tone encoder built on the system Opus encoder

enum OpusFixtures {
    // EBML writing
    static func idBytes(_ id: UInt32) -> [UInt8] {
        var b: [UInt8] = []
        var v = id
        while v > 0 { b.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return b
    }

    static func sizeBytes(_ n: Int, width: Int? = nil) -> [UInt8] {
        var len = width ?? 1
        while width == nil, n >= (1 << (7 * len)) - 1 { len += 1 }
        var out = [UInt8](repeating: 0, count: len)
        var v = n
        for i in (0..<len).reversed() { out[i] = UInt8(v & 0xFF); v >>= 8 }
        out[0] |= UInt8(0x80 >> (len - 1))
        return out
    }

    static func unknownSize(width: Int = 8) -> [UInt8] {
        var out = [UInt8](repeating: 0xFF, count: width)
        out[0] = UInt8(0xFF >> (width - 1))
        return out
    }

    static func el(_ id: UInt32, _ payload: [UInt8], sizeWidth: Int? = nil, unknown: Bool = false) -> [UInt8] {
        idBytes(id) + (unknown ? unknownSize() : sizeBytes(payload.count, width: sizeWidth)) + payload
    }

    static func uint(_ v: Int, width: Int? = nil) -> [UInt8] {
        var out: [UInt8] = []
        var x = v
        repeat { out.insert(UInt8(x & 0xFF), at: 0); x >>= 8 } while x > 0
        if let w = width { while out.count < w { out.insert(0, at: 0) } }
        return out
    }

    struct WebMOptions {
        var packetsPerCluster = 50
        var unknownSegment = false
        var unknownClusters = false
        var cues = true
        var cuesAtEnd = false
        var blockGroups = false
        var lacing = 0          // 0 none, 1 Xiph, 2 fixed, 3 EBML (laces pairs of packets; fixed needs equal sizes)
        var head = MusicOpusHead(channels: 2, preSkip: 312, inputRate: 48_000, outputGainQ8: 0, mappingFamily: 0)
        var withVideoTrack = false
        var codec = "A_OPUS"
    }

    static func webm(packets: [[UInt8]], frameMs: Int = 20, _ o: WebMOptions = WebMOptions()) -> [UInt8] {
        let ebmlHeader = el(0x1A45DFA3, el(0x4282, Array("webm".utf8)))
        let info = el(0x1549A966, el(0x2AD7B1, uint(1_000_000)) + el(0x4489, floatBytes(Double(packets.count * frameMs))))
        var tracks = el(0xAE, el(0xD7, [1]) + el(0x83, [2]) + el(0x86, Array(o.codec.utf8)) + el(0x63A2, o.head.bytes()) + el(0xE1, el(0x9F, [UInt8(o.head.channels)])))
        if o.withVideoTrack { tracks = el(0xAE, el(0xD7, [2]) + el(0x83, [1]) + el(0x86, Array("V_VP9".utf8))) + tracks }
        let tracksEl = el(0x1654AE6B, tracks)

        // Clusters
        var clusters: [[UInt8]] = []
        var clusterTimes: [Int] = []
        var i = 0
        while i < packets.count {
            let n = min(o.packetsPerCluster, packets.count - i)
            let t0 = i * frameMs
            var body = el(0xE7, uint(t0))
            if o.withVideoTrack { body += el(0xA3, [0x82, 0, 0, 0x80, 1, 2, 3]) }
            var k = 0
            while k < n {
                let rel = k * frameMs
                if o.lacing != 0, k + 1 < n {
                    let a = packets[i + k], b = packets[i + k + 1]
                    body += el(0xA3, [0x81, UInt8(rel >> 8), UInt8(rel & 0xFF), UInt8(o.lacing << 1)] + laced([a, b], mode: o.lacing))
                    k += 2
                } else if o.blockGroups {
                    var g = el(0xA1, [0x81, UInt8(rel >> 8), UInt8(rel & 0xFF), 0] + packets[i + k]) + el(0x9B, uint(frameMs))
                    if i + k == packets.count - 1 { g += el(0x75A2, [0x03, 0xA4, 0x4F]) } // 240 000 ns of end padding
                    body += el(0xA0, g)
                    k += 1
                } else {
                    body += el(0xA3, [0x81, UInt8(rel >> 8), UInt8(rel & 0xFF), 0x80] + packets[i + k])
                    k += 1
                }
            }
            clusters.append(el(0x1F43B675, body, unknown: o.unknownClusters))
            clusterTimes.append(t0)
            i += n
        }

        func cuesEl(base: Int) -> [UInt8] {
            var pos = base
            var points: [UInt8] = []
            for (n, c) in clusters.enumerated() {
                points += el(0xBB, el(0xB3, uint(clusterTimes[n])) + el(0xB7, el(0xF7, [1]) + el(0xF1, uint(pos, width: 4))))
                pos += c.count
            }
            return el(0x1C53BB6B, points)
        }
        let cuesLen = o.cues ? cuesEl(base: 0).count : 0
        let seekHeadFixed = el(0x114D9B74, el(0x4DBB, el(0x53AB, [0x1C, 0x53, 0xBB, 0x6B]) + el(0x53AC, uint(0, width: 4))))
        let seekHeadLen = o.cuesAtEnd ? seekHeadFixed.count : 0
        var segment: [UInt8] = []
        if o.cuesAtEnd {
            let cuesPos = seekHeadLen + info.count + tracksEl.count + clusters.reduce(0) { $0 + $1.count }
            segment += el(0x114D9B74, el(0x4DBB, el(0x53AB, [0x1C, 0x53, 0xBB, 0x6B]) + el(0x53AC, uint(cuesPos, width: 4))))
            segment += info + tracksEl
            let first = segment.count
            segment += clusters.flatMap { $0 }
            if o.cues { segment += cuesEl(base: first) }
        } else {
            segment += info + tracksEl
            let first = segment.count + cuesLen
            if o.cues { segment += cuesEl(base: first) }
            segment += clusters.flatMap { $0 }
        }
        return ebmlHeader + el(0x18538067, segment, unknown: o.unknownSegment)
    }

    static func floatBytes(_ d: Double) -> [UInt8] {
        let b = d.bitPattern
        return (0..<8).reversed().map { UInt8((b >> UInt64(8 * $0)) & 0xFF) }
    }

    static func laced(_ frames: [[UInt8]], mode: Int) -> [UInt8] {
        var out: [UInt8] = [UInt8(frames.count - 1)]
        switch mode {
        case 1:
            for f in frames.dropLast() {
                var n = f.count
                while n >= 255 { out.append(255); n -= 255 }
                out.append(UInt8(n))
            }
        case 3:
            out += sizeBytes(frames[0].count, width: 2)
            for k in 1..<max(1, frames.count - 1) {
                let d = frames[k].count - frames[k - 1].count
                // signed vint, two bytes: bias 2^13 - 1
                let raw = d + ((1 << 13) - 1)
                out += [UInt8(0x40 | (raw >> 8)), UInt8(raw & 0xFF)]
            }
        default: break
        }
        return out + frames.flatMap { $0 }
    }

    // Ogg writing
    static func oggCRCless(page flags: UInt8, granule: Int64, serial: UInt32, seq: UInt32, segments: [UInt8], body: [UInt8]) -> [UInt8] {
        var p = Array("OggS".utf8) + [0, flags]
        for i in 0..<8 { p.append(UInt8((UInt64(bitPattern: granule) >> UInt64(8 * i)) & 0xFF)) }
        for i in 0..<4 { p.append(UInt8((serial >> UInt32(8 * i)) & 0xFF)) }
        for i in 0..<4 { p.append(UInt8((seq >> UInt32(8 * i)) & 0xFF)) }
        p += [0, 0, 0, 0] // the demuxer does not check the checksum
        p.append(UInt8(segments.count))
        return p + segments + body
    }

    static func lacingValues(_ packetSize: Int) -> [UInt8] {
        var v = [UInt8](repeating: 255, count: packetSize / 255)
        v.append(UInt8(packetSize % 255))
        return v
    }

    static func ogg(packets: [[UInt8]], perPage: Int = 25, head: MusicOpusHead = MusicOpusHead(channels: 2, preSkip: 312, inputRate: 48_000, outputGainQ8: 0, mappingFamily: 0),
                    trimEnd: Int = 0, serial: UInt32 = 0xBEEF) -> [UInt8] {
        var out: [UInt8] = []
        var seq: UInt32 = 0
        let h = head.bytes()
        out += oggCRCless(page: 2, granule: 0, serial: serial, seq: seq, segments: lacingValues(h.count), body: h); seq += 1
        let tags = Array("OpusTags".utf8) + [4, 0, 0, 0] + Array("test".utf8) + [0, 0, 0, 0]
        out += oggCRCless(page: 0, granule: 0, serial: serial, seq: seq, segments: lacingValues(tags.count), body: tags); seq += 1
        var i = 0
        var samples: Int64 = 0
        while i < packets.count {
            let chunk = Array(packets[i..<min(packets.count, i + perPage)])
            var segs: [UInt8] = [], body: [UInt8] = []
            for p in chunk { segs += lacingValues(p.count); body += p; samples += Int64(MusicOpusTOC.samples(in: p) ?? 960) }
            i += chunk.count
            let last = i >= packets.count
            // 255 segments per page at most; the fixtures stay below that.
            out += oggCRCless(page: last ? 4 : 0, granule: last ? samples - Int64(trimEnd) : samples, serial: serial, seq: seq, segments: segs, body: body); seq += 1
        }
        return out
    }

    // Tone encoding with the system Opus encoder
    static func tonePackets(seconds: Double, frequency: Double = 440, channels: Int = 2, amplitude: Float = 0.5) -> [[UInt8]] {
        let frames = Int(seconds * 48_000)
        guard let of = MusicOpusDecoder.format(channels: channels, framesPerPacket: 960) else { return [] }
        let pcm = MusicOpusDecoder.pcmFormat(channels: channels)
        guard let enc = AVAudioConverter(from: pcm, to: of), let buf = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(frames)) else { return [] }
        buf.frameLength = AVAudioFrameCount(frames)
        for c in 0..<channels { for i in 0..<frames { buf.floatChannelData?[c][i] = amplitude * Float(sin(2 * Double.pi * frequency * Double(i) / 48_000)) } }
        let out = AVAudioCompressedBuffer(format: of, packetCapacity: 16, maximumPacketSize: enc.maximumOutputPacketSize)
        var given = false
        var packets: [[UInt8]] = []
        while true {
            var err: NSError?
            let st = enc.convert(to: out, error: &err) { _, s in
                if given { s.pointee = .endOfStream; return nil }
                given = true; s.pointee = .haveData; return buf
            }
            if st == .error { break }
            for i in 0..<Int(out.packetCount) {
                guard let d = out.packetDescriptions?[i] else { continue }
                let p = UnsafeBufferPointer(start: out.data.advanced(by: Int(d.mStartOffset)).assumingMemoryBound(to: UInt8.self), count: Int(d.mDataByteSize))
                packets.append(Array(p))
            }
            if st == .endOfStream || st == .inputRanDry { break }
        }
        return packets
    }

    /// Fake packets with a valid TOC (20 ms CELT) for container tests that never decode.
    static func fakePackets(_ n: Int, size: Int = 40) -> [[UInt8]] {
        (0..<n).map { i in [0xFC] + [UInt8](repeating: UInt8(i & 0xFF), count: size + (i % 7)) }
    }

    static func feedAll(_ d: inout MusicWebMDemuxer, _ bytes: [UInt8], chunk: Int) throws -> [MusicOpusEvent] {
        var ev: [MusicOpusEvent] = []
        var i = 0
        while i < bytes.count { ev += try d.feed(Array(bytes[i..<min(bytes.count, i + chunk)])); i += chunk }
        return ev
    }

    static func packets(_ ev: [MusicOpusEvent]) -> [MusicOpusPacket] { ev.compactMap { if case .packet(let p) = $0 { p } else { nil } } }

    static func goertzel(_ x: UnsafePointer<Float>, count: Int, freq: Double) -> Double {
        let w = 2 * Double.pi * freq / 48_000
        let c = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for i in 0..<count { let s = Double(x[i]) + c * s1 - s2; s2 = s1; s1 = s }
        return (s1 * s1 + s2 * s2 - c * s1 * s2) / Double(count * count)
    }
}

// MARK: tests

@Suite("Opus container parsing")
struct OpusContainerTests {
    @Test func variableLengthIntegers() {
        #expect(MusicWebMDemuxer.readVint([0x81], 0, keepMarker: false)?.0 == 1)
        #expect(MusicWebMDemuxer.readVint([0x40, 0x02], 0, keepMarker: false)?.0 == 2)
        #expect(MusicWebMDemuxer.readVint([0x10, 0x00, 0x00, 0x01], 0, keepMarker: false)?.0 == 1)
        #expect(MusicWebMDemuxer.readVint([0x01, 0, 0, 0, 0, 0, 0, 0x2A], 0, keepMarker: false)?.0 == 42)
        #expect(MusicWebMDemuxer.readVint([0x40], 0, keepMarker: false) == nil)
        #expect(MusicWebMDemuxer.readVint([0x00], 0, keepMarker: false) == nil)
        let (id, n) = MusicWebMDemuxer.readID([0x1A, 0x45, 0xDF, 0xA3], 0) ?? (0, 0)
        #expect(id == 0x1A45DFA3 && n == 4)
        #expect(MusicWebMDemuxer.unknownSize(length: 1) == 0x7F)
        #expect(MusicWebMDemuxer.unknownSize(length: 8) == (Int64(1) << 56) - 1)
        #expect(MusicWebMDemuxer.sint([0xFF]) == -1)
        #expect(MusicWebMDemuxer.sint([0xFF, 0xFE]) == -2)
        #expect(MusicWebMDemuxer.float([0x40, 0x59, 0, 0, 0, 0, 0, 0]) == 100)
        #expect(MusicWebMDemuxer.float([0x42, 0xC8, 0, 0]) == 100)
    }

    @Test func packetLengthsFollowTheTOC() {
        #expect(MusicOpusTOC.samples(in: [0xFC]) == 960)          // CELT 20 ms
        #expect(MusicOpusTOC.samples(in: [0xE0]) == 120)          // CELT 2.5 ms
        #expect(MusicOpusTOC.samples(in: [0x00]) == 480)          // SILK 10 ms
        #expect(MusicOpusTOC.samples(in: [0x18]) == 2880)         // SILK 60 ms
        #expect(MusicOpusTOC.samples(in: [0x69]) == 1920)         // hybrid 20 ms, two frames
        #expect(MusicOpusTOC.samples(in: [0xFB, 3]) == 2880)      // CELT 20 ms, code 3, three frames
        #expect(MusicOpusTOC.samples(in: [0xFB, 0]) == nil)
        #expect(MusicOpusTOC.samples(in: []) == nil)
    }

    @Test func headParsingAndGain() throws {
        let h = MusicOpusHead(channels: 2, preSkip: 312, inputRate: 44_100, outputGainQ8: -512, mappingFamily: 0)
        let back = try #require(MusicOpusHead.parse(h.bytes()))
        #expect(back == h)
        #expect(abs(back.gainLinear - 0.7943) < 0.001)   // -2 dB
        #expect(MusicOpusHead.parse(Array("OpusHeaX".utf8) + [UInt8](repeating: 0, count: 12)) == nil)
        #expect(MusicOpusHead.parse([1, 2, 3]) == nil)
        let fb = MusicOpusHead.fallback(channels: 1, codecDelayNs: 6_500_000)
        #expect(fb.preSkip == 312 && fb.channels == 1)
    }

    @Test func containersAreRecognisedByBytesAndMime() {
        #expect(MusicMediaContainer.sniff([0x1A, 0x45, 0xDF, 0xA3, 1]) == .webm)
        #expect(MusicMediaContainer.sniff(Array("OggS".utf8)) == .ogg)
        #expect(MusicMediaContainer.sniff([0, 0, 0, 0x20] + Array("ftypM4A ".utf8)) == .mp4)
        #expect(MusicMediaContainer.sniff(Array("ID3".utf8)) == .other)
        #expect(MusicMediaContainer.from(mime: "audio/webm; codecs=opus") == .webm)
        #expect(MusicMediaContainer.from(mime: "audio/ogg") == .ogg)
        #expect(MusicMediaContainer.from(mime: "text/html") == nil)
        let weird = MusicStream(url: "https://h/videoplayback?itag=251", codec: "opus", container: "")
        #expect(MusicOpusRouting.needsSniff(weird))
        #expect(MusicOpusRouting.declaresOpusContainer(MusicStream(url: "https://h/a", codec: "opus", container: "webm")))
        #expect(MusicOpusRouting.declaresOpusContainer(MusicStream(url: "https://h/a.opus", codec: "opus", container: "")))
        #expect(!MusicOpusRouting.declaresOpusContainer(MusicStream(url: "https://h/a", codec: "aac", container: "m4a")))
    }

    @Test(arguments: [1, 7, 4096, 1 << 20])
    func webmPacketsComeOutWhateverTheChunking(chunk: Int) throws {
        let packets = OpusFixtures.fakePackets(120)
        let bytes = OpusFixtures.webm(packets: packets)
        var d = MusicWebMDemuxer()
        let ev = try OpusFixtures.feedAll(&d, bytes, chunk: chunk)
        let got = OpusFixtures.packets(ev)
        #expect(got.count == 120)
        #expect(got.map(\.data) == packets)
        #expect(abs(got[99].time - 1.98) < 1e-9)
        #expect(got.allSatisfy { $0.samples == 960 })
        let info = try #require(d.trackInfo)
        #expect(info.head.preSkip == 312 && info.head.channels == 2)
        #expect(abs((info.duration ?? 0) - 2.4) < 1e-6)
        #expect(d.cues.count == 3)
        #expect(d.opusTrack == 1)
    }

    @Test func unknownSizeSegmentAndClustersAreSplitAtTheNextCluster() throws {
        var o = OpusFixtures.WebMOptions()
        o.unknownSegment = true; o.unknownClusters = true; o.packetsPerCluster = 30
        let packets = OpusFixtures.fakePackets(100)
        var d = MusicWebMDemuxer()
        let ev = try OpusFixtures.feedAll(&d, OpusFixtures.webm(packets: packets, o), chunk: 13)
        #expect(OpusFixtures.packets(ev).map(\.data) == packets)
        #expect(abs(OpusFixtures.packets(ev)[31].time - 0.62) < 1e-9)
    }

    @Test func blockGroupsCarryTheEndPadding() throws {
        var o = OpusFixtures.WebMOptions()
        o.blockGroups = true; o.cues = false
        let packets = OpusFixtures.fakePackets(10)
        var d = MusicWebMDemuxer()
        let got = OpusFixtures.packets(try OpusFixtures.feedAll(&d, OpusFixtures.webm(packets: packets, o), chunk: 100))
        #expect(got.count == 10)
        #expect(got.last?.discardEnd == 11)   // 240 000 ns at 48 kHz
        #expect(got.first?.discardEnd == 0)
    }

    @Test(arguments: [1, 2, 3])
    func lacedBlocksAreSplit(mode: Int) throws {
        var o = OpusFixtures.WebMOptions()
        o.lacing = mode; o.cues = false
        // Fixed lacing needs equal frame sizes.
        let packets: [[UInt8]] = mode == 2 ? (0..<20).map { _ in [0xFC] + [UInt8](repeating: 7, count: 50) } : OpusFixtures.fakePackets(20, size: 300)
        var d = MusicWebMDemuxer()
        let got = OpusFixtures.packets(try OpusFixtures.feedAll(&d, OpusFixtures.webm(packets: packets, o), chunk: 64))
        #expect(got.map(\.data) == packets)
        // The second frame of a laced pair is placed one packet length after the first.
        #expect(abs(got[1].time - 0.02) < 1e-9)
    }

    @Test func lacingAcceptsThreeFrames() throws {
        let frames: [[UInt8]] = [[1, 2, 3], [4, 5], [6, 7, 8, 9]]
        #expect(try MusicWebMDemuxer.unlace(OpusFixtures.laced(frames, mode: 1), mode: 1) == frames)
        #expect(try MusicWebMDemuxer.unlace(OpusFixtures.laced(frames, mode: 3), mode: 3) == frames)
        let equal: [[UInt8]] = [[1, 2], [3, 4], [5, 6]]
        #expect(try MusicWebMDemuxer.unlace(OpusFixtures.laced(equal, mode: 2), mode: 2) == equal)
        #expect(throws: MusicOpusError.self) { try MusicWebMDemuxer.unlace([2, 5, 5, 5, 5], mode: 2) }
    }

    @Test func nonOpusTracksAreReportedAndVideoIsSkipped() throws {
        var o = OpusFixtures.WebMOptions()
        o.codec = "A_VORBIS"; o.cues = false
        var d = MusicWebMDemuxer()
        _ = try OpusFixtures.feedAll(&d, OpusFixtures.webm(packets: OpusFixtures.fakePackets(3), o), chunk: 4096)
        #expect(d.trackInfo == nil)
        #expect(d.unsupportedReason == "VORBIS")

        var v = OpusFixtures.WebMOptions()
        v.withVideoTrack = true; v.cues = false
        var d2 = MusicWebMDemuxer()
        let got = OpusFixtures.packets(try OpusFixtures.feedAll(&d2, OpusFixtures.webm(packets: OpusFixtures.fakePackets(5), v), chunk: 4096))
        #expect(got.count == 5)
    }

    @Test func cuesAndSeekHeadAreRead() throws {
        var o = OpusFixtures.WebMOptions()
        o.cuesAtEnd = true
        let packets = OpusFixtures.fakePackets(150)
        let bytes = OpusFixtures.webm(packets: packets, o)
        var d = MusicWebMDemuxer()
        _ = try OpusFixtures.feedAll(&d, bytes, chunk: 1000)
        #expect(d.cues.count == 3)
        #expect(d.cuesPosition != nil)
        let c = try #require(MusicWebMDemuxer.cue(for: 1.4, in: d.cues))
        #expect(c.time == 1.0)
        #expect(MusicWebMDemuxer.cue(for: 0, in: d.cues)?.time == 0)
        #expect(MusicWebMDemuxer.cue(for: 99, in: d.cues)?.time == 2.0)
        // The cue position leads to the cluster: restart there and the first packet is that cluster's first.
        var r = d
        let seg = try #require(d.segmentDataStart)
        r.restart(atOffset: seg + c.position, clusterAligned: true)
        let got = OpusFixtures.packets(try r.feed(Array(bytes[Int(seg + c.position)...])))
        #expect(got.first?.data == packets[50])
        #expect(got.first.map { abs($0.time - 1.0) < 1e-9 } == true)
    }

    @Test func scanningFindsTheNextClusterAfterAGuess() throws {
        var o = OpusFixtures.WebMOptions()
        o.cues = false
        let packets = OpusFixtures.fakePackets(150)
        let bytes = OpusFixtures.webm(packets: packets, o)
        var d = MusicWebMDemuxer()
        _ = try OpusFixtures.feedAll(&d, bytes, chunk: 4096)
        var r = d
        let guess = bytes.count / 2 + 3
        r.restart(atOffset: Int64(guess), clusterAligned: false)
        let got = OpusFixtures.packets(try OpusFixtures.feedAll(&r, Array(bytes[guess...]), chunk: 500))
        #expect(!got.isEmpty)
        let first = try #require(got.first)
        #expect(first.time >= 1.0 - 1e-9 && packets.contains(first.data))
    }

    @Test func oggPacketsSpanPagesAndKeepTheirTimes() throws {
        // Packets over 255 bytes use several lacing values; one page boundary falls inside the list.
        var packets = OpusFixtures.fakePackets(60, size: 700)
        packets[10] = [0xFC] + [UInt8](repeating: 9, count: 254)   // exactly 255 bytes: ends with a zero lacing value
        let bytes = OpusFixtures.ogg(packets: packets, perPage: 7)
        for chunk in [1, 33, 100_000] {
            var d = MusicOggOpusDemuxer()
            var ev: [MusicOpusEvent] = []
            var i = 0
            while i < bytes.count { ev += try d.feed(Array(bytes[i..<min(bytes.count, i + chunk)])); i += chunk }
            let got = OpusFixtures.packets(ev)
            #expect(got.map(\.data) == packets)
            #expect(abs(got[30].time - 0.6) < 1e-9)
            #expect(d.trackInfo?.head.preSkip == 312)
        }
    }

    @Test func oggEndPageTrimsTheLastPacket() throws {
        let packets = OpusFixtures.fakePackets(10)
        let bytes = OpusFixtures.ogg(packets: packets, perPage: 4, trimEnd: 100)
        var d = MusicOggOpusDemuxer()
        let got = OpusFixtures.packets(try d.feed(bytes))
        #expect(got.count == 10)
        #expect(got.last?.discardEnd == 100)
        let g = try #require(MusicOggOpusDemuxer.lastGranule(in: bytes))
        #expect(g == 10 * 960 - 100)
        #expect(abs(MusicOggOpusDemuxer.duration(lastGranule: g, preSkip: 312) - Double(9600 - 100 - 312) / 48_000) < 1e-9)
    }

    @Test func oggRejectsOtherData() {
        var d = MusicOggOpusDemuxer()
        #expect(throws: MusicOpusError.self) { _ = try d.feed(Array("this is not an ogg file at all".utf8)) }
        let vorbis = OpusFixtures.oggCRCless(page: 2, granule: 0, serial: 1, seq: 0, segments: [30], body: [1] + Array("vorbis".utf8) + [UInt8](repeating: 0, count: 23))
        var v = MusicOggOpusDemuxer()
        #expect(throws: MusicOpusError.unsupported("Vorbis")) { _ = try v.feed(vorbis) }
    }
}

@Suite("Opus decoding and playback plumbing")
struct OpusDecodingTests {
    private func decodeAll(_ pipeline: MusicOpusPipeline, head: MusicOpusHead, opened: Bool = false) async throws -> (samples: [[Float]], firstTime: Double?) {
        if !opened { _ = try await pipeline.open() }
        let dec = try MusicOpusDecoder(head: head)
        var out = [[Float]](repeating: [], count: head.channels)
        var firstTime: Double?
        while let pk = try await pipeline.nextPackets() {
            for p in pk {
                if firstTime == nil { firstTime = p.time }
                guard let b = try dec.decode(p), let ch = b.floatChannelData else { continue }
                for c in 0..<head.channels { out[c] += Array(UnsafeBufferPointer(start: ch[c], count: Int(b.frameLength))) }
            }
        }
        return (out, firstTime)
    }

    @Test func systemDecoderRoundTripsATone() async throws {
        guard MusicOpusDecoder.isAvailable else { return }
        let packets = OpusFixtures.tonePackets(seconds: 1)
        try #require(packets.count >= 50)
        let bytes = OpusFixtures.webm(packets: packets)
        let pipeline = MusicOpusPipeline(source: MusicOpusMemorySource(bytes: bytes))
        let info = try await pipeline.open()
        let (pcm, _) = try await decodeAll(pipeline, head: info.head, opened: true)
        let n = pcm[0].count
        // 51 packets of 960, less the 312-sample pre-skip.
        #expect(abs(n - (packets.count * 960 - 312)) <= 2)
        let mid = Array(pcm[0][12_000..<36_000])
        let peak = mid.map { abs($0) }.max() ?? 0
        #expect(peak > 0.4 && peak < 0.62)
        let at440 = mid.withUnsafeBufferPointer { OpusFixtures.goertzel($0.baseAddress!, count: $0.count, freq: 440) }
        let at1000 = mid.withUnsafeBufferPointer { OpusFixtures.goertzel($0.baseAddress!, count: $0.count, freq: 1000) }
        #expect(at440 > at1000 * 1000)
        // The two channels carry the same tone.
        let diff = zip(pcm[0][12_000..<12_100], pcm[1][12_000..<12_100]).map { abs($0 - $1) }.max() ?? 1
        #expect(diff < 0.05)
    }

    @Test func outputGainScalesTheSamples() async throws {
        guard MusicOpusDecoder.isAvailable else { return }
        let packets = OpusFixtures.tonePackets(seconds: 0.5)
        var h = MusicOpusHead(channels: 2, preSkip: 312, inputRate: 48_000, outputGainQ8: 0, mappingFamily: 0)
        let a = try await decodeAll(MusicOpusPipeline(source: MusicOpusMemorySource(bytes: OpusFixtures.ogg(packets: packets, head: h))), head: h)
        h.outputGainQ8 = -1536 // -6 dB
        let b = try await decodeAll(MusicOpusPipeline(source: MusicOpusMemorySource(bytes: OpusFixtures.ogg(packets: packets, head: h))), head: h)
        let pa = a.samples[0][5000..<20000].map { abs($0) }.max() ?? 0
        let pb = b.samples[0][5000..<20000].map { abs($0) }.max() ?? 0
        #expect(abs(pb / pa - 0.5012) < 0.02)
    }

    @Test func monoStreamsDecodeToOneChannel() async throws {
        guard MusicOpusDecoder.isAvailable else { return }
        let packets = OpusFixtures.tonePackets(seconds: 0.5, channels: 1)
        let h = MusicOpusHead(channels: 1, preSkip: 312, inputRate: 48_000, outputGainQ8: 0, mappingFamily: 0)
        var o = OpusFixtures.WebMOptions(); o.head = h
        let pipeline = MusicOpusPipeline(source: MusicOpusMemorySource(bytes: OpusFixtures.webm(packets: packets, o)))
        let info = try await pipeline.open()
        #expect(info.head.channels == 1)
        let r = try await decodeAll(pipeline, head: info.head, opened: true)
        #expect(r.samples.count == 1 && r.samples[0].count > 20_000)
    }

    @Test func aLostPacketIsConcealedWithTheDecoderItself() async throws {
        guard MusicOpusDecoder.isAvailable else { return }
        let packets = OpusFixtures.tonePackets(seconds: 0.5)
        let dec = try MusicOpusDecoder(head: MusicOpusHead(channels: 2, preSkip: 0, inputRate: 48_000, outputGainQ8: 0, mappingFamily: 0))
        for (i, p) in packets.prefix(10).enumerated() { _ = try dec.decode(MusicOpusPacket(data: p, time: Double(i) * 0.02, samples: 960)) }
        let filled = try #require(try dec.conceal(samples: 960))
        #expect(filled.frameLength == 960)
        let energy = (0..<960).reduce(Float(0)) { $0 + abs(filled.floatChannelData?[0][$1] ?? 0) }
        #expect(energy > 1)
    }

    @Test func aDamagedPacketNeverCrashesTheDecoder() throws {
        guard MusicOpusDecoder.isAvailable else { return }
        let dec = try MusicOpusDecoder(head: MusicOpusHead(channels: 2, preSkip: 0, inputRate: 48_000, outputGainQ8: 0, mappingFamily: 0))
        for junk: [UInt8] in [[0xFF, 0xFF, 0xFF], [0xFC], [0xFB, 0x3F, 1, 2, 3], [UInt8](repeating: 0xAA, count: 300)] {
            _ = try? dec.decode(MusicOpusPacket(data: junk, time: 0, samples: 960))
        }
        #expect(try dec.conceal(samples: 960)?.frameLength == 960)
    }

    @Test func surroundOpusFailsGracefully() {
        #expect(throws: MusicOpusError.self) {
            _ = try MusicOpusDecoder(head: MusicOpusHead(channels: 6, preSkip: 0, inputRate: 48_000, outputGainQ8: 0, mappingFamily: 1))
        }
    }

    @Test func webmSeekUsesTheCues() async throws {
        let packets = OpusFixtures.fakePackets(200)
        let pipeline = MusicOpusPipeline(source: MusicOpusMemorySource(bytes: OpusFixtures.webm(packets: packets)))
        _ = try await pipeline.open()
        try await pipeline.seek(to: 2.5)
        let first = try #require(try await pipeline.nextPackets()?.first)
        #expect(abs(first.time - 2.0) < 1e-9)       // the cluster that holds 2.5 s starts at 2.0 s
        try await pipeline.seek(to: 0)
        #expect(try await pipeline.nextPackets()?.first?.data == packets[0])
    }

    @Test func webmSeekFindsCuesAtTheEndOfTheFile() async throws {
        var o = OpusFixtures.WebMOptions(); o.cuesAtEnd = true
        let packets = OpusFixtures.fakePackets(200)
        let pipeline = MusicOpusPipeline(source: MusicOpusMemorySource(bytes: OpusFixtures.webm(packets: packets, o)))
        _ = try await pipeline.open()
        try await pipeline.seek(to: 3.9)
        let first = try #require(try await pipeline.nextPackets()?.first)
        #expect(abs(first.time - 3.0) < 1e-9)
    }

    @Test func webmSeekWithoutCuesEstimatesThenScans() async throws {
        var o = OpusFixtures.WebMOptions(); o.cues = false
        let packets = OpusFixtures.fakePackets(400)
        let pipeline = MusicOpusPipeline(source: MusicOpusMemorySource(bytes: OpusFixtures.webm(packets: packets, o)))
        _ = try await pipeline.open()
        try await pipeline.seek(to: 4.0)
        let first = try #require(try await pipeline.nextPackets()?.first)
        #expect(first.time >= 2.0 && first.time <= 6.0)
    }

    @Test func oggSeekLandsBeforeTheTarget() async throws {
        let packets = OpusFixtures.fakePackets(500, size: 60)
        let pipeline = MusicOpusPipeline(source: MusicOpusMemorySource(bytes: OpusFixtures.ogg(packets: packets, perPage: 10)))
        let info = try await pipeline.open()
        #expect(abs((info.duration ?? 0) - Double(500 * 960 - 312) / 48_000) < 1e-6)
        try await pipeline.seek(to: 6.0)
        let first = try #require(try await pipeline.nextPackets()?.first)
        #expect(first.time <= 6.0 + 1e-9 && first.time > 5.0)
    }

    @Test func openingAnUnknownFileFails() async {
        let pipeline = MusicOpusPipeline(source: MusicOpusMemorySource(bytes: Array("RIFF....WAVEfmt ".utf8)))
        await #expect(throws: MusicOpusError.self) { _ = try await pipeline.open() }
        let vorbis = MusicOpusPipeline(source: MusicOpusMemorySource(bytes: OpusFixtures.webm(packets: OpusFixtures.fakePackets(3), {
            var o = OpusFixtures.WebMOptions(); o.codec = "A_VORBIS"; o.cues = false; return o }())))
        await #expect(throws: MusicOpusError.unsupported("VORBIS")) { _ = try await vorbis.open() }
    }

    @Test func ringKeepsTimeByFramesPlayedAndStandsStillWhenStarved() throws {
        let ring = MusicOpusRing(seconds: 1)
        ring.configure(channels: 2)
        ring.flush(base: 10)
        ring.setPlaying(true)
        let fmt = MusicOpusDecoder.pcmFormat(channels: 2)
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4800))
        buf.frameLength = 4800
        for i in 0..<4800 { buf.floatChannelData?[0][i] = Float(i); buf.floatChannelData?[1][i] = -Float(i) }
        #expect(ring.write(buf))
        var l = [Float](repeating: 9, count: 6000), r = [Float](repeating: 9, count: 6000)
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            let abl = AudioBufferList.allocate(maximumBuffers: 2)
            defer { free(abl.unsafeMutablePointer) }
            abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 6000 * 4, mData: lp.baseAddress)
            abl[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 6000 * 4, mData: rp.baseAddress)
            ring.render(frames: 6000, buffers: abl)
        } }
        #expect(l[4799] == 4799 && l[4800] == 0 && r[100] == -100)
        #expect(abs(ring.position - (10 + 0.1)) < 1e-9)     // only the 4800 real frames count
        #expect(ring.isStarving)
        ring.markEnd()
        #expect(ring.isDrained)
        ring.flush(base: 3)
        #expect(ring.position == 3 && ring.bufferedFrames == 0)
    }

    @Test func ringRefusesWritesThatDoNotFit() throws {
        let ring = MusicOpusRing(seconds: 0.1)   // 4800 frames
        let fmt = MusicOpusDecoder.pcmFormat(channels: 2)
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 3000))
        buf.frameLength = 3000
        #expect(ring.write(buf))
        #expect(!ring.write(buf))
        #expect(ring.freeFrames == 1800)
    }
}

@Suite("Opus stream choice")
struct OpusStreamChoiceTests {
    @MainActor @Test func aacBeatsOpusAndOpusIsUsedWhenAlone() {
        let webm = MusicStream(url: "https://a/x", codec: "opus", container: "webm", bitrate: 160)
        let m4a = MusicStream(url: "https://a/y", codec: "aac", container: "m4a", bitrate: 128)
        let low = MusicStream(url: "https://a/z", codec: "aac", container: "m4a", bitrate: 48)
        #expect(MusicStreamResolver.pick(from: [webm, m4a], quality: .high, opusAvailable: true) == m4a)
        #expect(MusicStreamResolver.pick(from: [webm, low], quality: .high, opusAvailable: true) == low)
        #expect(MusicStreamResolver.pick(from: [webm], quality: .high, opusAvailable: true) == webm)
        #expect(MusicStreamResolver.pick(from: [webm], quality: .high, opusAvailable: false) == nil)
        #expect(MusicStreamResolver.pick(from: [webm, m4a], quality: .high, opusAvailable: false) == m4a)
    }

    @MainActor @Test func vorbisIsNeverPlayable() {
        #expect(!MusicStreamResolver.isPlayable(container: "ogg", codec: "vorbis", opusAvailable: true))
        #expect(!MusicStreamResolver.isPlayable(container: "webm", codec: "vorbis", opusAvailable: true))
        #expect(MusicStreamResolver.isPlayable(container: "ogg", codec: "opus", opusAvailable: true))
        #expect(!MusicStreamResolver.isPlayable(container: "ogg", codec: "opus", opusAvailable: false))
        #expect(MusicStreamResolver.isPlayable(container: "mp3", codec: "mp3", opusAvailable: false))
    }
}
