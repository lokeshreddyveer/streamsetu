import Foundation

/// A streaming demuxer for Opus audio in WebM and Matroska (EBML). Bytes are fed as they arrive, in any chunking; packets come out as soon as
/// they are complete. It reads the Segment, the Opus track (CodecID A_OPUS and its OpusHead), Clusters with SimpleBlock and BlockGroup
/// (all three lacing modes, unknown-size clusters), the Cues and the SeekHead. Other tracks (video, subtitles) are skipped.
struct MusicWebMDemuxer: Sendable {
    // Element ids (the marker bits are part of the id).
    private enum ID {
        static let ebml: UInt32 = 0x1A45DFA3, segment: UInt32 = 0x18538067, seekHead: UInt32 = 0x114D9B74, seek: UInt32 = 0x4DBB
        static let seekID: UInt32 = 0x53AB, seekPosition: UInt32 = 0x53AC
        static let info: UInt32 = 0x1549A966, timecodeScale: UInt32 = 0x2AD7B1, duration: UInt32 = 0x4489
        static let tracks: UInt32 = 0x1654AE6B, trackEntry: UInt32 = 0xAE, trackNumber: UInt32 = 0xD7, trackType: UInt32 = 0x83
        static let codecID: UInt32 = 0x86, codecPrivate: UInt32 = 0x63A2, codecDelay: UInt32 = 0x56AA, audio: UInt32 = 0xE1, channels: UInt32 = 0x9F
        static let cluster: UInt32 = 0x1F43B675, timecode: UInt32 = 0xE7, simpleBlock: UInt32 = 0xA3, blockGroup: UInt32 = 0xA0
        static let block: UInt32 = 0xA1, discardPadding: UInt32 = 0x75A2
        static let cues: UInt32 = 0x1C53BB6B, cuePoint: UInt32 = 0xBB, cueTime: UInt32 = 0xB3, cueTrackPositions: UInt32 = 0xB7
        static let cueTrack: UInt32 = 0xF7, cueClusterPosition: UInt32 = 0xF1
        static let tags: UInt32 = 0x1254C367, chapters: UInt32 = 0x1043A770, attachments: UInt32 = 0x1941A469
    }

    private static let masters: Set<UInt32> = [ID.segment, ID.seekHead, ID.seek, ID.info, ID.tracks, ID.trackEntry, ID.audio, ID.cluster,
                                               ID.blockGroup, ID.cues, ID.cuePoint, ID.cueTrackPositions]
    private static let leaves: Set<UInt32> = [ID.seekID, ID.seekPosition, ID.timecodeScale, ID.duration, ID.trackNumber, ID.trackType, ID.codecID,
                                              ID.codecPrivate, ID.codecDelay, ID.channels, ID.timecode, ID.simpleBlock, ID.block, ID.discardPadding,
                                              ID.cueTime, ID.cueTrack, ID.cueClusterPosition]
    /// Elements that sit directly under the segment: meeting one ends an open cluster of unknown size.
    private static let levelOne: Set<UInt32> = [ID.cluster, ID.cues, ID.tags, ID.seekHead, ID.info, ID.tracks, ID.chapters, ID.attachments, ID.segment, ID.ebml]
    private static let maxLeaf = 16 * 1_048_576

    private struct Frame: Sendable { var id: UInt32; var end: Int64? }

    private var buf: [UInt8] = []
    private var head = 0
    /// Absolute stream offset of `buf[head]`.
    private(set) var offset: Int64 = 0
    private var stack: [Frame] = []
    private var skip: Int64 = 0
    private var resync = false

    // Segment and timing.
    private(set) var segmentDataStart: Int64?
    private(set) var timecodeScale: Int64 = 1_000_000
    private(set) var durationSeconds: Double?
    private(set) var cuesPosition: Int64?
    private(set) var firstClusterOffset: Int64?
    /// True once the first cluster has been seen: after this the tracks are known or the file is not usable.
    var reachedClusters: Bool { firstClusterOffset != nil }
    private var clusterTime: Int64 = 0

    // Track being read.
    private var entry = TrackDraft()
    private struct TrackDraft: Sendable {
        var number = 0, type = 0, codec = "", priv: [UInt8] = [], channels = 2, delayNs: Int64 = 0
    }
    private var foundCodecs: [String] = []
    private(set) var opusTrack: Int?
    private(set) var trackInfo: MusicOpusTrackInfo?

    // Cues and seek entries being read.
    private var cuePoints: [MusicOpusCue] = []
    private var cueDraft = (time: Int64(0), position: Int64(-1))
    private var seekIDDraft: [UInt8] = []
    private var seekPosDraft: Int64 = -1

