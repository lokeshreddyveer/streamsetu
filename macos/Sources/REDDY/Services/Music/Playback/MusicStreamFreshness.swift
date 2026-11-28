import Foundation
import CryptoKit

// Rules that keep a failed or expired stream address from being served again: how long a signed address may still be used, a bounded
// memory of addresses that failed, the hook a provider implements to drop its own cached copy, and the redaction used by the failure log.

/// When a signed stream address stops working, read from the stream itself and from the address.
enum MusicStreamExpiry {
    /// An address within this many seconds of its expiry is not used: the song would still be playing when it dies.
    static let safetyMargin: TimeInterval = 60

    /// The expiry written into an address (`expire`, `expires`, `Expires` or `exp`, in seconds or milliseconds since 1970), if it carries one.
    static func urlExpiry(_ url: String) -> Date? {
        guard let items = URLComponents(string: url)?.queryItems else { return nil }
        for name in ["expire", "expires", "Expires", "exp"] {
            guard let raw = items.first(where: { $0.name == name })?.value, let v = Double(raw) else { continue }
            let seconds = v > 100_000_000_000 ? v / 1000 : v
            if seconds > 1_000_000_000 { return Date(timeIntervalSince1970: seconds) }
        }
        return nil
    }

    /// The earlier of the stream's own expiry and the one in its address.
    static func effectiveExpiry(_ s: MusicStream) -> Date? {
        switch (s.expiresAt, urlExpiry(s.url)) {
        case let (a?, b?): return min(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }

    /// How old a YouTube media address is, estimated from its expiry (these addresses live about 5 h 59 min). Nil for any other address.
    static func estimatedAge(of s: MusicStream, now: Date) -> TimeInterval? {
        guard MusicRedaction.hostClass(s.url) == "googlevideo", let e = effectiveExpiry(s) else { return nil }
        return max(0, 21_540 - e.timeIntervalSince(now))
    }

    /// False when the address expires before `now` plus the margin.
    static func isUsable(_ s: MusicStream, now: Date, margin: TimeInterval = safetyMargin) -> Bool {
        guard let e = effectiveExpiry(s) else { return true }
        return e > now.addingTimeInterval(margin)
    }
}

/// Stream addresses that failed, kept for a limited time and in limited number. An address is never remembered for good: a transient failure
/// must not become a verdict, and the set cannot grow without bound.
final class MusicBadAddresses: @unchecked Sendable {
    static let capacity = 256
    static let lifetime: TimeInterval = 10 * 60

    private let lock = NSLock()
    private let now: () -> Date
    private var until: [String: Date] = [:]
    private var order: [String] = []

    init(now: @escaping () -> Date = { Date() }) { self.now = now }

    func insert(_ url: String) {
        lock.withLock {
            let t = now()
            prune(t)
            if until[url] == nil { order.append(url) }
            until[url] = t.addingTimeInterval(Self.lifetime)
            while order.count > Self.capacity { until[order.removeFirst()] = nil }
        }
    }

    func contains(_ url: String) -> Bool {
        lock.withLock {
            guard let e = until[url] else { return false }
            if e <= now() { until[url] = nil; order.removeAll { $0 == url }; return false }
            return true
        }
    }

    /// The live set, for the lanes of one race.
    func snapshot() -> Set<String> {
        lock.withLock { prune(now()); return Set(until.keys) }
    }

    var count: Int { lock.withLock { prune(now()); return until.count } }

    func removeAll() { lock.withLock { until = [:]; order = [] } }

    private func prune(_ t: Date) {
        guard until.values.contains(where: { $0 <= t }) else { return }
        until = until.filter { $0.value > t }
        order = order.filter { until[$0] != nil }
    }
}

/// An audio provider that keeps its own copy of stream addresses (a URL cache, an answer cache) implements this so a failed address can be
/// dropped everywhere before the retry asks it again.
protocol MusicStreamEvicting: MusicAudioProvider {
    /// Forgets every stream this provider holds for the recording, so the next `streams(for:)` is a fresh lookup.
    func evictStreams(for source: MusicAudioSource) async
}

/// What the failure log may keep of an address: the kind of host and a short hash. Never the address, a token or a cookie.
enum MusicRedaction {
    static func hostClass(_ url: String) -> String {
        guard let u = URL(string: url), let host = u.host?.lowercased() else { return url.hasPrefix("/") ? "file" : "unknown" }
        if u.isFileURL { return "file" }
        if host == "127.0.0.1" || host == "localhost" { return "loopback" }
        if host.hasSuffix("googlevideo.com") || host.hasSuffix(".c.youtube.com") { return "googlevideo" }
        if host.hasSuffix("youtube.com") || host.hasSuffix("youtu.be") { return "youtube" }
        return "other"
    }

    /// Eight hex characters of a SHA-256 over the address without its query: enough to tell two addresses apart, useless for rebuilding one.
    static func shortHash(_ url: String) -> String {
        let bare = url.split(separator: "?", maxSplits: 1).first.map(String.init) ?? url
        let digest = SHA256.hash(data: Data(bare.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// The minting client of a YouTube address (`c=`), or nil.
    static func client(_ url: String) -> String? { URL(string: url).flatMap(MusicProxyPolicy.client(of:)) }

    /// Strips anything that looks like an address, a long token or a cookie from free text before it is stored.
    static func scrub(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: #"https?://\S+"#, with: "<address>", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)(cookie|authorization|token|sig|signature|key)=[^\s&;]+"#, with: "$1=<redacted>", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[A-Za-z0-9_\-]{40,}"#, with: "<redacted>", options: .regularExpression)
        return s
    }
}
