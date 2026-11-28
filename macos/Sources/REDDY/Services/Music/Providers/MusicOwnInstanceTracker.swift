import Foundation

/// Keeps the person's own Piped and Invidious servers in front of the public ones. It probes an own server the first time it is needed (one
/// stream lookup for the fixed probe video, 6 seconds), keeps them in the order the person typed them, and only sets one aside after repeated
/// hard failures, to try it again five minutes later. Nothing here runs until a track needs audio or a status is asked for.
actor MusicOwnInstanceTracker {
    private let http: MusicHTTP
    private let urls: @Sendable (YouTubeInstances.Kind) -> [URL]
    private let now: @Sendable () -> Date
    private var books: [YouTubeInstances.Kind: MusicOwnBook] = [:]

    init(http: MusicHTTP, now: @escaping @Sendable () -> Date = { Date() },
         urls: @escaping @Sendable (YouTubeInstances.Kind) -> [URL] = { MusicOwnInstances.current().urls($0) }) {
        self.http = http
        self.now = now
        self.urls = urls
    }

    /// Own servers to try now, in the person's order, each probed first if it has no recent result.
    func ready(_ kind: YouTubeInstances.Kind) async -> [URL] {
        var book = books[kind] ?? MusicOwnBook()
        book.sync(urls(kind))
        let stale = book.entries.map(\.url).filter { book.needsProbe($0, now: now()) }
        books[kind] = book
        if !stale.isEmpty {
            let http = self.http, clock = self.now
            let results = await withTaskGroup(of: (URL, MusicOwnStatus).self) { group in
                for u in stale { group.addTask { (u, await MusicOwnProbe.run(kind, base: u, http: http, clock: clock)) } }
                var out: [(URL, MusicOwnStatus)] = []
                for await r in group { out.append(r) }
                return out
            }
            var updated = books[kind] ?? book
            for (u, s) in results { updated.recordProbe(u, s, now: now()) }
            books[kind] = updated
        }
        return books[kind]?.usable(now: now()) ?? []
    }

    func succeeded(_ kind: YouTubeInstances.Kind, _ url: URL) { books[kind]?.recordSuccess(url, now: now()) }
    func failed(_ kind: YouTubeInstances.Kind, _ url: URL) { books[kind]?.recordFailure(url, now: now()) }

    /// A person pressing "retry": every own server is eligible again.
    func reset() { books = [:] }

    /// One status per configured own server. A server with no result yet is probed so the answer is real.
    func statuses(_ kind: YouTubeInstances.Kind) async -> [MusicOwnInstanceStatus] {
        _ = await ready(kind)
        return books[kind]?.statuses() ?? []
    }
}

extension PipedProvider {
    /// Status of each own Piped server: working with its latency, not reachable, or reached but unable to provide audio.
    func ownInstanceStatuses() async -> [MusicOwnInstanceStatus] { await instances.ownStatuses(.piped) }
}

extension InvidiousProvider {
    func ownInstanceStatuses() async -> [MusicOwnInstanceStatus] { await instances.ownStatuses(.invidious) }
}

extension YouTubeInstances {
    /// Runs `op` on the person's own servers in their order. Returns nil when none is configured or none worked, so the caller goes on to the
    /// public ones. A missing video is not the server's fault and does not count against it.
    func performOwn<T: Sendable>(_ kind: Kind, _ op: @Sendable (URL) async throws -> T, lastError: inout Error) async throws -> T? {
        for base in await own.ready(kind) {
            do {
                let value = try await op(base)
                await own.succeeded(kind, base)
                return value
            } catch MusicError.cancelled {
                throw MusicError.cancelled
            } catch is CancellationError {
                throw MusicError.cancelled
            } catch {
                if let e = error as? MusicError, e == .notFound { lastError = e; continue }
                if let e = error as? MusicError, case .noPlayableSource = e { lastError = e; continue }
                await own.failed(kind, base)
                lastError = error
            }
        }
        return nil
    }
}