    // A block group's block waits for its DiscardPadding.
    private var pending: [MusicOpusPacket] = []
    private var pendingDiscardNs: Int64 = 0
    private var events: [MusicOpusEvent] = []

    init() {}

    /// Reads from a known place in an already-opened stream (a seek, or the Cues at the end of the file). `clusterAligned` says the first
    /// byte fed is the start of a cluster or Cues element; otherwise the demuxer scans forward for the next cluster.
    mutating func restart(atOffset o: Int64, clusterAligned: Bool) {
        buf = []; head = 0; offset = o; skip = 0
        stack = [Frame(id: ID.segment, end: nil)]
        resync = !clusterAligned
        pending = []; pendingDiscardNs = 0; events = []
        clusterTime = 0
    }

    var cues: [MusicOpusCue] { cuePoints }

    // MARK: feeding

    mutating func feed(_ data: [UInt8]) throws -> [MusicOpusEvent] {
        buf.append(contentsOf: data)
        try pump()
        if head > 1 << 16 { buf.removeFirst(head); head = 0 }
        defer { events = [] }
        return events
    }

    private var avail: Int { buf.count - head }

    private mutating func consume(_ n: Int) { head += n; offset += Int64(n) }

    private mutating func pump() throws {
        while true {
            if resync { guard scanForCluster() else { return } }
            popFinished()
            if skip > 0 {
                let n = Int(min(skip, Int64(avail)))
                consume(n); skip -= Int64(n)
                if skip > 0 { return }
                continue
            }
            guard let (id, idLen) = Self.readID(buf, head) else {
                if avail >= 1, buf[head].leadingZeroBitCount >= 4 { throw MusicOpusError.malformed("bad element id") }
                return
            }
            guard let (size, sizeLen) = Self.readVint(buf, head + idLen, keepMarker: false) else {
                if avail >= idLen + 1, buf[head + idLen] == 0 { throw MusicOpusError.malformed("bad element size") }
                return
            }
            let unknown = size == Self.unknownSize(length: sizeLen)
            // An open cluster of unknown size ends where the next top-level element begins.
            if let top = stack.last, top.end == nil, top.id == ID.cluster || top.id == ID.cues, Self.levelOne.contains(id) {
                popTop()
                continue
            }
            let header = idLen + sizeLen
            if id == ID.cluster, firstClusterOffset == nil { firstClusterOffset = offset }
            if Self.masters.contains(id) {
                consume(header)
                stack.append(Frame(id: id, end: unknown ? nil : offset + size))
                enter(id)
                continue
            }
            if Self.leaves.contains(id) {
                guard !unknown, size <= Int64(Self.maxLeaf) else { throw MusicOpusError.malformed("oversized element") }
                guard avail >= header + Int(size) else { return }
                let payload = Array(buf[(head + header)..<(head + header + Int(size))])
                consume(header + Int(size))
                try leaf(id, payload)
                continue
            }
            guard !unknown else { throw MusicOpusError.malformed("unknown size on a skipped element") }
            consume(header)
            skip = size
        }
    }

    /// Finds the next cluster id in the buffer and drops everything before it. False when more bytes are needed.
    private mutating func scanForCluster() -> Bool {
        let key: [UInt8] = [0x1F, 0x43, 0xB6, 0x75]
        var i = head
        while i + 5 < buf.count {
            if buf[i] == key[0], buf[i + 1] == key[1], buf[i + 2] == key[2], buf[i + 3] == key[3],
               let (size, len) = Self.readVint(buf, i + 4, keepMarker: false), size > 0, i + 4 + len < buf.count {
                // A real cluster starts with its Timecode element.
                let next = buf[i + 4 + len]
                if next == 0xE7 || size == Self.unknownSize(length: len) { consume(i - head); resync = false; return true }
            }
            i += 1
        }
        let keep = min(avail, 8)
        consume(avail - keep)
        return false
    }

    private mutating func popFinished() {
        while let top = stack.last, let end = top.end, offset >= end { popTop() }
    }

    private mutating func popTop() {
        guard let f = stack.popLast() else { return }
        exit(f.id)
    }

    // MARK: structure

    private mutating func enter(_ id: UInt32) {
        switch id {
        case ID.segment: if segmentDataStart == nil { segmentDataStart = offset }
        case ID.trackEntry: entry = TrackDraft()
        case ID.cluster:
            clusterTime = 0
        case ID.cuePoint: cueDraft = (0, -1)
        case ID.seek: seekIDDraft = []; seekPosDraft = -1
        case ID.blockGroup: pending = []; pendingDiscardNs = 0
        default: break
        }
    }

