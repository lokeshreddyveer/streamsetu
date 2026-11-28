import Foundation
import Network

// MARK: pure request and response handling

/// A byte range as the client asked for it. `end` is inclusive; nil means "to the end".
struct MusicByteRange: Equatable, Sendable {
    var start: Int64
    var end: Int64?
    /// Set for "bytes=-N": the last N bytes of the file. `start` is 0 and `end` nil in that case.
    var suffix: Int64? = nil
}

struct MusicProxyRequest: Equatable, Sendable {
    var method: String
    var path: String
    var range: MusicByteRange?
}

enum MusicProxyHTTP {
    /// Parses the request head (everything before the blank line). Returns nil for anything that is not a plain HTTP/1.x request line.
    static func parse(_ head: String) -> MusicProxyRequest? {
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return nil }
        var range: MusicByteRange?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].lowercased() == "range" {
                range = parseRange(String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return MusicProxyRequest(method: String(parts[0]).uppercased(), path: String(parts[1]), range: range)
    }

    /// "bytes=0-99", "bytes=100-", "bytes=0-" and the suffix form "bytes=-500" are understood. With several ranges only the first is used.
    /// Anything unusable returns nil and the whole file is served, which every client accepts.
    static func parseRange(_ value: String) -> MusicByteRange? {
        guard value.lowercased().hasPrefix("bytes=") else { return nil }
        var spec = value.dropFirst(6)
        if let comma = spec.firstIndex(of: ",") { spec = spec[..<comma] }
        spec = spec.drop(while: { $0 == " " })
        guard let dash = spec.firstIndex(of: "-") else { return nil }
        if dash == spec.startIndex {
            guard let n = Int64(spec[spec.index(after: dash)...]), n > 0 else { return nil }
            return MusicByteRange(start: 0, end: nil, suffix: n)
        }
        guard let start = Int64(spec[..<dash]), start >= 0 else { return nil }
        let tail = spec[spec.index(after: dash)...]
        if tail.isEmpty { return MusicByteRange(start: start, end: nil) }
        guard let end = Int64(tail), end >= start else { return nil }
        return MusicByteRange(start: start, end: end)
    }

    /// The absolute first and last byte to send for a request against a file of `total` bytes, or nil when the range starts past the end.
    static func resolve(_ range: MusicByteRange?, total: Int64) -> (start: Int64, end: Int64)? {
        guard total > 0 else { return nil }
        guard let r = range else { return (0, total - 1) }
        if let n = r.suffix { return (max(0, total - n), total - 1) }
        guard r.start < total else { return nil }
        return (r.start, min(r.end ?? (total - 1), total - 1))
    }

    /// "/<token>/<id>.<ext>?x" gives "<id>", but only when the token matches exactly.
    static func registrationID(path: String, token: String) -> String? {
        let clean = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        let prefix = "/" + token + "/"
        guard clean.hasPrefix(prefix) else { return nil }
        let rest = String(clean.dropFirst(prefix.count))
        let id = (rest as NSString).deletingPathExtension
        guard !id.isEmpty, !id.contains("/") else { return nil }
        return id
    }

    /// Upstream "Content-Range: bytes 100-199/1000" gives (100, 199, 1000); total is nil for "*".
    static func parseContentRange(_ value: String) -> (start: Int64, end: Int64, total: Int64?)? {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard v.lowercased().hasPrefix("bytes ") else { return nil }
        let spec = v.dropFirst(6)
        let halves = spec.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard halves.count == 2 else { return nil }
        let ends = halves[0].split(separator: "-")
        guard ends.count == 2, let s = Int64(ends[0]), let e = Int64(ends[1]) else { return nil }
        return (s, e, Int64(halves[1]))
    }

    static func head(status: Int, reason: String, contentType: String? = nil, length: Int64? = nil, contentRange: String? = nil) -> Data {
        var s = "HTTP/1.1 \(status) \(reason)\r\nAccept-Ranges: bytes\r\nConnection: close\r\nCache-Control: no-store\r\n"
        if let contentType { s += "Content-Type: \(contentType)\r\n" }
        if let length { s += "Content-Length: \(length)\r\n" }
        if let contentRange { s += "Content-Range: \(contentRange)\r\n" }
        return Data((s + "\r\n").utf8)
    }

    static func mime(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "mp3": "audio/mpeg"
        case "m4a", "mp4", "aac": "audio/mp4"
        case "flac": "audio/flac"
        case "ogg", "opus": "audio/ogg"
        case "wav": "audio/wav"
        case "webm": "audio/webm"
        default: "application/octet-stream"
        }
    }
}

