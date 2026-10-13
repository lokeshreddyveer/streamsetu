import Foundation
import Network

/// Splits a raw MPEG-TS live stream into HLS-style segments. Pure value logic (no I/O), so it can be tested with
/// synthetic packets. Segments start on a video keyframe (random-access indicator) and are prefixed with the PAT/PMT
/// so each one is independently decodable.
/// What a transport stream says about itself: its program tables (kept so a copy can be put in front of any cut), which stream is the video
/// and which the audio, and the audio layer. One reader, used by the HLS segmenter and by the raw relay, so they cannot disagree.
struct TSTables: Sendable {
    private(set) var pat: Data?, pmt: Data?
    private(set) var pmtPID = -1
    private(set) var videoPID = -1
    /// Every elementary stream the PMT declared: (stream type, PID). Types: 0x02 MPEG-2 video, 0x1B H.264, 0x24 HEVC, 0x03/0x04 MPEG audio, 0x0F AAC, 0x81 AC-3, 0x87 E-AC-3.
    private(set) var streamTypes: [(type: Int, pid: Int)] = []
    /// True once the first audio frame turned out to be MPEG Layer I or II, which Apple's player cannot play (Layer III, "MP3", is fine).
    private(set) var audioIsMPEGLayerII = false
    private var audioPID = -1
    private var audioChecked = false

    var ready: Bool { pat != nil && pmt != nil && videoPID >= 0 }

    static func pid(_ p: Data) -> Int { (Int(p[1] & 0x1F) << 8) | Int(p[2]) }
    static func startsPayload(_ p: Data) -> Bool { p[1] & 0x40 != 0 }
    static func payloadOffset(_ p: Data) -> (offset: Int, has: Bool) {
        let afc = (p[3] >> 4) & 3
        var payload = 4
        if afc & 2 != 0 { payload += 1 + Int(p[4]) }
        return (payload, afc & 1 != 0 && payload < 188)
    }
    /// True when the packet marks a random-access point (a keyframe the decoder can start from).
    static func isRandomAccess(_ p: Data) -> Bool { (p[3] >> 4) & 2 != 0 && p[4] > 0 && (p[5] & 0x40) != 0 }

    mutating func observe(_ p: Data) {
        let pid = Self.pid(p), pusi = Self.startsPayload(p)
        let (payload, hasPayload) = Self.payloadOffset(p)

        if pid == 0, pusi, hasPayload {
            pat = p
            var i = payload + 1 + 8       // pointer_field + table header
            while i + 4 <= 188 - 4 {
                let prog = (Int(p[i]) << 8) | Int(p[i + 1])
                let ppid = (Int(p[i + 2] & 0x1F) << 8) | Int(p[i + 3])
                if prog != 0 { pmtPID = ppid; break }
                i += 4
            }
        } else if pid == pmtPID, pusi, hasPayload {
            pmt = p
            let base = payload + 1
            if base + 12 <= 188 {
                let sectionLen = (Int(p[base + 1] & 0x0F) << 8) | Int(p[base + 2])
                let progInfo = (Int(p[base + 10] & 0x0F) << 8) | Int(p[base + 11])
                var i = base + 12 + progInfo
                let end = min(base + 3 + sectionLen - 4, 188)
                streamTypes = []
                while i + 5 <= end {
                    let type = p[i]
                    let epid = (Int(p[i + 1] & 0x1F) << 8) | Int(p[i + 2])
                    let esInfo = (Int(p[i + 3] & 0x0F) << 8) | Int(p[i + 4])
                    streamTypes.append((Int(type), epid))
                    if [0x01, 0x02, 0x10, 0x1B, 0x24].contains(type), videoPID < 0 { videoPID = epid }
                    if (type == 0x03 || type == 0x04), audioPID < 0 { audioPID = epid }
                    i += 5 + esInfo
                }
            }
        }

        // The first audio frame says which MPEG audio layer this is: header 0xFFE.., layer in bits 1-2 of the next byte.
        if ready, !audioChecked, pid == audioPID, pusi, hasPayload, payload + 9 < 188, p[payload] == 0, p[payload + 1] == 0, p[payload + 2] == 1 {
            let start = payload + 9 + Int(p[payload + 8])
            if start + 2 <= 188 {
                audioChecked = true
                if p[start] == 0xFF, p[start + 1] & 0xE0 == 0xE0 { audioIsMPEGLayerII = ((p[start + 1] >> 1) & 3) != 1 }
            }
        }
    }
}

