import Foundation
import Observation

/// One playback failure as the person sees it in Music Settings. It holds a song name and a plain reason, never an address or an identifier.
struct MusicPlaybackFailure: Identifiable, Equatable, Sendable {
    let id = UUID()
    var track: String
    var provider: String
    var reason: String
    var at: Date
}

/// The cause chain of an error as plain text, and the HTTP status when one is inside it.
enum MusicErrorChain {
    /// "AVFoundationErrorDomain -11800 > NSURLErrorDomain -1005": the error, then each underlying error. Domain and code only, never a message
    /// (a message can carry an address).
    static func describe(_ error: Error) -> (chain: String, status: Int?) {
        if let m = error as? MusicError { return ("MusicError." + String(String(describing: m).prefix(40).split(separator: "(").first ?? ""), nil) }
        var parts: [String] = []
        var status: Int?
        var current: NSError? = error as NSError
        var depth = 0
        while let e = current, depth < 6 {
            parts.append("\(e.domain) \(e.code)")
            // The two CoreMedia codes AVPlayer uses for a refused or missing address; every other status comes from the proxy's own trace.
            if status == nil, e.domain == "CoreMediaErrorDomain" { status = [-12660: 403, -12938: 404][e.code] }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return (parts.joined(separator: " > "), status)
    }
}

/// Where in the path to the speaker a failure happened.
enum MusicFailureStage: String, Codable, Sendable, CaseIterable {
    case resolve = "resolve"
    case verify = "verify"
    case proxy = "proxy"
    case playerItem = "AVPlayer item"
    case stall = "mid-song stall"
    case lateRejection = "late rejection"
    case preload = "preload"
    case priming = "crossfade priming"
    case opus = "Opus backend"
    case download = "download"
    case localFile = "local file"
}

/// One playback failure with everything needed to explain it afterwards, and nothing that could be used to replay it: no address, token or cookie,
/// only the kind of host and a short hash.
struct MusicFailureRecord: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var at: Date
    var track: String
    var provider: String
    var stage: MusicFailureStage
    /// The plain sentence a person reads.
    var reason: String
    /// Error domain and code of the cause and of each underlying error.
    var errorChain: String?
    /// HTTP status of the failing range request (from the proxy or the verifier).
    var httpStatus: Int?
    /// Which window of the file failed ("offset 1048576, 524288 bytes").
    var window: String?
    /// The YouTube client that minted the address (`c=`).
    var client: String?
    var hostClass: String?
    var addressHash: String?
    var secondsIn: Double?
    /// "online", "offline" or "unknown".
    var network: String?
    /// "proxy", "direct", "file", "opus" or "cache file".
    var route: String?
    /// True when the stream came from the resolver's cache or a pre-resolve; with its age in seconds.
    var fromCache: Bool?
    var cacheAgeSeconds: Double?
    /// What the failure ladder did next ("retry", "skip", "stay", ...).
    var decision: String?
    /// The check's guess at the cause ("address expired or revoked mid-song", "client capped ...").
    var hypothesis: String?
}

/// The last few playback failures. The short list the person sees in Music Settings is kept in memory; a longer redacted ring (the last 50, with
/// the stage, the error codes and the ladder decision) is kept on disk so a failure that happened last night can still be explained. Nothing is
/// sent anywhere, and a stored record never holds an address.
@MainActor @Observable
final class MusicPlaybackLog {
    static let capacity = 20
    static let failureCapacity = 50
    static let shared = MusicPlaybackLog(persistAt: MusicPlaybackLog.defaultStoreURL)

    nonisolated static var defaultStoreURL: URL { MusicStorage.root.appendingPathComponent("playback-failures.json") }

    private(set) var entries: [MusicPlaybackFailure] = []
    /// Newest first, at most `failureCapacity`.
    private(set) var failures: [MusicFailureRecord] = []
    @ObservationIgnored private let storeURL: URL?

    init(persistAt url: URL? = nil) {
        storeURL = url
        if let url, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([MusicFailureRecord].self, from: data) {
            failures = Array(saved.prefix(Self.failureCapacity))
        }
    }

    func record(track: String, provider: String?, reason: String, at: Date = Date()) {
        let entry = MusicPlaybackFailure(track: Self.clip(track, 80), provider: provider.map { Self.clip($0, 40) } ?? "Unknown", reason: Self.clip(reason, 160), at: at)
        entries.insert(entry, at: 0)
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
    }