// MARK: chunking rules (pure)

/// The numbers and decisions behind bounded range fetching.
enum MusicProxyChunker {
    /// Every upstream request asks for at most this many bytes.
    static let chunkBytes: Int64 = 4 * 1_048_576
    /// An upstream read that makes no progress for this long is dead.
    static let stallSeconds: TimeInterval = 20
    /// How long the loopback side waits for the request head.
    static let headerTimeoutSeconds: TimeInterval = 15
    /// Pause after a listener error, so a descriptor shortage does not spin a core.
    static let acceptErrorSleep: TimeInterval = 0.1

    /// The back-to-back windows that cover `start...end`, each at most `chunk` bytes.
    static func windows(start: Int64, end: Int64, chunk: Int64 = chunkBytes) -> [ClosedRange<Int64>] {
        guard start >= 0, end >= start, chunk > 0 else { return [] }
        var out: [ClosedRange<Int64>] = []
        var s = start
        while s <= end {
            let e = min(end, s + chunk - 1)
            out.append(s...e)
            s = e + 1
        }
        return out
    }

    /// A chunk is usable only as a 206 whose body is exactly the requested size.
    static func accepts(status: Int, body: Int, window: ClosedRange<Int64>) -> Bool {
        status == 206 && Int64(body) == window.upperBound - window.lowerBound + 1
    }

    /// Hosts that serve open-ended requests slowly and bounded ones fast.
    static func throttlesOpenRanges(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        return host.hasSuffix("googlevideo.com") || host.hasSuffix("youtube.com") || url.path.contains("/videoplayback")
    }

    /// No proxy for: a user-configured outbound proxy (the loopback address would be sent through it), a live or HLS stream, or a stream
    /// that is not a plain remote file.
    static func shouldBypass(proto: MusicStreamProtocol, url: URL, userProxyActive: Bool) -> Bool {
        if userProxyActive || proto != .progressive { return true }
        return url.scheme != "http" && url.scheme != "https"
    }
}

// MARK: upstream trace

/// What the host answered to the proxy's range requests for one registered address: whether any window was ever served, and the last
/// refusal (status, window, error). The player reads it when a song fails, to tell "the address ran out mid-song" from "this client is capped".
final class MusicUpstreamTrace: @unchecked Sendable {
    struct Failure: Sendable, Equatable {
        var status: Int?
        var errorChain: String?
        var offset: Int64
        var length: Int64?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var recent: [(key: String, trace: MusicUpstreamTrace)] = []
    private static let keep = 8

    /// The newest trace for a track uid (the proxy registers one per stream it relays).
    static func latest(for key: String) -> MusicUpstreamTrace? { lock.withLock { recent.last { $0.key == key }?.trace } }
    static func begin(key: String?, url: String) -> MusicUpstreamTrace {
        let t = MusicUpstreamTrace(url: url)
        if let key { lock.withLock { recent.append((key, t)); if recent.count > keep { recent.removeFirst(recent.count - keep) } } }
        return t
    }
    static func clearAll() { lock.withLock { recent = [] } }

    let addressHash: String
    let hostClass: String
    let client: String?
    private let state = NSLock()
    private var served = 0
    private var lastFailureValue: Failure?
    private let started = Date()

    init(url: String) {
        addressHash = MusicRedaction.shortHash(url); hostClass = MusicRedaction.hostClass(url); client = MusicRedaction.client(url)
    }

