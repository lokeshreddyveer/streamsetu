import Foundation

// The song page's section loaders: one `MusicEntitySectionLoader` per graph-backed block. They read only the local graph (never the network and never
// the player), so a metadata outage leaves them showing whatever the graph already holds. Each runs under one shared gate that lets at most three
// sections read at once, reports partial results as they build, and stops when its task is cancelled.

/// At most `limit` section reads at a time for one page; a waiting read leaves the queue when its task is cancelled.
actor MusicSongLoadGate {
    private let limit: Int
    private var running = 0
    private var waiters: [(id: UUID, cont: CheckedContinuation<Void, Error>)] = []
    private(set) var peak = 0

    init(limit: Int = 3) { self.limit = max(1, limit) }

    private func acquire() async throws {
        try Task.checkCancellation()
        if running < limit { running += 1; peak = max(peak, running); return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { c.resume(throwing: CancellationError()) } else { waiters.append((id, c)) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        peak = max(peak, running)
    }

    private func cancelWaiter(_ id: UUID) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).cont.resume(throwing: CancellationError())
    }

    private func release() {
        if !waiters.isEmpty { waiters.removeFirst().cont.resume() } else { running -= 1 }
    }

    func run<T: Sendable>(_ op: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        do { let v = try await op(); release(); return v } catch { release(); throw error }
    }
}

/// One neighbourhood walk shared by the sections that need it (related and similar read the same one).
actor MusicSongNeighbourhoodShare {
    private var tasks: [MusicEntityID: Task<MusicNeighbourhood?, Never>] = [:]
    private(set) var walks = 0

    func get(_ store: any MusicGraphStoring, _ id: MusicEntityID) async -> MusicNeighbourhood? {
        if let t = tasks[id] { return await t.value }
        walks += 1
        let t = Task<MusicNeighbourhood?, Never> { try? await store.neighbours(of: id, depth: MusicTraversal.maxDepth, fanOut: MusicTraversal.maxFanOut) }
        tasks[id] = t
        return await t.value
    }
}

/// The credits of the page's recording, read once for every section that needs the people (credits, more by, films).
actor MusicSongCreditsShare {
    private var tasks: [MusicEntityID: Task<[MusicSongCreditGroup], Never>] = [:]
    private(set) var reads = 0

    func groups(_ store: any MusicGraphStoring, _ id: MusicEntityID) async -> [MusicSongCreditGroup] {
        if let t = tasks[id] { return await t.value }
        reads += 1
        let t = Task<[MusicSongCreditGroup], Never> { await MusicSongReads.creditGroups(store, id) }
        tasks[id] = t
        return await t.value
    }
}

/// What every loader of one page shares.
struct MusicSongLoaderEnv: Sendable {
    let gate: MusicSongLoadGate
    let hood: MusicSongNeighbourhoodShare
    let credits: MusicSongCreditsShare
    init(gate: MusicSongLoadGate = MusicSongLoadGate(), hood: MusicSongNeighbourhoodShare = MusicSongNeighbourhoodShare(), credits: MusicSongCreditsShare = MusicSongCreditsShare()) {
        self.gate = gate; self.hood = hood; self.credits = credits
    }

    /// The loaders of the nine graph-backed sections.
    func loaders() -> [any MusicEntitySectionLoader] {
        [MusicSongContextLoader(env: self), MusicSongPageCreditsLoader(env: self), MusicSongVersionsLoader(env: self), MusicSongSamplesLoader(env: self), MusicSongRelatedLoader(env: self),
         MusicSongMoreLoader(env: self, section: .moreBySinger), MusicSongMoreLoader(env: self, section: .moreByComposer), MusicSongFilmsLoader(env: self),
         MusicSongPlaylistsLoader(env: self), MusicSongSimilarLoader(env: self)]
    }
}

// MARK: reads