struct TSSegmenter: Sendable {
    struct Segment: Sendable { let seq: Int; let data: Data; let duration: Double }

    var minSegment = 2.0
    var maxSegment = 8.0
    var keep = 8

    private(set) var segments: [Segment] = []
    private(set) var nextSeq = 0
    private(set) var tables = TSTables()
    var videoPID: Int { tables.videoPID }
    var streamTypes: [(type: Int, pid: Int)] { tables.streamTypes }
    var audioIsMPEGLayerII: Bool { tables.audioIsMPEGLayerII }
    private(set) var droppedBytes = 0
    private var carry = Data()
    private var cur = Data()
    private var curStartPTS: Int64?
    private var curStartWall = Date()
    private var startNextImmediately = false

    mutating func ingest(_ data: Data, now: Date = Date()) {
        carry.append(data)
        var off = 0
        while carry.count - off >= 188 {
            if carry[off] != 0x47 { off += 1; droppedBytes += 1; continue }     // resync on the next sync byte
            process(carry.subdata(in: off..<off + 188), now: now)
            off += 188
        }
        carry.removeSubrange(0..<off)
    }

    private mutating func process(_ p: Data, now: Date) {
        tables.observe(p)
        let pid = TSTables.pid(p), pusi = TSTables.startsPayload(p)
        let (payload, hasPayload) = TSTables.payloadOffset(p)
        let afc = (p[3] >> 4) & 3

        guard tables.ready, let pat = tables.pat, let pmt = tables.pmt else { return }       // wait for the stream tables


        if pid == tables.videoPID, pusi {
            let rai = TSTables.isRandomAccess(p)
            let pts = hasPayload ? Self.pts(p, payload) : nil
            if !cur.isEmpty {
                let el = elapsed(pts, now: now)
                if (rai && el >= minSegment) || el >= maxSegment {
                    // Encoders that never flag keyframes still get steady segments: after a forced cut, start right away.
                    startNextImmediately = !rai
                    finishSegment(duration: el)
                }
            }
            if cur.isEmpty, rai || startNextImmediately || now.timeIntervalSince(curStartWall) > 4 {
                startNextImmediately = false
                cur.append(pat); cur.append(pmt)
                curStartPTS = pts
                curStartWall = now
            }
        }
        if !cur.isEmpty { cur.append(p) }
    }

    private func elapsed(_ pts: Int64?, now: Date) -> Double {
        if let a = curStartPTS, let b = pts {
            let d = (b - a + (1 << 33)) % (1 << 33)            // 33-bit wraparound
            if d < 90_000 * 60 { return Double(d) / 90_000 }
        }
        return now.timeIntervalSince(curStartWall)
    }

    private mutating func finishSegment(duration: Double) {
        segments.append(Segment(seq: nextSeq, data: cur, duration: max(0.5, duration)))
        nextSeq += 1
        if segments.count > keep { segments.removeFirst(segments.count - keep) }
        cur = Data()
        curStartPTS = nil
    }

    /// PTS (90 kHz) from the PES header at the start of a payload, if present.
    static func pts(_ p: Data, _ o: Int) -> Int64? {
        guard o + 14 <= 188, p[o] == 0, p[o + 1] == 0, p[o + 2] == 1, p[o + 7] & 0x80 != 0 else { return nil }
        let x = (o + 9..<o + 14).map { Int64(p[$0]) }
        return ((x[0] >> 1) & 7) << 30 | x[1] << 22 | (x[2] >> 1) << 15 | x[3] << 7 | x[4] >> 1
    }

