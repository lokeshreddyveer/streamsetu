import Foundation

// Decides whether a stream address is really playable before it is handed to the player: it must open, say it is audio, deliver bytes from the
// start AND from the middle of the file (some clients serve only the first mebibyte), and be as long as the song it is supposed to be.

enum MusicProbeVerdict: Equatable, Sendable {
    case ok
    /// The server refused this address or served something that is not audio. The client that minted it should be skipped for a while.
    case refused(String)
    /// The address did not deliver (timeout, other status, too few bytes). Skipped for this attempt only.
    case unreachable(String)
    /// The stream is a preview or cut off compared with the catalogue length.
    case preview(String)

    var isOK: Bool { self == .ok }
    var reason: String {
        switch self {
        case .ok: return ""
        case .refused(let s), .unreachable(let s), .preview(let s): return s
        }
    }
}

/// What one ranged read answered.
struct MusicProbeReading: Sendable, Equatable {
    var status: Int
    var contentType: String?
    /// The full length of the file when the answer said so (Content-Range total, or Content-Length of a 200).
    var total: Int64?
    var bytesRead: Int
}

enum MusicStreamVerifier {
    static let minimumBytes = 16 * 1024
    static let midMinimumBytes = 4 * 1024
    static let readLimit = 32 * 1024
    static let timeout: TimeInterval = 6
    /// The slowest bitrate a real recording is encoded at, used to turn a file size into the longest runtime it can have.
    static let lossyFloorKbps = 64.0
    static let losslessFloorKbps = 200.0
    static let previewSlackSeconds = 10.0
    /// Files shorter than this are probed at the start only.
    static let midProbeMinimumLength: Int64 = 1_500_000

    /// One ranged read: the request is built by the verifier, the reader returns the answer with at most `limit` body bytes counted.
    typealias Reader = @Sendable (_ url: URL, _ headers: [String: String], _ range: String, _ limit: Int) async -> MusicProbeReading?

    // MARK: pure classification

    static func isAudioType(_ type: String?, url: URL?) -> Bool {
        guard let t = type?.lowercased() else { return false }
        if t.hasPrefix("audio/") { return true }
        if t.hasPrefix("application/octet-stream") || t.hasPrefix("binary/octet-stream") {
            let ext = url?.pathExtension.lowercased() ?? ""
            return ["m4a", "mp3", "aac", "flac", "ogg", "opus", "wav", "mp4"].contains(ext)
        }
        return false
    }

    static func classifyFirst(_ r: MusicProbeReading?, url: URL?) -> MusicProbeVerdict {
        guard let r else { return .unreachable("no answer") }
        if [403, 404, 410].contains(r.status) { return .refused("HTTP \(r.status)") }
        if r.status == 416 { return .ok }
        guard (200..<300).contains(r.status) else { return .unreachable("HTTP \(r.status)") }
        if !isAudioType(r.contentType, url: url) { return .refused("not audio (\(r.contentType ?? "no type"))") }
        let small = r.total.map { $0 < Int64(minimumBytes) } ?? false
        if r.bytesRead < minimumBytes, !small { return .unreachable("only \(r.bytesRead) bytes arrived") }
        return .ok
    }

    static func classifyMid(_ r: MusicProbeReading?, url: URL?) -> MusicProbeVerdict {
        guard let r else { return .unreachable("no answer in the middle of the file") }
        if [403, 404, 410].contains(r.status) { return .refused("the middle of the file is refused (HTTP \(r.status))") }
        guard (200..<300).contains(r.status) else { return .unreachable("middle of the file answered HTTP \(r.status)") }
        if !isAudioType(r.contentType, url: url) { return .refused("middle of the file is not audio") }
        if r.bytesRead < midMinimumBytes { return .unreachable("middle of the file delivered \(r.bytesRead) bytes") }
        return .ok
    }