    func success() { state.withLock { served += 1 } }
    func failure(status: Int?, error: Error? = nil, offset: Int64, length: Int64? = nil) {
        let chain = error.map { MusicErrorChain.describe($0).chain }
        state.withLock { lastFailureValue = Failure(status: status, errorChain: chain, offset: offset, length: length) }
    }
    var servedWindows: Int { state.withLock { served } }
    var lastFailure: Failure? { state.withLock { lastFailureValue } }

    /// The plain hypothesis for the last refusal (nil when the last problem was not a 403 or 410).
    var hypothesis: String? {
        state.withLock { MusicStreamVerifier.refusalHypothesis(status: lastFailureValue?.status, servedBefore: served > 0) }
    }
}

// MARK: proxy

/// A small loopback-only HTTP server that AVPlayer reads from instead of the real stream. It adds the headers a stream needs, answers
/// range requests the way a player expects, and copies the bytes into the audio cache while they pass through.
///
/// Nothing runs while it is stopped: the listener, the connections and the upstream requests all exist only between `register` and `stop`.
final class MusicStreamProxy: @unchecked Sendable {
    static let maxConnections = 4
    private static let maxRegistrations = 64

    struct Registration: Sendable {
        var url: URL
        var headers: [String: String]
        var cacheKey: String?
        var container: String
        /// Largest byte window asked from the host in one request (per client, see `MusicProxyPolicy`).
        var window: Int64 = MusicProxyChunker.chunkBytes
        /// The start timeline this stream belongs to (the track's uid), for the first-byte stamp.
        var timelineKey: String? = nil
        /// What the host answered to this registration's requests.
        var trace: MusicUpstreamTrace? = nil
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "music.stream.proxy")
    private var listener: NWListener?
    private var port: UInt16?
    private var token = ""
    private var startTask: Task<UInt16?, Never>?
    private var registrations: [String: Registration] = [:]
    private var probes: [String: Probe] = [:]
    private var order: [String] = []
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var cache: MusicAudioCache?
    /// Set once the loopback relay has proved itself for this listener; later registrations skip the proof (a stream that then fails to open is
    /// played directly by the caller, as before).
    private var relayProven = false
    /// Read-ahead for the few most recent registrations (a song that was skipped is dropped, so memory stays bounded).
    private var readAheads: [String: MusicReadAhead] = [:]
    private var readAheadOrder: [String] = []
    static let maxReadAheads = 3

    private func readAhead(for id: String, reg: Registration, total: Int64) -> MusicReadAhead {
        let (ra, dropped): (MusicReadAhead, [MusicReadAhead]) = lock.withLock {
            if let r = readAheads[id] { return (r, []) }
            let blockBytes = MusicProxyPolicy.isGoogleVideo(reg.url) ? MusicBlockGrid().block : min(reg.window, 1_048_576)
            let r = MusicReadAhead(grid: MusicBlockGrid(block: blockBytes, total: total)) { [weak self] range in await self?.fetchChunk(reg, range) }
            readAheads[id] = r
            readAheadOrder.append(id)
            var old: [MusicReadAhead] = []
            while readAheadOrder.count > Self.maxReadAheads { if let x = readAheads.removeValue(forKey: readAheadOrder.removeFirst()) { old.append(x) } }
            return (r, old)
        }
        dropped.forEach { $0.stop() }
        return ra
    }

    /// True while the listener is up.
    var isRunning: Bool { lock.withLock { port != nil } }

    /// Makes a loopback URL for a stream, starting the server if needed. Nil when the server could not start (the caller plays directly).
    func register(_ stream: MusicStream, url: URL, cacheKey: String?, cache: MusicAudioCache?, selfTest: Bool = true, timelineKey: String? = nil) async -> URL? {
        guard let port = await start() else { return nil }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let ext = MusicAudioCache.safeExtension(stream.container)
        let t: String = lock.withLock {
            self.cache = cache
            registrations[id] = Registration(url: url, headers: MusicProxyPolicy.headers(for: url, base: stream.headers), cacheKey: cacheKey,
                                             container: stream.container, window: MusicProxyPolicy.window(for: url), timelineKey: timelineKey,
                                             trace: MusicUpstreamTrace.begin(key: timelineKey, url: url.absoluteString))
            order.append(id)
            while order.count > Self.maxRegistrations { let old = order.removeFirst(); registrations[old] = nil; probes[old] = nil }
            return token
        }
        guard let local = URL(string: "http://127.0.0.1:\(port)/\(t)/\(id).\(ext)") else { return nil }
        // The proxy must prove it can relay this stream before the player is pointed at it; otherwise the caller plays the address directly.
        if selfTest, !lock.withLock({ relayProven }) {
            guard await MusicProxyPolicy.selfTest(local) else {
                lock.withLock { registrations[id] = nil; probes[id] = nil; order.removeAll { $0 == id } }
                return nil
            }
            lock.withLock { relayProven = true }
        }
        if let timelineKey { MusicStartTimeline.shared.mark(timelineKey, .proxyReady) }
        return local
    }