    /// A live playlist once enough segments exist for a player to start (3), else nil.
    func playlist(minimumSegments: Int = 3) -> String? {
        guard segments.count >= minimumSegments else { return nil }
        let target = Int(ceil(segments.map(\.duration).max() ?? 4))
        var m = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:\(target)\n#EXT-X-MEDIA-SEQUENCE:\(segments[0].seq)\n"
        for s in segments { m += "#EXTINF:\(String(format: "%.3f", s.duration)),\nseg/\(s.seq).ts\n" }
        return m
    }

    func segment(_ seq: Int) -> Data? { segments.first { $0.seq == seq }?.data }
}

/// Cuts a live TS stream so it begins on a keyframe: everything before the first picture a decoder can start from is dropped, and the
/// program tables are put in front. Hardware decoders refuse to start in the middle of a group of pictures, which is why a stream opened
/// at a random moment used to fall back to slow software decoding.
struct TSKeyframeGate: Sendable {
    private(set) var tables = TSTables()
    private(set) var started = false
    private var carry = Data()
    private var waitingSince: Date
    private(set) var skippedBytes = 0

    init(now: Date = Date()) { waitingSince = now }

    mutating func reset(now: Date = Date()) { tables = TSTables(); started = false; carry = Data(); waitingSince = now; skippedBytes = 0 }

    /// Returns what should be forwarded (empty until the stream has reached a keyframe).
    mutating func ingest(_ data: Data, now: Date = Date()) -> Data {
        carry.append(data)
        var out = Data()
        var off = 0
        while carry.count - off >= 188 {
            if carry[off] != 0x47 { off += 1; continue }                                         // resync on the next sync byte
            let p = carry.subdata(in: off..<off + 188)
            off += 188
            tables.observe(p)
            if started { out.append(p); continue }
            guard tables.ready, let pat = tables.pat, let pmt = tables.pmt else { skippedBytes += 188; continue }
            // Start at a flagged keyframe; an encoder that never flags them is cut in at the next picture after 3 seconds instead.
            if TSTables.pid(p) == tables.videoPID, TSTables.startsPayload(p), TSTables.isRandomAccess(p) || now.timeIntervalSince(waitingSince) > 3 {
                started = true
                out.append(pat); out.append(pmt); out.append(p)
            } else { skippedBytes += 188 }
        }
        carry.removeSubrange(0..<off)
        return out
    }
}