    private mutating func exit(_ id: UInt32) {
        switch id {
        case ID.trackEntry: finishTrackEntry()
        case ID.tracks: finishTracks()
        case ID.info: if let d = durationSeconds { events.append(.duration(d)) }
        case ID.cuePoint:
            if cueDraft.position >= 0 { cuePoints.append(MusicOpusCue(time: Double(cueDraft.time) * Double(timecodeScale) / 1e9, position: cueDraft.position)) }
        case ID.cues:
            cuePoints.sort { $0.time < $1.time }
            events.append(.cues(cuePoints))
        case ID.seek:
            if seekIDDraft == [0x1C, 0x53, 0xBB, 0x6B], seekPosDraft >= 0 { cuesPosition = seekPosDraft }
        case ID.blockGroup: flushPending()
        default: break
        }
    }

    private mutating func finishTrackEntry() {
        foundCodecs.append(entry.codec)
        guard opusTrack == nil, entry.codec == "A_OPUS", entry.type == 2 || entry.type == 0 else { return }
        opusTrack = entry.number
        let h = MusicOpusHead.parse(entry.priv) ?? .fallback(channels: entry.channels, codecDelayNs: entry.delayNs)
        trackInfo = MusicOpusTrackInfo(head: h, duration: durationSeconds)
    }

    private mutating func finishTracks() {
        if var t = trackInfo { t.duration = durationSeconds; trackInfo = t; events.append(.track(t)) }
    }

    /// Set when the file's tracks were read and none of them is Opus; the reason names the codec.
    var unsupportedReason: String? {
        guard opusTrack == nil, !foundCodecs.isEmpty else { return nil }
        return foundCodecs.first(where: { $0.hasPrefix("A_") }).map { $0.replacingOccurrences(of: "A_", with: "") } ?? "no audio track"
    }

    private mutating func leaf(_ id: UInt32, _ p: [UInt8]) throws {
        switch id {
        case ID.timecodeScale: timecodeScale = max(1, Self.uint(p))
        case ID.duration:
            if let d = Self.float(p), d.isFinite, d >= 0 { durationSeconds = d * Double(timecodeScale) / 1e9 }
        case ID.trackNumber: entry.number = Int(Self.uint(p))
        case ID.trackType: entry.type = Int(Self.uint(p))
        case ID.codecID: entry.codec = String(decoding: p.prefix { $0 != 0 }, as: UTF8.self)
        case ID.codecPrivate: entry.priv = p
        case ID.codecDelay: entry.delayNs = Self.uint(p)
        case ID.channels: entry.channels = Int(Self.uint(p))
        case ID.seekID: seekIDDraft = p
        case ID.seekPosition: seekPosDraft = Self.uint(p)
        case ID.cueTime: cueDraft.time = Self.uint(p)
        case ID.cueClusterPosition: cueDraft.position = Self.uint(p)
        case ID.cueTrack: break
        case ID.timecode: clusterTime = Self.uint(p)
        case ID.simpleBlock: try block(p, inGroup: false)
        case ID.block: try block(p, inGroup: true)
        case ID.discardPadding: pendingDiscardNs = Self.sint(p)
        default: break
        }
    }

    // MARK: blocks

    private mutating func block(_ p: [UInt8], inGroup: Bool) throws {
        guard let (track, tlen) = Self.readVint(p, 0, keepMarker: false), p.count >= tlen + 3 else { throw MusicOpusError.malformed("short block") }
        if let want = opusTrack { guard Int(track) == want else { return } } else if trackInfo == nil { return }
        let rel = Int(Int16(bitPattern: UInt16(p[tlen]) << 8 | UInt16(p[tlen + 1])))
        let flags = p[tlen + 2]
        let body = Array(p[(tlen + 3)...])
        let base = Double(clusterTime + Int64(rel)) * Double(timecodeScale) / 1e9
        let frames = try Self.unlace(body, mode: Int((flags >> 1) & 3))
        var t = base
        var out: [MusicOpusPacket] = []
        for f in frames {
            guard let n = MusicOpusTOC.samples(in: f) else { continue }
            out.append(MusicOpusPacket(data: f, time: t, samples: n))
            t += Double(n) / 48_000
        }
        if inGroup { pending.append(contentsOf: out) } else { for o in out { events.append(.packet(o)) } }
    }

    private mutating func flushPending() {
        guard !pending.isEmpty else { return }
        if pendingDiscardNs > 0, var last = pending.popLast() {
            last.discardEnd = Int(min(Int64(last.samples), pendingDiscardNs * 48_000 / 1_000_000_000))
            pending.append(last)
        }
        for p in pending { events.append(.packet(p)) }
        pending = []; pendingDiscardNs = 0
    }

