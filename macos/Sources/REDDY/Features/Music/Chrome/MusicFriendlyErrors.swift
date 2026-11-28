import Foundation
import Observation

/// One rule for how a failure is worded to the person: a dead network gets one friendly sentence, anything else keeps its own text.
enum MusicFriendlyErrors {
    static let unreachable = "Can't reach the music service. Check your connection."
    static let offlineTitle = "No connection"
    static let genericTitle = "Something went wrong"

    /// Fragments that mean the network itself failed (lower case).
    static let networkFragments: [String] = [
        "error sending request", "error trying to connect", "error reading a body", "error decoding response body", "connect error", "dns error",
        "failed to lookup address", "lookup address", "name or service not known", "nodename nor servname", "connection refused", "connection reset",
        "connection timed out", "timed out", "network is unreachable", "host is unreachable", "no route to host", "could not connect to the server",
        "not connected to the internet", "network connection was lost", "hostname could not be found", "internet connection appears to be offline",
        "unreachable", "secure connection to the server cannot be made"
    ]

    static func isNetworkShaped(_ text: String) -> Bool {
        let t = text.lowercased()
        return networkFragments.contains { t.contains($0) }
    }

    /// Rewrites a raw message. A caller's own prefix ("Loading Home: <transport text>") is kept and only the transport part is replaced.
    static func rewrite(_ raw: String) -> String {
        guard isNetworkShaped(raw) else { return raw }
        let parts = raw.components(separatedBy: ": ")
        guard parts.count > 1 else { return unreachable }
        let prefix = parts.prefix { !isNetworkShaped($0) }
        return prefix.isEmpty ? unreachable : prefix.joined(separator: ": ") + ": " + unreachable
    }

    /// True when the failure means there is no usable connection.
    static func isOffline(_ error: Error) -> Bool {
        if let u = error as? URLError { return offlineCodes.contains(u.code) }
        if let m = error as? MusicError, case .network(let s) = m { return isNetworkShaped(s) }
        return isNetworkShaped(error.localizedDescription)
    }

    static let offlineCodes: Set<URLError.Code> = [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .timedOut, .dnsLookupFailed, .secureConnectionFailed, .internationalRoamingOff, .dataNotAllowed]

    static func message(for error: Error) -> String {
        if error is CancellationError { return "Cancelled." }
        if isOffline(error) { return unreachable }
        if let m = error as? MusicError { return rewrite(m.errorDescription ?? genericTitle) }
        return rewrite(error.localizedDescription)
    }
}

/// How long to wait before each automatic retry while offline: 2, 4, 8, 15, then 30 seconds. A quiet spell of five minutes starts the ladder over.
struct MusicRetryLadder: Sendable, Equatable {
    static let steps: [TimeInterval] = [2, 4, 8, 15, 30, 30, 30, 30, 30, 30]
    static let quietReset: TimeInterval = 300

    private(set) var attempt = 0
    private(set) var lastAt: Date?

    /// The wait before the next try, or nil when the ladder is spent.
    mutating func next(now: Date) -> TimeInterval? {
        if let last = lastAt, now.timeIntervalSince(last) >= Self.quietReset { attempt = 0 }
        guard attempt < Self.steps.count else { return nil }
        defer { attempt += 1; lastAt = now }
        return Self.steps[attempt]
    }

    mutating func reset() { attempt = 0; lastAt = nil }
}

/// Retries a failed page by itself while the device is offline. Each rung checks the connection first and only retries when it is back, so a page does
/// not flip between loading and failed on every rung. The clock and the sleep are injected so tests run instantly.
@MainActor @Observable
final class MusicOfflineRetry {
    private(set) var ladder = MusicRetryLadder()
    private(set) var waiting = false
    private(set) var nextIn: TimeInterval?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let isOnline: @MainActor () -> Bool
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async -> Void
    @ObservationIgnored private let now: @Sendable () -> Date

    init(isOnline: @escaping @MainActor () -> Bool = { true },
         sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.isOnline = isOnline; self.sleep = sleep; self.now = now
    }

    /// Follows the app's `NetworkWatch`, the one monitor the app has.
    convenience init(watch: NetworkWatch) {
        self.init(isOnline: { [weak watch] in watch?.isOnline ?? true })
    }

    /// Starts the ladder. `retry` runs when a rung finds the connection back; it should reload the page.
    func arm(retry: @escaping @MainActor () -> Void) {
        task?.cancel()
        waiting = true
        task = Task { [weak self] in
            while let self, !Task.isCancelled {
                guard let wait = self.step() else { self.finish(); return }
                self.nextIn = wait
                await self.sleep(wait)
                if Task.isCancelled { return }
                if self.isOnline() { self.finish(); retry(); return }
            }
        }
    }

    private func step() -> TimeInterval? {
        var l = ladder
        let w = l.next(now: now())
        ladder = l
        return w
    }

    private func finish() { waiting = false; nextIn = nil }

    func cancel() { task?.cancel(); task = nil; finish() }
    func reset() { cancel(); ladder.reset() }
}