    /// True when a file of `bytes` cannot hold the expected runtime even at the slowest real bitrate.
    static func isTooShort(bytes: Int64?, expectedSeconds: Double?, lossless: Bool, statedKbps: Int? = nil, slackSeconds: Double = previewSlackSeconds) -> Bool {
        guard let bytes, bytes > 0, let expected = expectedSeconds, expected > 0 else { return false }
        var floor = lossless ? losslessFloorKbps : lossyFloorKbps
        if !lossless, let k = statedKbps, k > 0 { floor = min(floor, Double(k)) }
        let longestPossible = Double(bytes) * 8 / (floor * 1000)
        return longestPossible < expected - slackSeconds
    }

    /// After load: the item's real length against the catalogue length. Wrong when it differs by more than 10 s and by more than 10 percent.
    static func durationMismatch(catalogueSeconds: Double, actualSeconds: Double) -> Bool {
        guard catalogueSeconds > 0, actualSeconds > 0 else { return false }
        let d = abs(catalogueSeconds - actualSeconds)
        return d > 10 && d > catalogueSeconds * 0.10
    }

    // MARK: refusal hypothesis

    /// Why a later range of an address was refused, as one plain phrase for the failure log. A 403 or 410 after the same address already served
    /// bytes means the address itself ran out or was revoked; a refusal when only the opening was ever served means that client is capped.
    static func refusalHypothesis(status: Int?, servedBefore: Bool) -> String? {
        guard let status, status == 403 || status == 410 else { return nil }
        return servedBefore ? "address expired or revoked mid-song" : "client capped (opening served, later range refused)"
    }

    /// The HTTP status inside a verdict's reason ("... (HTTP 403)"), if it names one.
    static func status(inReason reason: String) -> Int? {
        guard let r = reason.range(of: #"HTTP (\d{3})"#, options: .regularExpression) else { return nil }
        return Int(reason[r].dropFirst(5))
    }

    // MARK: probing

    /// What the opening read of a stream proved: the verdict plus the size and type it reported (the proxy reuses them).
    struct Start: Sendable, Equatable {
        var verdict: MusicProbeVerdict
        var total: Int64?
        var contentType: String?
    }

    static func probes(_ stream: MusicStream) -> URL? {
        guard stream.proto == .progressive, let url = URL(string: stream.url), url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }

    /// The part of the check that must finish before the song can start: the address opens, says it is audio, delivers bytes and is not a
    /// preview. One ranged read. The size it learns is handed to the proxy so the proxy does not ask for it again.
    static func verifyStart(_ stream: MusicStream, catalogueMs: Int64, reader: Reader = live, proof: MusicStreamProof = .shared) async -> Start {
        guard let url = probes(stream) else { return Start(verdict: .ok) }
        var first = await reader(url, stream.headers, "bytes=0-\(readLimit - 1)", readLimit)
        var v = classifyFirst(first, url: url)
        // A single timeout or short read is asked again once; a refusal (403, not audio) is not.
        if case .unreachable = v {
            first = await reader(url, stream.headers, "bytes=0-\(readLimit - 1)", readLimit)
            v = classifyFirst(first, url: url)
        }
        guard v.isOK, let first else { return Start(verdict: v) }
        if isTooShort(bytes: first.total, expectedSeconds: catalogueMs > 0 ? Double(catalogueMs) / 1000 : nil, lossless: stream.isLossless, statedKbps: stream.bitrate) {
            return Start(verdict: .preview("the stream is much shorter than the song"), total: first.total, contentType: first.contentType)
        }
        if let total = first.total, first.status == 206 { proof.seed(stream.url, size: .init(total: total, contentType: first.contentType)) }
        return Start(verdict: .ok, total: first.total, contentType: first.contentType)
    }

    /// The rest of the check: the middle and the tail of the file (some clients serve only the first mebibyte). Safe to run after playback began.
    static func verifyDeep(_ stream: MusicStream, total: Int64?, reader: Reader = live) async -> MusicProbeVerdict {
        guard let url = probes(stream), let total, total > midProbeMinimumLength else { return .ok }
        let mid = total / 2
        let midRange = "bytes=\(mid)-\(mid + 16_383)", tailRange = "bytes=\(max(0, total - 8_192))-\(total - 1)"
        async let midRead = reader(url, stream.headers, midRange, 16_384)
        async let tailRead = reader(url, stream.headers, tailRange, 8_192)
        var m = classifyMid(await midRead, url: url)
        var t = classifyMid(await tailRead, url: url)
        // One hiccup (a timeout, a short read) is read again once before the address is judged; a refusal is final.
        if case .unreachable = m { m = classifyMid(await reader(url, stream.headers, midRange, 16_384), url: url) }
        if case .unreachable = t { t = classifyMid(await reader(url, stream.headers, tailRange, 8_192), url: url) }
        if !m.isOK { return m }
        if !t.isOK { return t }
        return .ok
    }

    /// Checks a stream completely (start, then middle and tail). Manifests (HLS, DASH) and local files are not probed here.
    static func verify(_ stream: MusicStream, catalogueMs: Int64, reader: Reader = live) async -> MusicProbeVerdict {
        let start = await verifyStart(stream, catalogueMs: catalogueMs, reader: reader)
        guard start.verdict.isOK else { return start.verdict }
        let deep = await verifyDeep(stream, total: start.total, reader: reader)
        if deep.isOK { MusicStreamProof.shared.markPassed(stream.url) }
        return deep
    }

    /// The real reader: a ranged GET through the app's transfer client, read only as far as needed.
    static let live: Reader = { url, headers, range, limit in
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue(range, forHTTPHeaderField: "Range")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        req.timeoutInterval = timeout
        let request = req
        do {
            return try await withTimeout(timeout + 2) {
                let (bytes, http) = try await MusicTransfer.bytes(for: request)
                var n = 0
                if (200..<300).contains(http.statusCode) {
                    for try await _ in bytes { n += 1; if n >= limit { break } }
                }
                var total: Int64?
                if let cr = http.value(forHTTPHeaderField: "Content-Range").flatMap(MusicProxyHTTP.parseContentRange) { total = cr.total }
                else if http.statusCode == 200, http.expectedContentLength > 0 { total = http.expectedContentLength }
                return MusicProbeReading(status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type"), total: total, bytesRead: n)
            }
        } catch { return nil }
    }

    private static func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); throw MusicError.network("timed out") }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw MusicError.network("no answer") }
            return first
        }
    }
}

