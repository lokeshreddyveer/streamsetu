import Foundation

/// The one front door for asking a source for something Music may need again. It answers from the saved copy when it can, asks the source when it
/// must, asks only once however many screens ask at the same moment, retries a short network failure, and falls back to an older saved copy when the
/// source is down.
///
/// - `fresh`: saved less than `fresh` ago: returned as it is, no request.
/// - `usable`: saved less than `ttl` ago: returned at once, and one quiet refresh runs behind it (stale-while-revalidate, RFC 5861).
/// - older, or none: the source is asked. If that fails and a copy younger than `ttl + staleIfError` exists, that copy is returned (stale-if-error).
/// - one request per key at a time: a second ask for a key already in flight waits for the first answer.
/// - a failed request never removes a good copy; the answer that comes back is saved for everyone.
actor MusicFetch {
    struct Policy: Sendable, Equatable {
        var fresh: TimeInterval
        var ttl: TimeInterval
        var staleIfError: TimeInterval
        var retries: Int = 2
    }

    enum Source: Sendable, Equatable { case network, saved, savedBecauseOffline }
    struct Answer<T: Sendable>: Sendable { var value: T; var source: Source; var savedAt: Date? }

    /// What each kind of answer is worth, in one place.
    enum Kind {
        static let albumPage = Policy(fresh: 6 * 3_600, ttl: 7 * 86_400, staleIfError: 30 * 86_400)
        static let artistPage = Policy(fresh: 6 * 3_600, ttl: 3 * 86_400, staleIfError: 14 * 86_400)
        static let playlist = Policy(fresh: 3_600, ttl: 86_400, staleIfError: 7 * 86_400)
        static let browse = Policy(fresh: 3_600, ttl: 6 * 3_600, staleIfError: 86_400)
        static let search = Policy(fresh: 60, ttl: 600, staleIfError: 3_600, retries: 1)
    }

    /// Bumped when a saved shape changes: old rows then never match.
    static let schema = "v1"

    private let store: MusicDataStore
    private let clock: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async -> Void
    private var inflight: [String: Task<Data, Error>] = [:]
    private var refreshing = Set<String>()
    private(set) var requests = 0

    init(store: MusicDataStore, clock: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.store = store; self.clock = clock; self.sleep = sleep
    }

    static func key(_ parts: String...) -> String { ([schema] + parts).joined(separator: "|") }

    /// `keep` says whether a fetched answer is worth saving (an empty page is returned but not saved, so a hiccup is not remembered for hours).
    func value<T: Codable & Sendable>(_ key: String, policy: Policy, keep: @escaping @Sendable (T) -> Bool = { _ in true }, fetch: @escaping @Sendable () async throws -> T) async throws -> Answer<T> {
        let saved = await store.get(key)
        let decoded: (T, Date)? = saved.flatMap { row in (try? JSONDecoder().decode(T.self, from: row.data)).map { ($0, row.savedAt) } }
        let age = decoded.map { clock().timeIntervalSince($0.1) }
        if let (v, at) = decoded, let age, age < policy.fresh { return Answer(value: v, source: .saved, savedAt: at) }
        if let (v, at) = decoded, let age, age < policy.ttl {
            refreshBehind(key, policy: policy, keep: keep, fetch: fetch)
            return Answer(value: v, source: .saved, savedAt: at)
        }
        do {
            let data = try await shared(key, policy: policy, keep: keep, fetch: fetch)
            return Answer(value: try JSONDecoder().decode(T.self, from: data), source: .network, savedAt: nil)
        } catch {
            if let (v, at) = decoded, let age, age < policy.ttl + policy.staleIfError, !(error is CancellationError) {
                return Answer(value: v, source: .savedBecauseOffline, savedAt: at)
            }
            throw error
        }
    }

    /// Forgets saved answers whose key starts with `prefix` (a source was switched off, an account changed).
    func forget(prefix: String) async { await store.remove(prefix: prefix) }
    func wipe() async { inflight.values.forEach { $0.cancel() }; inflight = [:]; await store.wipe() }

    // MARK: one request per key

    private func shared<T: Codable & Sendable>(_ key: String, policy: Policy, keep: @escaping @Sendable (T) -> Bool, fetch: @escaping @Sendable () async throws -> T) async throws -> Data {
        if let running = inflight[key] { return try await running.value }
        requests += 1
        let task = Task<Data, Error> { [store, sleep] in
            var attempt = 0
            while true {
                do {
                    let value = try await fetch()
                    let data = try JSONEncoder().encode(value)
                    if keep(value) { await store.put(key, data: data) }
                    return data
                } catch {
                    if Task.isCancelled || attempt >= policy.retries || !Self.isTransient(error) { throw error }
                    attempt += 1
                    await sleep(.milliseconds(attempt == 1 ? 400 : 1_200))
                }
            }
        }
        inflight[key] = task
        // A newer request may sit under this key after a wipe: only the one made here is removed.
        defer { if inflight[key] == task { inflight[key] = nil } }
        return try await task.value
    }

    private func refreshBehind<T: Codable & Sendable>(_ key: String, policy: Policy, keep: @escaping @Sendable (T) -> Bool, fetch: @escaping @Sendable () async throws -> T) {
        guard refreshing.insert(key).inserted else { return }
        Task.detached(priority: .background) { [self] in
            _ = try? await shared(key, policy: Policy(fresh: 0, ttl: 0, staleIfError: 0, retries: 0), keep: keep, fetch: fetch)
            await finished(key)
        }
    }
    private func finished(_ key: String) { refreshing.remove(key) }

    /// A short network failure is worth another try; a refusal, a missing item or a bad answer is not.
    static func isTransient(_ error: Error) -> Bool {
        if let u = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost].contains(u.code)
        }
        return (error as NSError).domain == "MusicTransient"
    }
}

extension MusicFetch {
    /// The one instance the app uses: a database in the Music cache folder (not backed up; rebuildable; removed by the privacy wipe).
    static let shared: MusicFetch = {
        let dir = MusicStorage.caches.appendingPathComponent("Data", isDirectory: true)
        _ = MusicStorage.ensureUnbacked(dir)
        // The first version of the saved pages was a folder of files; its contents are not read any more.
        try? FileManager.default.removeItem(at: MusicStorage.caches.appendingPathComponent("PageCache", isDirectory: true))
        return MusicFetch(store: MusicDataStore(path: dir.appendingPathComponent("data.sqlite")))
    }()
}