/// Republishes a raw MPEG-TS live stream as a rolling HLS playlist on localhost, so AVPlayer can play it.
/// Many IPTV panels only serve `.ts`; AVFoundation only understands HLS.
final class TSBridge: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// `.hls` republishes the stream as a rolling HLS playlist for Apple's player. `.raw` passes the stream through unchanged, starting on a
    /// keyframe, for MPV: the phone's own network stack fetches it (names, IPv6-only networks, proxy and VPN all handled by the system).
    enum Mode: Sendable { case hls, raw }
    private let mode: Mode
    private var gate = TSKeyframeGate()
    private var rawClient: NWConnection?
    private var rawPending = Data()
    private var rawOutstanding = 0
    private var rawTraced = false
    private let source: URL
    private let q = DispatchQueue(label: "app.reddy.tsbridge")
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var listener: NWListener?
    private var stopped = false
    private var segmenter = TSSegmenter()
    private var _failure: String?
    private var _status: Int?
    private var _bytes = 0
    private var _ended = false
    private var _tracedSegments = 0

    var failure: String? { q.sync { _failure } }
    /// HTTP status of the upstream stream request, once known.
    var httpStatus: Int? { q.sync { _status } }
    /// Set when the stream carries video Apple's player cannot show inside live TS (HEVC, MPEG-2): it would play the sound and no picture.
    var unsupportedVideo: String? {
        q.sync {
            let t = mode == .raw ? gate.tables : segmenter.tables
            let types = t.streamTypes.map(\.type)
            if types.contains(0x24) { return "HEVC video in a live stream" }
            if types.contains(0x02) || types.contains(0x01) { return "MPEG-2 video in a live stream" }
            if t.audioIsMPEGLayerII { return "MPEG Layer II (MP2) audio in a live stream" }
            return nil
        }
    }
    /// The provider answered 200 and then closed the connection without a single byte of video: usually its one-connection limit.
    var receivedNothing: Bool { q.sync { _ended && _bytes == 0 && _status == 200 } }

    private let headers: [String: String]

    init(source: URL, headers: [String: String] = [:], mode: Mode = .hls) {
        self.mode = mode
        self.headers = headers
        self.source = source
        super.init()
        let op = OperationQueue()
        op.maxConcurrentOperationCount = 1
        op.underlyingQueue = q
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: op)
    }

    /// Starts the localhost server and the upstream download. Returns the playlist URL for AVPlayer.
    func start() async throws -> URL {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let l = try NWListener(using: params)
        listener = l
        l.newConnectionHandler = { [weak self] c in self?.handle(c) }
        let port: UInt16 = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            let once = Once()
            l.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.take() { cont.resume(returning: l.port?.rawValue ?? 0) }
                case .failed(let e): if once.take() { cont.resume(throwing: e) }
                default: break
                }
            }
            l.start(queue: q)
        }
        var req = URLRequest(url: source, timeoutInterval: 30)
        req.setValue("VLC/3.0.20 LibVLC/3.0.20", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let upstream = req
        q.async { [self] in
            guard !stopped else { return }
            task = session.dataTask(with: upstream)
            task?.resume()
        }
        return URL(string: "http://127.0.0.1:\(port)/\(mode == .raw ? "raw.ts" : "live.m3u8")")!
    }

    func stop() {
        q.async { [self] in
            stopped = true
            task?.cancel()
            listener?.cancel()
            session.invalidateAndCancel()
        }
    }

    // MARK: upstream

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let h = response as? HTTPURLResponse {
            Trace.log("bridge upstream HTTP \(h.statusCode) content-type=\(h.value(forHTTPHeaderField: "Content-Type") ?? "-") length=\(h.value(forHTTPHeaderField: "Content-Length") ?? "-")")
            _status = h.statusCode
            if h.statusCode != 200 { _failure = "The server refused the stream (HTTP \(h.statusCode))."; completionHandler(.cancel); return }
        }
        completionHandler(.allow)
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if Trace.on {
            if _bytes == 0 {
                let looksText = data.prefix(64).allSatisfy { ($0 >= 32 && $0 < 127) || $0 == 10 || $0 == 13 || $0 == 9 }
                Trace.log("bridge first bytes: \(data.count) B, first=0x\(String(format: "%02X", data.first ?? 0)), \(looksText ? "TEXT: " + String(decoding: data.prefix(160), as: UTF8.self).replacingOccurrences(of: "\n", with: " ") : "binary")")
            }
        }
        _bytes += data.count
        if mode == .raw {
            let chunk = gate.ingest(data)
            if !rawTraced, gate.started {
                rawTraced = true
                Trace.log("relay started on a keyframe after skipping \(gate.skippedBytes) B; streams=\(gate.tables.streamTypes.map { String(format: "0x%02X", $0.type) }.joined(separator: ","))")
            }
            deliverRaw(chunk)
            return
        }
        segmenter.ingest(data)
        if Trace.on, segmenter.nextSeq != _tracedSegments {
            _tracedSegments = segmenter.nextSeq
            Trace.log("bridge segments=\(segmenter.nextSeq) videoPID=\(segmenter.videoPID) bytes=\(_bytes) dropped=\(segmenter.droppedBytes) streams=\(segmenter.streamTypes.map { String(format: "0x%02X", $0.type) }.joined(separator: ","))")
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Trace.log("bridge upstream ended: error=\(error.map { "\(($0 as NSError).domain) \(($0 as NSError).code) \($0.localizedDescription)" } ?? "none") bytes=\(_bytes) segments=\(segmenter.nextSeq) stopped=\(stopped)")
        if !stopped { _ended = true }
        if mode == .raw, let c = rawClient { c.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() }) }     // tell MPV the stream ended
        if !stopped, _failure == nil { _failure = _bytes == 0 ? "The server accepted the connection but sent no video. This is usually a connection limit, an expired account, or a blocked server." : (error?.localizedDescription ?? "The stream ended.") }
    }

    // MARK: localhost HTTP server

    private func handle(_ c: NWConnection) {
        c.start(queue: q)
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self, let data, let line = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n").first
            else { c.cancel(); return }
            let parts = line.split(separator: " ")
            guard parts.count >= 2 else { c.cancel(); return }
            self.route(String(parts[1]), c, tries: 0)
        }
    }

    // MARK: raw pass-through (for MPV)

    private func serveRaw(_ c: NWConnection, tries: Int = 0) {
        if let f = _failure, _bytes == 0 { return reply(c, 502, "text/plain", Data(f.utf8)) }
        if !gate.started, tries <= 100, !stopped { return q.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.serveRaw(c, tries: tries + 1) } }
        if !gate.started { return reply(c, 504, "text/plain", Data("No data from the stream.".utf8)) }
        rawClient?.cancel()
        rawClient = c
        c.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.stop() }
            if case .cancelled = state { self?.q.async { if self?.rawClient === c { self?.rawClient = nil; self?.stop() } } }       // MPV closed it: let the provider's slot go at once
        }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        let first = Data(head.utf8) + rawPending
        rawPending = Data()
        sendRaw(first, to: c)
    }

    private func deliverRaw(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        if let c = rawClient { sendRaw(chunk, to: c); return }
        rawPending.append(chunk)
        if rawPending.count > 8_000_000 { rawPending = Data(); gate.reset() }       // nobody is listening: start again from the next keyframe
    }

    private func sendRaw(_ data: Data, to c: NWConnection) {
        rawOutstanding += data.count
        if rawOutstanding > 16_000_000 { Trace.log("relay: MPV is not keeping up, closing"); c.cancel(); return }
        c.send(content: data, completion: .contentProcessed { [weak self] _ in self?.q.async { self?.rawOutstanding -= data.count } })
    }

    private func route(_ path: String, _ c: NWConnection, tries: Int) {
        if path.hasPrefix("/raw.ts") { return serveRaw(c) }
        if path.hasPrefix("/live.m3u8") {
            if let m = segmenter.playlist() { return reply(c, 200, "application/vnd.apple.mpegurl", Data(m.utf8)) }
            if let f = _failure, segmenter.segments.isEmpty { return reply(c, 502, "text/plain", Data(f.utf8)) }
            if tries > 50 || stopped { return reply(c, 504, "text/plain", Data("No data from the stream.".utf8)) }
            q.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.route(path, c, tries: tries + 1) }
        } else if path.hasPrefix("/seg/"), let n = Int(path.dropFirst(5).prefix { $0.isNumber }), let d = segmenter.segment(n) {
            reply(c, 200, "video/MP2T", d)
        } else {
            reply(c, 404, "text/plain", Data("not found".utf8))
        }
    }

    private func reply(_ c: NWConnection, _ code: Int, _ type: String, _ body: Data) {
        let head = "HTTP/1.1 \(code) \(code == 200 ? "OK" : "Error")\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }
}

final class Once: @unchecked Sendable {
    private var taken = false
    private let lock = NSLock()
    func take() -> Bool { lock.withLock { if taken { return false }; taken = true; return true } }
}