/// Remembers, per video and client, that a client's address was refused, and per video that a track can never play here.
final class MusicUnplayableMemory: @unchecked Sendable {
    static let memory: TimeInterval = 10 * 60
    static let shared = MusicUnplayableMemory()

    /// Why a recording cannot be played, in words a person can read.
    enum Verdict: String, Sendable, Equatable {
        case ageRestricted, regionLocked, premiumOnly, privateVideo, removed, paid
        var text: String {
            switch self {
            case .ageRestricted: return "This video is age-restricted."
            case .regionLocked: return "This song is not available in your country."
            case .premiumOnly: return "This song needs a paid music subscription."
            case .privateVideo: return "This video is private."
            case .removed: return "This video has been removed."
            case .paid: return "This is paid content."
            }
        }
    }

    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var verdicts: [String: (Verdict, Date)] = [:]
    private var excluded: [String: Date] = [:]
    /// Stream addresses that were handed out and then failed during playback; they are never served from a cache again (until they age out).
    private var badURLs: [String: Date] = [:]
    /// The video each bad address belongs to, so playing the video again on purpose forgives them.
    private var badURLVideo: [String: String] = [:]
    /// How long a client stays excluded for a video after one refusal or playback failure. Short on purpose: the refusal may be a passing hiccup.
    static let clientExclusion: TimeInterval = 2 * 60
    /// No table holds more than this many entries; the oldest go first.
    static let capacity = 256

    init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    /// Drops what has run out and trims each table to its capacity. Called under the lock by every writer.
    private func prune() {
        let t = now()
        if verdicts.count >= Self.capacity / 2 { verdicts = verdicts.filter { $0.value.1 > t } }
        if excluded.count >= Self.capacity / 2 { excluded = excluded.filter { $0.value > t } }
        if badURLs.count >= Self.capacity / 2 { badURLs = badURLs.filter { $0.value > t }; badURLVideo = badURLVideo.filter { badURLs[$0.key] != nil } }
        if verdicts.count > Self.capacity { for k in verdicts.sorted(by: { $0.value.1 < $1.value.1 }).prefix(verdicts.count - Self.capacity).map(\.key) { verdicts[k] = nil } }
        if excluded.count > Self.capacity { for k in excluded.sorted(by: { $0.value < $1.value }).prefix(excluded.count - Self.capacity).map(\.key) { excluded[k] = nil } }
        if badURLs.count > Self.capacity {
            for k in badURLs.sorted(by: { $0.value < $1.value }).prefix(badURLs.count - Self.capacity).map(\.key) { badURLs[k] = nil; badURLVideo[k] = nil }
        }
    }