    /// Closes the listener and every connection and upstream request.
    func stop() {
        let (l, conns, work): (NWListener?, [NWConnection], [Task<Void, Never>]) = lock.withLock {
            let r = (listener, Array(connections.values), Array(tasks.values))
            listener = nil; port = nil; startTask = nil; token = ""
            registrations = [:]; probes = [:]; order = []; connections = [:]; tasks = [:]; cache = nil; relayProven = false
            let ahead = Array(readAheads.values); readAheads = [:]; readAheadOrder = []
            ahead.forEach { $0.stop() }
            return r
        }
        work.forEach { $0.cancel() }
        conns.forEach { $0.cancel() }
        l?.cancel()
    }

    /// Brings the listener up ahead of the first stream, so the first song does not wait for it. Cheap and safe to call again.
    /// Also proves the loopback relay with a small local answer (no host involved), so the first song does not pay for the proof.
    func prepare() {
        Task {
            guard let port = await start(), !lock.withLock({ relayProven }) else { return }
            let tok = lock.withLock { token }
            guard !tok.isEmpty, let url = URL(string: "http://127.0.0.1:\(port)/\(tok)/selftest.bin") else { return }
            if await MusicProxyPolicy.selfTest(url) { lock.withLock { relayProven = true } }
        }
    }

    // MARK: starting

    private func start() async -> UInt16? {
        let task: Task<UInt16?, Never> = lock.withLock {
            if let p = port { return Task { p } }
            if let t = startTask { return t }
            let t = Task<UInt16?, Never> { await self.bringUp() }
            startTask = t
            return t
        }
        return await task.value
    }

    private func bringUp() async -> UInt16? {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        guard let l = try? NWListener(using: params) else { lock.withLock { startTask = nil }; return nil }
        let newToken = Self.randomToken()
        let gate = PortGate()
        l.stateUpdateHandler = { state in
            switch state {
            case .ready: gate.resume(l.port?.rawValue)
            case .failed, .cancelled: gate.resume(nil)
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        lock.withLock { token = newToken }
        l.start(queue: queue)
        let p: UInt16? = await withCheckedContinuation { gate.install($0) }
        lock.withLock {
            startTask = nil
            if let p { listener = l; port = p } else { l.cancel() }
        }
        return p
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 18)
        let ok = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
        if !ok { bytes = (0..<18).map { _ in UInt8.random(in: 0...255) } }
        return MusicHash.hex(bytes)
    }

    // MARK: connections

    private func accept(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        guard MusicNetworkPolicy.isLoopback(conn.endpoint) else { conn.cancel(); return }
        let admitted: Bool = lock.withLock {
            guard connections.count < Self.maxConnections else { return false }
            connections[id] = conn
            return true
        }
        guard admitted else {
            conn.start(queue: queue)
            conn.send(content: MusicProxyHTTP.head(status: 503, reason: "Busy", length: 0), completion: .contentProcessed { _ in conn.cancel() })
            return
        }
        conn.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.forget(id) }
        }
        conn.start(queue: queue)
        let work = Task { [weak self] in
            await self?.serve(conn)
            conn.cancel()
        }
        lock.withLock { tasks[id] = work }
    }

    private func forget(_ id: ObjectIdentifier) {
        let t: Task<Void, Never>? = lock.withLock { connections[id] = nil; return tasks.removeValue(forKey: id) }
        t?.cancel()
    }