    /// Splits a block body into frames. Mode 0 none, 1 Xiph, 2 fixed-size, 3 EBML.
    static func unlace(_ b: [UInt8], mode: Int) throws -> [[UInt8]] {
        if mode == 0 { return b.isEmpty ? [] : [b] }
        guard let first = b.first else { return [] }
        let count = Int(first) + 1
        var pos = 1
        var sizes: [Int] = []
        switch mode {
        case 2:
            let rest = b.count - 1
            guard rest % count == 0 else { throw MusicOpusError.malformed("fixed lacing size") }
            sizes = Array(repeating: rest / count, count: count)
            pos = 1
        case 1:
            for _ in 0..<(count - 1) {
                var s = 0
                while true {
                    guard pos < b.count else { throw MusicOpusError.malformed("xiph lacing") }
                    let v = Int(b[pos]); pos += 1; s += v
                    if v != 255 { break }
                }
                sizes.append(s)
            }
        default:
            if count >= 2 {
            guard let (firstSize, len) = readVint(b, pos, keepMarker: false) else { throw MusicOpusError.malformed("ebml lacing") }
            pos += len
            var prev = Int(firstSize)
            sizes.append(prev)
            for _ in 1..<max(1, count - 1) {
                guard let (raw, l) = readVint(b, pos, keepMarker: false) else { throw MusicOpusError.malformed("ebml lacing") }
                pos += l
                // Signed vint: subtract the bias for this length.
                let bias = (Int64(1) << Int64(7 * l - 1)) - 1
                prev += Int(raw - bias)
                guard prev >= 0 else { throw MusicOpusError.malformed("ebml lacing") }
                sizes.append(prev)
            }
            }
        }
        if mode != 2 {
            let used = sizes.reduce(0, +)
            let last = b.count - pos - used
            guard last >= 0 else { throw MusicOpusError.malformed("lacing sizes exceed the block") }
            sizes.append(last)
        }
        var out: [[UInt8]] = []
        var at = pos
        for s in sizes {
            guard at + s <= b.count else { throw MusicOpusError.malformed("lacing overrun") }
            out.append(Array(b[at..<(at + s)])); at += s
        }
        return out
    }

    // MARK: EBML primitives

    /// The element id at `i`: the marker bits stay in, ids are 1 to 4 bytes.
    static func readID(_ b: [UInt8], _ i: Int) -> (UInt32, Int)? {
        guard i < b.count else { return nil }
        let first = b[i]
        guard first != 0 else { return nil }
        let len = first.leadingZeroBitCount + 1
        guard len <= 4, i + len <= b.count else { return nil }
        var v: UInt32 = 0
        for k in 0..<len { v = v << 8 | UInt32(b[i + k]) }
        return (v, len)
    }

    /// A variable-length integer of 1 to 8 bytes. With `keepMarker` false the length marker bit is removed (sizes, track numbers).
    static func readVint(_ b: [UInt8], _ i: Int, keepMarker: Bool) -> (Int64, Int)? {
        guard i >= 0, i < b.count else { return nil }
        let first = b[i]
        guard first != 0 else { return nil }
        let len = first.leadingZeroBitCount + 1
        guard i + len <= b.count else { return nil }
        var v = Int64(keepMarker ? first : first & (0xFF >> UInt8(len)))
        for k in 1..<max(1, len) { v = v << 8 | Int64(b[i + k]) }
        return (v, len)
    }

    /// The value a size field has when every data bit is one: "unknown".
    static func unknownSize(length: Int) -> Int64 { (Int64(1) << Int64(7 * length)) - 1 }

    static func uint(_ p: [UInt8]) -> Int64 {
        var v: Int64 = 0
        for b in p.prefix(8) { v = v << 8 | Int64(b) }
        return v
    }

    static func sint(_ p: [UInt8]) -> Int64 {
        guard let f = p.first, !p.isEmpty, p.count <= 8 else { return 0 }
        var v: Int64 = f & 0x80 != 0 ? -1 : 0
        for b in p { v = v << 8 | Int64(b) }
        return v
    }

    static func float(_ p: [UInt8]) -> Double? {
        if p.count == 4 { return Double(Float(bitPattern: UInt32(uint(p)))) }
        if p.count == 8 { return Double(bitPattern: UInt64(bitPattern: uint(p))) }
        return nil
    }
}

extension MusicWebMDemuxer {
    /// The latest cue at or before `time`; the cluster to restart from for a seek.
    static func cue(for time: Double, in cues: [MusicOpusCue]) -> MusicOpusCue? {
        guard !cues.isEmpty else { return nil }
        var best = cues[0]
        for c in cues where c.time <= time { best = c }
        return best
    }
}
