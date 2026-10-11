import Foundation

enum ChannelHealth: Equatable, Sendable {
    /// Answered with data. `slow` answered, but only after several seconds.
    case ok(ms: Int), slow(ms: Int)
    /// Sent nothing within the time allowed, twice. Not proof the channel is gone: some providers take a long time to start a
    /// stream, or refuse a second connection while one is open. Never counted as dead.
    case silent
    /// A definite failure: an error status, an unknown host, a refused connection, or something that isn't video.
    case dead(String)
    var isDead: Bool { if case .dead = self { true } else { false } }
    var isSlow: Bool { if case .slow = self { true } else { false } }
    var isSilent: Bool { if case .silent = self { true } else { false } }
    var label: String {
        switch self {
        case .ok(let ms): "OK · \(ms) ms"
        case .slow(let ms): "Slow · \(ms) ms"
        case .silent: "No answer in time"
        case .dead(let why): why
        }
    }
}

struct ChannelHealthResult: Identifiable, Equatable, Sendable {
    let channelID: String
    let name: String
    let category: String?
    let health: ChannelHealth
    var id: String { channelID }
}

/// Checks whether channels answer, so dead ones can be found and hidden. It asks each channel for its first few kilobytes and
/// stops, a few channels at a time and only when the person asks. Addresses never leave this class: a result carries the
/// channel's name and a short reason, never the stream URL or login.
final class ChannelHealthService: Sendable {
    static let slowAfterMs = 3000
    private let resolveURL: @Sendable (Channel) throws -> URL
    private let timeouts: (first: TimeInterval, second: TimeInterval)
    private let session: URLSession

    private let resolveHeaders: @Sendable (Channel) -> [String: String]

    convenience init(resolver: StreamResolver) {
        self.init(resolveURL: { try resolver.resolve(channel: $0).url }, resolveHeaders: { (try? resolver.resolve(channel: $0).headers) ?? [:] })
    }

    init(resolveURL: @escaping @Sendable (Channel) throws -> URL, resolveHeaders: @escaping @Sendable (Channel) -> [String: String] = { _ in [:] },
         timeouts: (first: TimeInterval, second: TimeInterval) = (10, 25)) {
        self.resolveURL = resolveURL; self.resolveHeaders = resolveHeaders; self.timeouts = timeouts
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 25; c.timeoutIntervalForResource = 40
        c.httpAdditionalHeaders = ["User-Agent": "VLC/3.0.20 LibVLC/3.0.20"]
        session = URLSession(configuration: c)
    }

    /// Checks `channels` with at most `concurrency` requests in flight (default 2, because many providers allow only one or two
    /// connections per login). `progress` reports how many have finished. Cancelling the task stops promptly.
    func check(_ channels: [Channel], concurrency: Int = 2, progress: @escaping @Sendable (Int, Int) -> Void) async -> [ChannelHealthResult] {
        var results: [ChannelHealthResult] = []
        var done = 0
        let total = channels.count
        await withTaskGroup(of: ChannelHealthResult?.self) { group in
            var iterator = channels.makeIterator()
            func addNext() -> Bool {
                guard !Task.isCancelled, let ch = iterator.next() else { return false }
                group.addTask { [self] in
                    guard !Task.isCancelled else { return nil }
                    return ChannelHealthResult(channelID: ch.id, name: ch.name, category: ch.categoryName, health: await probe(ch))
                }
                return true
            }
            for _ in 0..<max(1, concurrency) { _ = addNext() }
            while let r = await group.next() {
                if let r { results.append(r); done += 1; progress(done, total) }
                _ = addNext()
            }
        }
        return results
    }

    /// Asks twice before giving up on silence: a short wait first, then a long one, because many providers need many seconds to
    /// start a stream. Silence after both is reported as "no answer", never as dead.
    private func probe(_ ch: Channel) async -> ChannelHealth {
        let first = await attempt(ch, timeout: timeouts.first)
        guard first.isSilent, !Task.isCancelled else { return first }
        return await attempt(ch, timeout: timeouts.second)
    }

    private func attempt(_ ch: Channel, timeout: TimeInterval) async -> ChannelHealth {
        guard let url = try? resolveURL(ch) else { return .dead("Can't build its address") }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
        for (k, v) in resolveHeaders(ch) { req.setValue(v, forHTTPHeaderField: k) }
        let started = Date()
        do {
            let (bytes, response) = try await session.bytes(for: req)
            guard let http = response as? HTTPURLResponse else { return .dead("No HTTP answer") }
            guard (200...299).contains(http.statusCode) else { return .dead(Self.reason(forStatus: http.statusCode)) }
            var head = Data()
            for try await b in bytes {
                head.append(b)
                if head.count >= 1024 { break }
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            return Self.classify(statusOK: true, head: head, contentType: http.value(forHTTPHeaderField: "Content-Type"), ms: ms)
        } catch is CancellationError {
            return .dead("Cancelled")
        } catch {
            if (error as? URLError)?.code == .timedOut { return .silent }
            return .dead(Self.reason(for: error))
        }
    }

    // MARK: pure rules (tested)

    static func classify(statusOK: Bool, head: Data, contentType: String?, ms: Int) -> ChannelHealth {
        guard statusOK else { return .dead("Bad answer") }
        guard !head.isEmpty else { return .dead("Empty answer") }
        let text = String(decoding: head.prefix(64), as: UTF8.self)
        let type = (contentType ?? "").lowercased()
        // A web page or an error message where video should be
        if type.contains("text/html") || text.lowercased().hasPrefix("<!doctype html") || text.lowercased().hasPrefix("<html") { return .dead("Returned a web page") }
        return ms > slowAfterMs ? .slow(ms: ms) : .ok(ms: ms)
    }

    static func reason(forStatus code: Int) -> String {
        switch code {
        case 401, 403: "Not allowed (\(code))"
        case 404: "Not found (404)"
        case 429: "Provider limited the connection (429)"
        case 458, 509: "Connection limit reached (\(code))"
        case 500...599: "Provider error (\(code))"
        default: "HTTP \(code)"
        }
    }

    static func reason(for error: Error) -> String {
        guard let e = error as? URLError else { return "Failed" }
        switch e.code {
        case .timedOut: return "No answer in time"
        case .cannotFindHost, .dnsLookupFailed: return "Host not found"
        case .cannotConnectToHost, .networkConnectionLost: return "Couldn't connect"
        case .notConnectedToInternet: return "No internet"
        case .secureConnectionFailed, .serverCertificateUntrusted: return "Secure connection failed"
        default: return "Failed"
        }
    }
}