    // MARK: serving one request

    private func serve(_ conn: NWConnection) async {
        // Cancelling this task makes the sleep throw; only a sleep that ran to the end may close the connection.
        let timeout = Task {
            do { try await Task.sleep(nanoseconds: UInt64(MusicProxyChunker.headerTimeoutSeconds * 1_000_000_000)) } catch { return }
            conn.cancel()
        }
        let headText = await Self.readHead(conn)
        timeout.cancel()
        guard let headText, let req = MusicProxyHTTP.parse(headText) else { await Self.send(conn, MusicProxyHTTP.head(status: 400, reason: "Bad Request", length: 0)); return }
        guard req.method == "GET" || req.method == "HEAD" else {
            await Self.send(conn, MusicProxyHTTP.head(status: 405, reason: "Method Not Allowed", length: 0)); return
        }
        let (tok, regs, cache): (String, [String: Registration], MusicAudioCache?) = lock.withLock { (token, registrations, self.cache) }
        if !tok.isEmpty, req.path == "/\(tok)/selftest.bin" {
            let body = Data(count: 1024)
            _ = await Self.send(conn, MusicProxyHTTP.head(status: 206, reason: "Partial Content", contentType: "application/octet-stream", length: 1024, contentRange: "bytes 0-1023/1024"))
            if req.method == "GET" { _ = await Self.send(conn, body) }
            return
        }
        guard !tok.isEmpty, let id = MusicProxyHTTP.registrationID(path: req.path, token: tok), let reg = regs[id] else {
            await Self.send(conn, MusicProxyHTTP.head(status: 404, reason: "Not Found", length: 0)); return
        }
        await relay(conn, req: req, reg: reg, id: id, cache: cache)
    }

    /// What a one-byte probe taught us about a registration: the file size and its type. Learned once per registration.
    struct Probe: Sendable { var total: Int64; var contentType: String }

    private func probe(_ reg: Registration, id: String) async -> Probe? {
        if let p = lock.withLock({ probes[id] }) { return p }
        // The stream check or the stream list already learned the size and type: no extra round trip to the host.
        if let known = MusicStreamProof.shared.size(of: reg.url.absoluteString) {
            var type = MusicProxyHTTP.mime(forExtension: MusicAudioCache.safeExtension(reg.container))
            if let t = known.contentType, t.lowercased().hasPrefix("audio/") || t.lowercased().hasPrefix("video/") { type = t }
            let p = Probe(total: known.total, contentType: type)
            lock.withLock { probes[id] = p }
            return p
        }
        var up = URLRequest(url: reg.url)
        for (k, v) in reg.headers { up.setValue(v, forHTTPHeaderField: k) }
        up.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        up.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        up.timeoutInterval = MusicProxyChunker.stallSeconds
        let probed: (Data, HTTPURLResponse)?
        do { probed = try await MusicTransfer.data(for: up, maxBytes: 4_096) } catch { reg.trace?.failure(status: nil, error: error, offset: 0, length: 1); probed = nil }
        if let (_, h) = probed, h.statusCode != 206 { reg.trace?.failure(status: h.statusCode, offset: 0, length: 1) }
        guard let (_, http) = probed, http.statusCode == 206,
              let cr = http.value(forHTTPHeaderField: "Content-Range").flatMap(MusicProxyHTTP.parseContentRange), let total = cr.total, total > 0 else { return nil }
        var type = MusicProxyHTTP.mime(forExtension: MusicAudioCache.safeExtension(reg.container))
        if let t = http.value(forHTTPHeaderField: "Content-Type"), t.lowercased().hasPrefix("audio/") || t.lowercased().hasPrefix("video/") { type = t }
        let p = Probe(total: total, contentType: type)
        lock.withLock { probes[id] = p }
        return p
    }

