import Foundation
import Network

/// Splits a raw MPEG-TS live stream into HLS-style segments. Pure value logic (no I/O), so it can be tested with
/// synthetic packets. Segments start on a video keyframe (random-access indicator) and are prefixed with the PAT/PMT
/// so each one is independently decodable.
struct TSSegmenter: Sendable {
    struct Segment: Sendable { let seq: Int; let data: Data; let duration: Double }

    var minSegment = 2.0
    var maxSegment = 8.0
    var keep = 8

    private(set) var segments: [Segment] = []
    private(set) var nextSeq = 0
    private(set) var videoPID = -1
    private(set) var droppedBytes = 0
    private var carry = Data()
    private var pat: Data?, pmt: Data?
    private var pmtPID = -1
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
        let pid = (Int(p[1] & 0x1F) << 8) | Int(p[2])
        let pusi = p[1] & 0x40 != 0
        let afc = (p[3] >> 4) & 3
        var payload = 4
        if afc & 2 != 0 { payload += 1 + Int(p[4]) }
        let hasPayload = afc & 1 != 0 && payload < 188

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
                while i + 5 <= end {
                    let type = p[i]
                    let epid = (Int(p[i + 1] & 0x1F) << 8) | Int(p[i + 2])
                    let esInfo = (Int(p[i + 3] & 0x0F) << 8) | Int(p[i + 4])
                    if [0x01, 0x02, 0x10, 0x1B, 0x24].contains(type) { videoPID = epid; break }
                    i += 5 + esInfo
                }
            }
        }

        guard let pat, let pmt, videoPID >= 0 else { return }       // wait for the stream tables

        if pid == videoPID, pusi {
            let rai = afc & 2 != 0 && p[4] > 0 && (p[5] & 0x40) != 0
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

/// Republishes a raw MPEG-TS live stream as a rolling HLS playlist on localhost, so AVPlayer can play it.
/// Many IPTV panels only serve `.ts`; AVFoundation only understands HLS.
final class TSBridge: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let source: URL
    private let q = DispatchQueue(label: "app.reddy.tsbridge")
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var listener: NWListener?
    private var stopped = false
    private var segmenter = TSSegmenter()
    private var _failure: String?
    private var _status: Int?

    var failure: String? { q.sync { _failure } }
    /// HTTP status of the upstream stream request, once known.
    var httpStatus: Int? { q.sync { _status } }

    private let headers: [String: String]

    init(source: URL, headers: [String: String] = [:]) {
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
        return URL(string: "http://127.0.0.1:\(port)/live.m3u8")!
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
            _status = h.statusCode
            if h.statusCode != 200 { _failure = "The server refused the stream (HTTP \(h.statusCode))."; completionHandler(.cancel); return }
        }
        completionHandler(.allow)
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { segmenter.ingest(data) }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if !stopped, _failure == nil { _failure = error?.localizedDescription ?? "The stream ended." }
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

    private func route(_ path: String, _ c: NWConnection, tries: Int) {
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

private final class Once: @unchecked Sendable {
    private var taken = false
    private let lock = NSLock()
    func take() -> Bool { lock.withLock { if taken { return false }; taken = true; return true } }
}
