import Foundation

/// Notices when a lyrics source is blocked or down (401, 403, 410, 429, 5xx, a challenge page) even though its adapter turned the reply
/// into "no lyrics". The lookup then counts that source as failed instead of as a real "not found", so a dead source can never cause a
/// miss to be remembered.
final class MusicLyricsProbe: @unchecked Sendable {
    @TaskLocal static var current: MusicLyricsProbe?
    private let lock = NSLock()
    private var failed = false
    func markFailed() { lock.lock(); failed = true; lock.unlock() }
    var didFail: Bool { lock.lock(); defer { lock.unlock() }; return failed }

    static func isHardFailure(status: Int) -> Bool { [401, 403, 410, 429].contains(status) || status >= 500 }
}

/// Wraps a transport and reports hard failures to the probe of the lookup that made the request.
struct MusicLyricsRecordingTransport: MusicHTTPTransport {
    let inner: MusicHTTPTransport
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (d, r) = try await inner.data(for: request)
            if MusicLyricsProbe.isHardFailure(status: r.statusCode) { MusicLyricsProbe.current?.markFailed() }
            return (d, r)
        } catch {
            MusicLyricsProbe.current?.markFailed()
            throw error
        }
    }
}

/// Per source: how many lookups in a row failed hard. After three the source is left out for the rest of the session.
@MainActor
final class MusicLyricsHealth {
    static let threshold = 3
    private var streak: [String: Int] = [:]

    private var downSince: [String: Date] = [:]
    /// A source marked down is tried again after this long (one probe: another failure marks it down again), so a bad minute never silences it for the whole session.
    static let coolOff: TimeInterval = 90

    func isDown(_ id: String, now: Date = Date()) -> Bool {
        guard (streak[id] ?? 0) >= Self.threshold else { return false }
        if let t = downSince[id], now.timeIntervalSince(t) >= Self.coolOff { streak[id] = Self.threshold - 1; downSince[id] = nil; return false }
        return true
    }
    func recordFailure(_ id: String, now: Date = Date()) {
        streak[id, default: 0] += 1
        if (streak[id] ?? 0) >= Self.threshold, downSince[id] == nil { downSince[id] = now }
    }
    func recordAnswer(_ id: String) { streak[id] = 0; downSince[id] = nil }
    /// A person asking for a source by hand gives it another chance.
    func reset(_ id: String) { streak[id] = 0; downSince[id] = nil }
}