    private func relay(_ conn: NWConnection, req: MusicProxyRequest, reg: Registration, id: String, cache: MusicAudioCache?) async {
        let isHead = req.method == "HEAD"
        // The host throttles open-ended and plain requests to about twice real time but serves bounded ranges at full speed, so the
        // player's request is always answered from back-to-back bounded range requests. A host that ignores ranges is relayed as it is.
        guard let probe = await probe(reg, id: id) else { await relayWhole(conn, req: req, reg: reg, cache: cache); return }
        let total = probe.total
        guard let r = MusicProxyHTTP.resolve(req.range, total: total) else {
            await Self.send(conn, MusicProxyHTTP.head(status: 416, reason: "Range Not Satisfiable", contentRange: "bytes */\(total)")); return
        }
        let ranged = req.range != nil
        let length = r.end - r.start + 1
        let head = MusicProxyHTTP.head(status: ranged ? 206 : 200, reason: ranged ? "Partial Content" : "OK", contentType: probe.contentType,
                                       length: length, contentRange: ranged ? "bytes \(r.start)-\(r.end)/\(total)" : nil)
        var clientAlive = await Self.send(conn, head)
        if isHead || !clientAlive { return }

        // The cache is filled only from a response that carries the whole file from byte zero.
        var writer: MusicCacheWriter?
        if let key = reg.cacheKey, let cache, r.start == 0, r.end == total - 1 { writer = cache.beginWrite(key: key, container: reg.container) }
        var complete = true
        let ahead = readAhead(for: id, reg: reg, total: total)
        var sentOffset = r.start
        // Delivers bytes to the player and the cache; false when nobody wants more.
        func deliver(_ original: Data) async -> Bool {
            // AVFoundation reads the track length of a fragmented MP4 (itag 140) as twice the song; the file's first bytes go out with it cleared.
            var piece = original
            if sentOffset == 0 { MusicMP4Header.neutraliseDurations(in: &piece, fileOffset: 0) }
            sentOffset += Int64(piece.count)
            if let k = reg.timelineKey, !MusicStartTimeline.shared.has(k, .proxyFirstByte), MusicStartTimeline.shared.has(k, .proxyReady) { MusicStartTimeline.shared.mark(k, .proxyFirstByte) }
            if let w = writer, !w.append(piece) { writer = nil; w.abort() }
            if clientAlive { clientAlive = await Self.send(conn, piece) }
            return !(Task.isCancelled || (!clientAlive && writer == nil))
        }
        var pos = r.start
        while pos <= r.end {
            if Task.isCancelled || (!clientAlive && writer == nil) { complete = false; break }
            let index = ahead.grid.index(of: pos)
            let blockRange = ahead.grid.range(of: index)
            let upTo = min(r.end, blockRange.upperBound)
            if let data = await ahead.block(index) {
                // The block is in memory, or arrives as one piece; a player that restarts its request every few hundred kilobytes is served at once.
                let slice = data.subdata(in: Int(pos - blockRange.lowerBound)..<Int(upTo - blockRange.lowerBound) + 1)
                if !(await deliver(slice)) { complete = false; break }
            } else {
                // The block could not be fetched whole: the bytes are relayed as they arrive, and a window that breaks off is asked again once.
                let ok = await streamWindow(reg, pos...upTo, deliver)
                if !ok { complete = false; if clientAlive { conn.cancel() }; break }
            }
            pos = upTo + 1
        }
        if let w = writer { if complete { w.finish(expectedSize: total) } else { w.abort() } }
    }

    /// One bounded range request. Only this chunk is held in memory. The 20 second limit is URLSession's gap-between-packets timer, so a
    /// slow link that keeps delivering is fine and a link that goes silent is declared dead.
    private func fetchChunk(_ reg: Registration, _ w: ClosedRange<Int64>) async -> Data? {
        var up = URLRequest(url: reg.url)
        for (k, v) in reg.headers { up.setValue(v, forHTTPHeaderField: k) }
        up.setValue("bytes=\(w.lowerBound)-\(w.upperBound)", forHTTPHeaderField: "Range")
        up.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        up.timeoutInterval = MusicProxyChunker.stallSeconds
        let got: (Data, HTTPURLResponse)
        do { got = try await MusicTransfer.data(for: up, maxBytes: 16_000_000) } catch {
            reg.trace?.failure(status: nil, error: error, offset: w.lowerBound, length: w.upperBound - w.lowerBound + 1)
            return nil
        }
        let (data, http) = got
        guard MusicProxyChunker.accepts(status: http.statusCode, body: data.count, window: w) else {
            reg.trace?.failure(status: http.statusCode, offset: w.lowerBound, length: w.upperBound - w.lowerBound + 1)
            return nil
        }
        reg.trace?.success()
        return data
    }