    func remember(_ v: Verdict, videoID: String) { lock.withLock { prune(); verdicts[videoID] = (v, now().addingTimeInterval(Self.memory)) } }

    func verdict(videoID: String) -> Verdict? {
        lock.withLock {
            guard let e = verdicts[videoID] else { return nil }
            if e.1 <= now() { verdicts[videoID] = nil; return nil }
            return e.0
        }
    }

    func exclude(client: String, videoID: String, for seconds: TimeInterval = MusicUnplayableMemory.clientExclusion) {
        lock.withLock { prune(); excluded[client + "|" + videoID] = now().addingTimeInterval(seconds) }
    }

    func markBadURL(_ url: String, videoID: String? = nil) {
        lock.withLock {
            prune()
            badURLs[url] = now().addingTimeInterval(Self.memory)
            if let videoID { badURLVideo[url] = videoID }
        }
    }

    func isBadURL(_ url: String) -> Bool {
        lock.withLock {
            guard let t = badURLs[url] else { return false }
            if t <= now() { badURLs[url] = nil; badURLVideo[url] = nil; return false }
            return true
        }
    }

    /// Forgets every verdict, exclusion and bad address of one video (the person pressed play again on purpose).
    func forgive(videoID: String) {
        lock.withLock {
            verdicts[videoID] = nil
            for k in excluded.keys where k.hasSuffix("|" + videoID) { excluded[k] = nil }
            for (u, v) in badURLVideo where v == videoID { badURLs[u] = nil; badURLVideo[u] = nil }
        }
    }

    /// The video played: whatever was held against it (a verdict, a parked client) was wrong or has passed. The failed addresses stay on their own clock.
    func noteSuccess(videoID: String) {
        lock.withLock {
            verdicts[videoID] = nil
            for k in excluded.keys where k.hasSuffix("|" + videoID) { excluded[k] = nil }
        }
    }

    /// The person asked to search again, the network changed or the app came back to the front: nothing negative is carried over.
    func resetAll() { lock.withLock { verdicts = [:]; excluded = [:]; badURLs = [:]; badURLVideo = [:] } }

    /// Sizes of the three tables (for tests that check the memory stays bounded).
    var sizes: (verdicts: Int, excluded: Int, badURLs: Int) { lock.withLock { (verdicts.count, excluded.count, badURLs.count) } }

    func isExcluded(client: String, videoID: String) -> Bool {
        lock.withLock {
            let k = client + "|" + videoID
            guard let t = excluded[k] else { return false }
            if t <= now() { excluded[k] = nil; return false }
            return true
        }
    }

    /// Reads a player response's playability status and reason into a permanent verdict. Plain "needs a sign-in" and bot checks are NOT permanent.
    static func classify(status: String, reason: String?) -> Verdict? {
        let r = (reason ?? "").lowercased()
        if r.contains("private video") || r.contains("this video is private") { return .privateVideo }
        if r.contains("premium") { return .premiumOnly }
        if r.contains("country") || r.contains("region") || r.contains("not available in your") || r.contains("geo") { return .regionLocked }
        if r.contains("removed") || r.contains("terminated") || r.contains("no longer available") || r.contains("been deleted") { return .removed }
        if r.contains("rent") || r.contains("purchase") || r.contains("paid content") { return .paid }
        if status == "AGE_VERIFICATION_REQUIRED" || status == "AGE_CHECK_REQUIRED" || r.contains("age-restricted") || r.contains("age restricted") || r.contains("confirm your age") { return .ageRestricted }
        if status == "UNPLAYABLE", r.contains("unavailable") { return .removed }
        return nil
    }
}
