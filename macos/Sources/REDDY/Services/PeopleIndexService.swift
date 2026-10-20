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

    /// Starts a pass unless one is running. Safe to call as often as is convenient. `fast` asks four at a time with short pauses (the person pressed "Read Cast Now"); the
    /// default is the slow, polite pace. Either way it waits while something plays, and a playlist that keeps failing is left alone.
    func start(fast: Bool = false) {
        guard running.begin() else { return }
        Task.detached(priority: fast ? .utility : .background) { [self] in
            defer { running.end() }
            await run(fast: fast)
        }
    }

    private enum Outcome: Sendable { case learned, nothingToLearn, failed, cancelled }

    private func learn(_ id: String, _ sourceID: UUID) async -> Outcome {
        guard let movie = try? catalog.movie(id: id), let source = try? catalog.source(id: sourceID) else { index.markDone(itemID: id, sourceID: sourceID); return .nothingToLearn }
        do {
            let detail = try await sources.makeProvider(for: source).movieDetail(movie)
            try? indexer.saveMovieDetail(id: id, detail: detail)          // the story, genre and length it also carries are kept too
            try index.save(itemID: id, kind: .movie, sourceID: sourceID, names: (detail.extras?.cast ?? []) + (detail.extras?.directors ?? []))
            return .learned
        } catch is CancellationError { return .cancelled }
        catch SourceError.unsupported(_) { index.markDone(itemID: id, sourceID: sourceID); return .nothingToLearn }          // this kind of playlist has no details: nothing to learn
        catch { return .failed }
    }

    private func run(fast: Bool) async {
        var failures: [UUID: Int] = [:]
        var giveUp = Set<UUID>()
        let width = fast ? 4 : 1
        while !Task.isCancelled {
            if await busy() { try? await Task.sleep(nanoseconds: 8_000_000_000); continue }
            let batch = index.pendingMovies(limit: fast ? 24 : 8).filter { !giveUp.contains($0.sourceID) }
            if batch.isEmpty { return }
            var next = 0
            let results: [(UUID, Outcome)] = await withTaskGroup(of: (UUID, Outcome)?.self) { group in
                func add() {
                    guard next < batch.count else { return }
                    let (id, sourceID) = batch[next]; next += 1
                    group.addTask { [self] in
                        if Task.isCancelled { return nil }
                        if await busy() { return nil }
                        let r = await learn(id, sourceID)
                        try? await Task.sleep(nanoseconds: fast ? 40_000_000 : 350_000_000)
                        return (sourceID, r)
                    }
                }
                for _ in 0..<width { add() }
                var out: [(UUID, Outcome)] = []
                while let r = await group.next() { if let r { out.append(r) }; add() }
                return out
            }
            if results.contains(where: { $0.1 == .cancelled }) { return }
            if results.isEmpty { try? await Task.sleep(nanoseconds: 2_000_000_000); continue }          // everything waited for playback
            for (sourceID, r) in results {
                switch r {
                case .learned: failures[sourceID] = 0
                case .failed:
                    failures[sourceID, default: 0] += 1
                    if failures[sourceID, default: 0] >= 4 { giveUp.insert(sourceID) }                    // struggling: leave it until the next pass
                default: break
                }
            }
            if results.contains(where: { $0.1 == .failed }) { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            if batch.allSatisfy({ giveUp.contains($0.sourceID) }) { return }
        }
    }
}