    /// One bounded range request relayed piece by piece. Returns false when the host failed twice or the consumer stopped wanting bytes.
    private func streamWindow(_ reg: Registration, _ w: ClosedRange<Int64>, _ deliver: (Data) async -> Bool) async -> Bool {
        var received: Int64 = 0
        let length = w.upperBound - w.lowerBound + 1
        for _ in 0..<2 {
            if Task.isCancelled { return false }
            let from = w.lowerBound + received
            var up = URLRequest(url: reg.url)
            for (k, v) in reg.headers { up.setValue(v, forHTTPHeaderField: k) }
            up.setValue("bytes=\(from)-\(w.upperBound)", forHTTPHeaderField: "Range")
            up.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            up.timeoutInterval = MusicProxyChunker.stallSeconds
            let opened: (URLSession.AsyncBytes, HTTPURLResponse)
            do { opened = try await MusicTransfer.bytes(for: up) } catch { reg.trace?.failure(status: nil, error: error, offset: from, length: w.upperBound - from + 1); continue }
            let (bytes, http) = opened
            guard http.statusCode == 206 else { reg.trace?.failure(status: http.statusCode, offset: from, length: w.upperBound - from + 1); continue }
            reg.trace?.success()
            var buffer = Data()
            buffer.reserveCapacity(32 * 1024)
            do {
                for try await b in bytes {
                    buffer.append(b)
                    if buffer.count >= 32 * 1024 {
                        let piece = buffer; buffer.removeAll(keepingCapacity: true)
                        received += Int64(piece.count)
                        if !(await deliver(piece)) { return false }
                    }
                }
                if !buffer.isEmpty { received += Int64(buffer.count); if !(await deliver(buffer)) { return false } }
            } catch {
                if !buffer.isEmpty { received += Int64(buffer.count); if !(await deliver(buffer)) { return false } }
            }
            if received >= length { return true }
        }
        return false
    }

