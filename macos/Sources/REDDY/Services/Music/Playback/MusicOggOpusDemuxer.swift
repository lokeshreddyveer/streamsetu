import Foundation

/// A streaming demuxer for Opus in Ogg (RFC 3533 pages, RFC 7845 mapping). Feed bytes in any chunking. The first logical stream that
/// starts with OpusHead is followed; other streams in the same file are ignored. Packet times come from the page granule positions.
struct MusicOggOpusDemuxer: Sendable {
    private var buf: [UInt8] = []
    private var head = 0
    private(set) var offset: Int64 = 0
    private var serial: UInt32?
    private var partial: [UInt8] = []
    private var havePartial = false
    private var headerSeen = false
    private var tagsSeen = false
    private(set) var trackInfo: MusicOpusTrackInfo?
    /// Samples at 48 kHz, counted from the first audio sample (before pre-skip), of the next packet to complete.
    private var cursor: Int64 = 0
    private var resync = false
    private var events: [MusicOpusEvent] = []

    init() {}

    /// Starts reading at a page boundary guess: the demuxer scans for the next "OggS" and drops a packet that began before it.
    mutating func restart(atOffset o: Int64) {
        buf = []; head = 0; offset = o
        partial = []; havePartial = false
        resync = true
        anchorNext = true
        events = []
    }

    mutating func feed(_ data: [UInt8]) throws -> [MusicOpusEvent] {
        buf.append(contentsOf: data)
        try pump()
        if head > 1 << 16 { buf.removeFirst(head); head = 0 }
        defer { events = [] }
        return events
    }

    private var avail: Int { buf.count - head }
    private mutating func consume(_ n: Int) { head += n; offset += Int64(n) }

    private static func isCapture(_ b: [UInt8], _ i: Int) -> Bool {
        i + 4 <= b.count && b[i] == 0x4F && b[i + 1] == 0x67 && b[i + 2] == 0x67 && b[i + 3] == 0x53
    }

    private mutating func pump() throws {
        while true {
            // Find the next page start. After a seek, or after damage, bytes before it are dropped.
            if avail >= 4, !Self.isCapture(buf, head) {
                if !resync, !headerSeen { throw MusicOpusError.malformed("not an Ogg file") }
                if !resync { partial = []; havePartial = false }
                var i = head
                while i + 4 <= buf.count, !Self.isCapture(buf, i) { i += 1 }
                if i + 4 > buf.count { consume(max(0, avail - 3)); return }
                consume(i - head)
            }
            guard avail >= 27 else { return }
            guard Self.isCapture(buf, head) else { return }
            let segCount = Int(buf[head + 26])
            guard avail >= 27 + segCount else { return }
            var bodyLen = 0
            for k in 0..<segCount { bodyLen += Int(buf[head + 27 + k]) }
            let total = 27 + segCount + bodyLen
            guard avail >= total else { return }
            let flags = buf[head + 5]
            let granule = Self.le64(buf, head + 6)
            let ser = UInt32(buf[head + 14]) | UInt32(buf[head + 15]) << 8 | UInt32(buf[head + 16]) << 16 | UInt32(buf[head + 17]) << 24
            let lacing = Array(buf[(head + 27)..<(head + 27 + segCount)])
            let body = Array(buf[(head + 27 + segCount)..<(head + total)])
            consume(total)
            try page(flags: flags, granule: granule, serial: ser, lacing: lacing, body: body)
        }
    }

    private mutating func page(flags: UInt8, granule: Int64, serial ser: UInt32, lacing: [UInt8], body: [UInt8]) throws {
        let continued = flags & 1 != 0
        let beginning = flags & 2 != 0
        let ending = flags & 4 != 0
        if let s = serial, s != ser, !(beginning && !headerSeen) { return }
        // Cut the body into packets.
        var packets: [[UInt8]] = []
        var cur: [UInt8] = continued && havePartial ? partial : []
        var skippingLostStart = continued && !havePartial
        var at = 0
        var open = false
        for l in lacing {
            let n = Int(l)
            if !skippingLostStart { cur.append(contentsOf: body[at..<(at + n)]) }
            at += n
            if n < 255 {
                if skippingLostStart { skippingLostStart = false } else { packets.append(cur) }
                cur = []; open = false
            } else { open = true }
        }
        partial = open ? cur : []
        havePartial = open
        resync = false

        var audio: [MusicOpusPacket] = []
        for p in packets {
            if !headerSeen {
                guard let h = MusicOpusHead.parse(p) else {
                    if beginning, p.count >= 7, Array(p[0..<min(p.count, 8)]).starts(with: Array("\u{1}vorbis".utf8)) { throw MusicOpusError.unsupported("Vorbis") }
                    if beginning { continue } else { throw MusicOpusError.malformed("missing OpusHead") }
                }
                guard h.channels <= 8 else { throw MusicOpusError.unsupported("too many channels") }
                serial = ser; headerSeen = true
                trackInfo = MusicOpusTrackInfo(head: h, duration: nil)
                events.append(.track(trackInfo ?? MusicOpusTrackInfo(head: h, duration: nil)))
                continue
            }
            if p.count >= 8, Array(p[0..<8]) == Array("OpusTags".utf8) || Array(p[0..<8]) == Array("OpusHead".utf8) { tagsSeen = true; continue }
            guard let n = MusicOpusTOC.samples(in: p) else { continue }
            audio.append(MusicOpusPacket(data: p, time: 0, samples: n))
        }
        guard !audio.isEmpty else { return }
        // Anchor to the granule when the page gives one: it is the end of its last completed packet.
        let sum = audio.reduce(0) { $0 + Int64($1.samples) }
        if granule >= 0 {
            let start = granule - sum
            if start >= 0, (anchorNext || abs(start - cursor) > 4800) { cursor = start }
        }
        anchorNext = false
        for i in audio.indices {
            audio[i].time = Double(cursor) / 48_000
            cursor += Int64(audio[i].samples)
        }
        if ending, granule >= 0, cursor > granule, var last = audio.popLast() {
            last.discardEnd = Int(min(Int64(last.samples), cursor - granule))
            audio.append(last)
        }
        for a in audio { events.append(.packet(a)) }
    }

    /// True until the first audio page after a seek, so its granule re-anchors the clock whatever the old cursor said.
    private var anchorNext = true

    private static func le64(_ b: [UInt8], _ i: Int) -> Int64 {
        var v: UInt64 = 0
        for k in (0..<8).reversed() { v = v << 8 | UInt64(b[i + k]) }
        return Int64(bitPattern: v)
    }

    // MARK: seeking helpers

    /// The granule of the last page that completes a packet in `tail`, if any. Used to learn the length of a file from its last bytes.
    static func lastGranule(in tail: [UInt8]) -> Int64? {
        var i = tail.count - 27
        while i >= 0 {
            if isCapture(tail, i) {
                let g = le64(tail, i + 6)
                if g >= 0 { return g }
            }
            i -= 1
        }
        return nil
    }

    /// The granule of the first page in `data` that has one, with the offset of that page inside `data`.
    static func firstGranule(in data: [UInt8]) -> (granule: Int64, at: Int)? {
        var i = 0
        while i + 27 <= data.count {
            if isCapture(data, i) {
                let g = le64(data, i + 6)
                if g >= 0 { return (g, i) }
            }
            i += 1
        }
        return nil
    }

    /// Seconds of audio in a file whose last page carries `granule`.
    static func duration(lastGranule g: Int64, preSkip: Int) -> Double { Double(max(0, g - Int64(preSkip))) / 48_000 }
}