    /// Adds one detailed failure. Free text is scrubbed of anything that looks like an address or a token before it is stored.
    func recordFailure(_ r: MusicFailureRecord) {
        var r = r
        r.track = Self.clip(MusicRedaction.scrub(r.track), 80)
        r.provider = Self.clip(MusicRedaction.scrub(r.provider), 40)
        r.reason = Self.clip(MusicRedaction.scrub(r.reason), 160)
        r.errorChain = r.errorChain.map { Self.clip(MusicRedaction.scrub($0), 160) }
        r.hypothesis = r.hypothesis.map { Self.clip(MusicRedaction.scrub($0), 120) }
        failures.insert(r, at: 0)
        if failures.count > Self.failureCapacity { failures.removeLast(failures.count - Self.failureCapacity) }
        persist()
    }

    func clear() {
        entries = []
        failures = []
        if let storeURL { try? FileManager.default.removeItem(at: storeURL) }
    }

    private func persist() {
        guard let storeURL else { return }
        let snapshot = failures
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: storeURL, options: .atomic)
        }
    }

    /// The redacted text a person can copy and paste into a report: one line per failure, newest first.
    func diagnosticsText(now: Date = Date()) -> String {
        Self.diagnostics(failures, now: now)
    }

    nonisolated static func diagnostics(_ items: [MusicFailureRecord], now: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        var lines = ["Music playback diagnostics (addresses are replaced by a host kind and a short hash)", "Created: " + f.string(from: now), "Failures: \(items.count)"]
        for r in items {
            var parts = [f.string(from: r.at), "\"" + r.track + "\"", r.provider, "stage=" + r.stage.rawValue]
            if let e = r.errorChain { parts.append("error=" + e) }
            if let h = r.httpStatus { parts.append("http=\(h)") }
            if let w = r.window { parts.append("window=" + w) }
            if let c = r.client { parts.append("client=" + c) }
            if let h = r.hostClass { parts.append("host=" + h + (r.addressHash.map { "#" + $0 } ?? "")) }
            if let s = r.secondsIn { parts.append(String(format: "at=%.0fs", s)) }
            if let n = r.network { parts.append("net=" + n) }
            if let route = r.route { parts.append("route=" + route) }
            if let c = r.fromCache { parts.append(c ? "cached(age=\(Int(r.cacheAgeSeconds ?? 0))s)" : "fresh") }
            if let d = r.decision { parts.append("decision=" + d) }
            if let h = r.hypothesis { parts.append("likely=" + h) }
            parts.append("reason=" + r.reason)
            lines.append(parts.joined(separator: " | "))
        }
        return lines.joined(separator: "\n")
    }

    /// Where the time went between pressing play on a track and hearing it (stage by stage), for the matrix report and diagnostics.
    func startTimeline(for uid: String) -> MusicStartReport? { MusicStartTimeline.shared.report(uid) }

    nonisolated static func clip(_ s: String, _ n: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= n ? t : String(t.prefix(n - 1)) + "…"
    }
}

/// Remembers which providers failed lately. A provider with three failures inside the window is asked last until it answers once.
final class MusicProviderHealth: @unchecked Sendable {
    static let threshold = 3
    static let window: TimeInterval = 15 * 60
    private let lock = NSLock()
    private var failures: [String: [Date]] = [:]
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    func recordFailure(_ id: String) {
        let t = now()
        lock.withLock { failures[id] = (failures[id] ?? []).filter { t.timeIntervalSince($0) < Self.window } + [t] }
    }
    func recordSuccess(_ id: String) { lock.withLock { failures[id] = nil } }
    /// The network changed or the app came back: no provider is held against its earlier failures.
    func reset() { lock.withLock { failures = [:] } }
    func isDegraded(_ id: String) -> Bool {
        let t = now()
        return lock.withLock { (failures[id] ?? []).filter { t.timeIntervalSince($0) < Self.window }.count >= Self.threshold }
    }
    /// Healthy providers first, each group keeping the person's order.
    func ordered<T>(_ items: [T], id: (T) -> String) -> [T] {
        items.filter { !isDegraded(id($0)) } + items.filter { isDegraded(id($0)) }
    }
}