    /// The fallback for a host that does not answer ranges: pass the response through as it comes.
    private func relayWhole(_ conn: NWConnection, req: MusicProxyRequest, reg: Registration, cache: MusicAudioCache?) async {
        let isHead = req.method == "HEAD"
        var up = URLRequest(url: reg.url)
        for (k, v) in reg.headers { up.setValue(v, forHTTPHeaderField: k) }
        if isHead { up.setValue("bytes=0-0", forHTTPHeaderField: "Range") }
        else if let r = req.range, r.suffix == nil { up.setValue("bytes=\(r.start)-\(r.end.map(String.init) ?? "")", forHTTPHeaderField: "Range") }

        let bytes: URLSession.AsyncBytes
        let http: HTTPURLResponse
        do {
            (bytes, http) = try await MusicTransfer.bytes(for: up)
        } catch {
            reg.trace?.failure(status: nil, error: error, offset: req.range?.start ?? 0)
            await Self.send(conn, MusicProxyHTTP.head(status: 502, reason: "Bad Gateway", length: 0)); return
        }
        guard http.statusCode == 200 || http.statusCode == 206 else {
            reg.trace?.failure(status: http.statusCode, offset: req.range?.start ?? 0)
            let code = http.statusCode == 416 ? 416 : 502
            await Self.send(conn, MusicProxyHTTP.head(status: code, reason: code == 416 ? "Range Not Satisfiable" : "Bad Gateway", length: 0)); return
        }
        var upstreamStart: Int64 = 0
        var total: Int64?
        if http.statusCode == 206, let cr = http.value(forHTTPHeaderField: "Content-Range").flatMap(MusicProxyHTTP.parseContentRange) {
            upstreamStart = cr.start; total = cr.total
        } else if http.expectedContentLength > 0 {
            total = http.expectedContentLength
        }
        let mime = MusicProxyHTTP.mime(forExtension: MusicAudioCache.safeExtension(reg.container))
        if isHead {
            await Self.send(conn, MusicProxyHTTP.head(status: 200, reason: "OK", contentType: mime, length: total ?? 0))
            return
        }
        let wantStart = req.range?.start ?? 0
        var sendStatus = 200
        var sendLength: Int64?
        var rangeHeader: String?
        var lastByte: Int64?
        if let total {
            guard let r = MusicProxyHTTP.resolve(req.range, total: total) else {
                await Self.send(conn, MusicProxyHTTP.head(status: 416, reason: "Range Not Satisfiable", contentRange: "bytes */\(total)")); return
            }
            lastByte = r.end
            sendLength = r.end - r.start + 1
            if req.range != nil { sendStatus = 206; rangeHeader = "bytes \(r.start)-\(r.end)/\(total)" }
        }
        let headData = MusicProxyHTTP.head(status: sendStatus, reason: sendStatus == 206 ? "Partial Content" : "OK", contentType: mime, length: sendLength, contentRange: rangeHeader)
        var clientAlive = await Self.send(conn, headData)
        var writer: MusicCacheWriter?
        if let key = reg.cacheKey, let cache, let total, wantStart == 0, lastByte == total - 1, upstreamStart == 0 {
            writer = cache.beginWrite(key: key, container: reg.container)
        }
        var skip = max(0, wantStart - upstreamStart)
        var remaining = sendLength ?? Int64.max
        var buffer = Data()
        buffer.reserveCapacity(32 * 1024)
        var complete = false
        do {
            for try await byte in bytes {
                if skip > 0 { skip -= 1; continue }
                if remaining <= 0 { break }
                buffer.append(byte)
                remaining -= 1
                if buffer.count >= 32 * 1024 || remaining == 0 {
                    let chunk = buffer; buffer.removeAll(keepingCapacity: true)
                    if let w = writer, !w.append(chunk) { writer = nil; w.abort() }
                    if clientAlive { clientAlive = await Self.send(conn, chunk) }
                    if !clientAlive && writer == nil { break }
                }
                if remaining == 0 { complete = true; break }
            }
            if remaining > 0 && sendLength == nil { complete = true }
            if !buffer.isEmpty {
                if let w = writer, !w.append(buffer) { writer = nil; w.abort() }
                if clientAlive { clientAlive = await Self.send(conn, buffer) }
            }
        } catch {
            complete = false
        }
        if let w = writer {
            if complete { w.finish(expectedSize: total) } else { w.abort() }
        }
    }

    // MARK: NWConnection helpers

    private static func readHead(_ conn: NWConnection) async -> String? {
        var data = Data()
        let end = Data("\r\n\r\n".utf8)
        while data.count < 16 * 1024 {
            let chunk: Data? = await withCheckedContinuation { cont in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { content, _, _, error in
                    cont.resume(returning: error == nil ? content : nil)
                }
            }
            guard let chunk, !chunk.isEmpty else { return nil }
            data.append(chunk)
            if let r = data.range(of: end) { return String(data: data[..<r.lowerBound], encoding: .utf8) }
        }
        return nil
    }

    @discardableResult
    private static func send(_ conn: NWConnection, _ data: Data) async -> Bool {
        await withCheckedContinuation { cont in
            conn.send(content: data, completion: .contentProcessed { error in cont.resume(returning: error == nil) })
        }
    }
}

/// Hands the listener's port to whoever is waiting, exactly once.
private final class PortGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16?, Never>?
    private var result: UInt16??

    func install(_ c: CheckedContinuation<UInt16?, Never>) {
        let ready: UInt16?? = lock.withLock {
            if let r = result { return r }
            continuation = c
            return nil
        }
        if let ready { c.resume(returning: ready) }
    }

    func resume(_ port: UInt16?) {
        let c: CheckedContinuation<UInt16?, Never>? = lock.withLock {
            guard result == nil else { return nil }
            result = .some(port)
            let c = continuation; continuation = nil
            return c
        }
        c?.resume(returning: port)
    }
}
