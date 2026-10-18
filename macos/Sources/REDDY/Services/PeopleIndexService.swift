import Foundation

/// Reads who is in each movie (the cast and directors the playlist offers) so people can be searched for. It works slowly in the background:
/// one title at a time with a pause, never while something is playing (a detail request competes with a stream, and some providers allow only
/// one connection), and it stops by itself when a playlist keeps failing. What it learned is kept, so each pass carries on where the last stopped.
final class PeopleIndexService: Sendable {
    private let index: PeopleIndex
    private let catalog: SQLiteCatalogRepository
    private let sources: SourceManager
    private let indexer: CatalogIndexer
    private let busy: @Sendable () async -> Bool
    private let running = Flag()

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var on = false
        func begin() -> Bool { lock.lock(); defer { lock.unlock() }; if on { return false }; on = true; return true }
        func end() { lock.lock(); on = false; lock.unlock() }
    }

    init(index: PeopleIndex, catalog: SQLiteCatalogRepository, sources: SourceManager, indexer: CatalogIndexer, busy: @escaping @Sendable () async -> Bool) {
        self.index = index; self.catalog = catalog; self.sources = sources; self.indexer = indexer; self.busy = busy
    }

    var progress: (done: Int, total: Int) { index.progress() }

    /// Starts a pass unless one is running. Safe to call as often as is convenient.
    func start() {
        guard running.begin() else { return }
        Task.detached(priority: .background) { [self] in
            defer { running.end() }
            await run()
        }
    }

    private func run() async {
        var failures: [UUID: Int] = [:]
        var giveUp = Set<UUID>()
        while !Task.isCancelled {
            if await busy() { try? await Task.sleep(nanoseconds: 8_000_000_000); continue }
            let batch = index.pendingMovies(limit: 8).filter { !giveUp.contains($0.sourceID) }
            if batch.isEmpty { return }
            for (id, sourceID) in batch {
                if Task.isCancelled { return }
                if await busy() { break }
                guard let movie = try? catalog.movie(id: id), let source = try? catalog.source(id: sourceID) else { index.markDone(itemID: id, sourceID: sourceID); continue }
                do {
                    let detail = try await sources.makeProvider(for: source).movieDetail(movie)
                    try? indexer.saveMovieDetail(id: id, detail: detail)          // the story, genre and length it also carries are kept too
                    try index.save(itemID: id, kind: .movie, sourceID: sourceID, names: (detail.extras?.cast ?? []) + (detail.extras?.directors ?? []))
                    failures[sourceID] = 0
                } catch is CancellationError { return }
                catch SourceError.unsupported(_) { index.markDone(itemID: id, sourceID: sourceID) }          // this kind of playlist has no details: nothing to learn
                catch {
                    failures[sourceID, default: 0] += 1
                    if failures[sourceID, default: 0] >= 4 { giveUp.insert(sourceID) }                    // struggling: leave it until the next pass
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            if batch.allSatisfy({ giveUp.contains($0.sourceID) }) { return }
        }
    }
}
