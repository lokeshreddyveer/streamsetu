import Foundation

/// A cached answer for one file, found by its identity (path, size and modification time), so a file is fingerprinted and looked up once, not every time.
struct AcoustIDCacheEntry: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case matched, ambiguous, unconfirmed }
    var state: State
    var fingerprint: String
    var duration: Int
    var recordings: [AcoustIDRecording]
    var at: Date
}

enum AcoustIDCacheRules {
    /// How long an answer is trusted: a match for months, an unknown file for a week (the database grows), an ambiguous one for a month.
    static func lifetime(_ s: AcoustIDCacheEntry.State) -> TimeInterval {
        switch s { case .matched: 90 * 86_400; case .ambiguous: 30 * 86_400; case .unconfirmed: 7 * 86_400 }
    }
    static func isFresh(_ e: AcoustIDCacheEntry, now: Date = Date()) -> Bool { now.timeIntervalSince(e.at) < lifetime(e.state) }
    static func key(path: String, size: Int64, modified: Date) -> String { "\(path)|\(size)|\(Int(modified.timeIntervalSince1970))" }
    static let capacity = 1_500
}

final class AcoustIDCacheStore: @unchecked Sendable {
    static let shared = AcoustIDCacheStore(url: MusicStorage.subfolder("AcoustID").appendingPathComponent("results.json"))
    private let lock = NSLock()
    private var entries: [String: AcoustIDCacheEntry] = [:]
    private let url: URL?
    private var loaded = false

    init(url: URL?) { self.url = url }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        if let url, let d = try? Data(contentsOf: url), let m = try? MusicJSONCoding.makeDecoder().decode([String: AcoustIDCacheEntry].self, from: d) { entries = m }
    }

    func entry(_ key: String) -> AcoustIDCacheEntry? { lock.lock(); defer { lock.unlock() }; ensureLoaded(); return entries[key] }

    func set(_ e: AcoustIDCacheEntry, for key: String) {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        entries[key] = e
        if entries.count > AcoustIDCacheRules.capacity {
            for k in entries.sorted(by: { $0.value.at < $1.value.at }).prefix(entries.count - AcoustIDCacheRules.capacity).map(\.key) { entries[k] = nil }
        }
        if let url, let d = try? MusicJSONCoding.makeEncoder().encode(entries) { try? d.write(to: url, options: .atomic) }
    }

    func clear() { lock.lock(); defer { lock.unlock() }; entries = [:]; loaded = true; if let url { try? FileManager.default.removeItem(at: url) } }
}

struct AcoustIDOutcome: Equatable, Sendable {
    var verdict: AcoustIDVerdict
    /// The answer came from the cache; no fingerprint was made and nothing was sent.
    var fromCache: Bool
}

/// Identifies one local file. Serial (one file at a time), cancellable, and independent of playback and lyrics: it only reads the file.
actor LocalRecordingIdentifier {
    static let shared = LocalRecordingIdentifier()

    var client = AcoustIDClient()
    var cache: AcoustIDCacheStore = .shared
    var fingerprinter: @Sendable (URL) async throws -> (duration: Int, fingerprint: String) = { try await ChromaprintEngine.fingerprint($0) }

    func configure(client: AcoustIDClient, cache: AcoustIDCacheStore, fingerprinter: @escaping @Sendable (URL) async throws -> (duration: Int, fingerprint: String)) {
        self.client = client; self.cache = cache; self.fingerprinter = fingerprinter
    }

    func identify(_ entry: LocalEntry, now: Date = Date()) async throws -> AcoustIDOutcome {
        let url = URL(fileURLWithPath: entry.path)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        let key = AcoustIDCacheRules.key(path: entry.path, size: size, modified: entry.modified)
        let local = AcoustIDMatcher.Local(title: entry.title, artist: entry.artist, durationMs: entry.durationMs)

        if let hit = cache.entry(key), AcoustIDCacheRules.isFresh(hit, now: now) { return AcoustIDOutcome(verdict: AcoustIDMatcher.decide(hit.recordings, local: local), fromCache: true) }

        // A fingerprint kept from an earlier lookup is reused when only the answer has expired.
        var fingerprint = cache.entry(key).map { ($0.duration, $0.fingerprint) }
        if fingerprint == nil { fingerprint = try await fingerprinter(url) }
        try Task.checkCancellation()
        guard let fp = fingerprint else { throw ChromaprintTool.Failure.unreadable }
        let recordings = try await client.lookup(fingerprint: fp.1, duration: fp.0)
        let verdict = AcoustIDMatcher.decide(recordings, local: local)
        let state: AcoustIDCacheEntry.State
        switch verdict { case .match: state = .matched; case .ambiguous: state = .ambiguous; case .unconfirmed: state = .unconfirmed }
        cache.set(AcoustIDCacheEntry(state: state, fingerprint: fp.1, duration: fp.0, recordings: recordings, at: now), for: key)
        return AcoustIDOutcome(verdict: verdict, fromCache: false)
    }
}