/// Non-throwing reads: a store error becomes "nothing here" so one failing read gives a partial section, never a failed page. Cancellation is checked
/// by the callers between reads.
enum MusicSongReads {
    static func edges(_ s: any MusicGraphStoring, _ id: MusicEntityID, _ p: MusicPredicate?, _ d: MusicEdgeDirection, _ limit: Int = 60) async -> [MusicEdge] {
        (try? await s.edges(of: id, predicate: p, direction: d, limit: limit)) ?? []
    }

    static func entity(_ s: any MusicGraphStoring, _ id: MusicEntityID) async -> MusicEntitySnapshot? { try? await s.entity(id) }

    static func link(_ e: MusicEntitySnapshot) -> MusicSongLink { MusicSongLink(id: e.id, name: e.name, year: e.year, subkind: e.subkind, imageRef: e.imageRef) }

    /// "Mukesh, Lata Mangeshkar": the first performers' names, for a line under a song.
    static func artistLine(_ s: any MusicGraphStoring, _ id: MusicEntityID, limit: Int = 2) async -> String? {
        var names: [String] = []
        for e in await edges(s, id, .performedBy, .outgoing, 6).prefix(limit) { if let p = await entity(s, e.object) { names.append(p.name) } }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    /// The credit rows of a recording (and of its work, when there is one), grouped. Reads the recording first and reports nothing; callers that
    /// want partial results use `creditRows`.
    static func creditRows(_ s: any MusicGraphStoring, _ id: MusicEntityID, predicates: [MusicPredicate]) async -> [MusicSongCredits.Row] {
        var rows: [MusicSongCredits.Row] = []
        var names: [MusicEntityID: MusicEntitySnapshot] = [:]
        func row(_ e: MusicEdge) async -> MusicSongCredits.Row? {
            if names[e.object] == nil { names[e.object] = await entity(s, e.object) }
            guard let p = names[e.object] else { return nil }
            return MusicSongCredits.Row(edge: e, name: p.name, year: p.year, country: p.country, subkind: p.subkind)
        }
        for p in predicates {
            if Task.isCancelled { return rows }
            for e in await edges(s, id, p, .outgoing, 60) { if let r = await row(e) { rows.append(r) } }
        }
        for w in await edges(s, id, .recordingOf, .outgoing, 3) {
            for p in predicates where p == .composedBy || p == .writtenBy || p == .musicDirectedBy {
                if Task.isCancelled { return rows }
                for e in await edges(s, w.object, p, .outgoing, 40) { if let r = await row(e) { rows.append(r) } }
            }
        }
        return rows
    }

    static let creditPredicates: [MusicPredicate] = [.performedBy, .composedBy, .musicDirectedBy, .writtenBy, .producedBy]

    static func creditGroups(_ s: any MusicGraphStoring, _ id: MusicEntityID) async -> [MusicSongCreditGroup] {
        MusicSongCredits.build(rows: await creditRows(s, id, predicates: creditPredicates))
    }

    /// The `soundtrackOf` edges of the albums a song is on: the placement's own release and, when a release belongs to an album, that album too.
    static func soundtrackEdges(_ s: any MusicGraphStoring, placements: [MusicEdge], limit: Int = 3) async -> [MusicEdge] {
        var out: [MusicEdge] = []
        var seen = Set<MusicEntityID>()
        for p in placements.prefix(limit) where p.predicate == .trackOn && !p.tombstone {
            var targets = [p.object]
            if p.object.kind == .release, let up = await edges(s, p.object, .editionOf, .outgoing, 3).filter({ !$0.tombstone }).sorted(by: MusicSongVersioning.better).first { targets.append(up.object) }
            for t in targets where seen.insert(t).inserted { out += await edges(s, t, .soundtrackOf, .outgoing, 4) }
        }
        return out
    }

    static func provenance(_ statuses: [EdgeStatus]) -> [MusicSectionProvenance] {
        guard let worst = statuses.max(by: { $0.rawValue < $1.rawValue }) else { return [] }
        return [MusicSectionProvenance(source: nil, status: worst, confidence: nil, retrievedAt: nil, note: nil)]
    }

    static func isSong(_ id: MusicEntityID) -> Bool { id.kind == .recording || id.kind == .work || id.kind == .track }
}
