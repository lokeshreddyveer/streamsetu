import Foundation
import Observation

/// Where an entity's page is overall. Sections have their own phases; this one says whether the entity itself is here.
enum MusicEntityPhase: Sendable, Equatable {
    case idle
    case loading
    /// The row is here but only provisionally (minted from provider text): the page renders it and enrichment is under way.
    case partial
    case loaded
    /// The graph has no such entity and nothing could fetch it.
    case failed
}

/// One entity's shared view model (section 4.4): its snapshot, its sections, one load per section however many views hold it. Pages never create one
/// directly; they `acquire` a lease from the center. It never references the player.
@MainActor @Observable
final class MusicEntityModel {
    /// The id the page asked for. After a merge `id` is the survivor.
    let requestedID: MusicEntityID
    private(set) var id: MusicEntityID
    private(set) var phase: MusicEntityPhase = .idle
    private(set) var snapshot: MusicEntitySnapshot?
    private(set) var sections: [String: MusicEntitySection] = [:]
    /// How many times the entity row was loaded (tests: two views, one load).
    @ObservationIgnored private(set) var snapshotLoads = 0
    /// How many section loads actually ran, by key.
    @ObservationIgnored private(set) var sectionRuns: [String: Int] = [:]

    @ObservationIgnored private let store: MusicEntityStore
    @ObservationIgnored private var loaders: [String: any MusicEntitySectionLoader] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var openTask: Task<Void, Never>?
    /// Keys whose running load began with items already on the page: their first-stage partials are ignored so the page does not shrink and regrow.
    @ObservationIgnored private var keepsItems: Set<String> = []
    /// Keys the graph changed while their load was running: that load may have read older edges, so it runs once more when it ends.
    @ObservationIgnored private var dirty: Set<String> = []
    @ObservationIgnored private var cancelled = false

    init(id: MusicEntityID, store: MusicEntityStore) {
        requestedID = id; self.id = id; self.store = store
    }

    var kind: MusicEntityKind { id.kind }
    var name: String? { snapshot?.name }
    /// The snapshot as a typed node (`model.node(MusicPersonNode.self)`); nil while loading or for another kind.
    func node<N: MusicEntityNode>(_ type: N.Type) -> N? { snapshot.flatMap { N(snapshot: $0) } }
    func section(_ key: String) -> MusicEntitySection { sections[key] ?? MusicEntitySection(key: key) }
    /// True while the store's background enrichment of this entity runs (it is started with the row and lands more rows and edges as it goes).
    private(set) var enriching = false
    var isWorking: Bool { openTask != nil || !tasks.isEmpty || enriching }

    // MARK: the entity

    /// Loads the row once and starts enrichment. Safe to call again (the first call wins until `refresh`).
    func start() {
        guard openTask == nil, phase == .idle else { return }
        cancelled = false
        phase = .loading
        openTask = Task { [weak self] in
            guard let self else { return }
            await self.loadRow()
            self.openTask = nil
        }
    }

    /// Tries a failed entity again: the phase goes back to idle and the row is loaded anew. A model that is not failed is left alone.
    func restart() {
        guard phase == .failed, openTask == nil else { return }
        phase = .idle
        start()
    }

    private func loadRow() async {
        snapshotLoads += 1
        let result = await store.load(id)
        guard !Task.isCancelled, !cancelled else { return }
        switch result {
        case .found(let s):
            apply(s)
            let run = store.enrich(s.id)
            enriching = true
            Task { [weak self] in await run.value; self?.enriching = false }
        case .missing:
            if snapshot == nil { phase = .failed }
        }
    }

    private func apply(_ s: MusicEntitySnapshot) {
        id = s.id
        snapshot = s
        phase = s.provisional ? .partial : .loaded
    }

    /// The graph changed for this entity: take the new row (a provisional id can resolve to a different live one) and re-run the sections that had loaded.
    func refresh() async {
        guard !cancelled else { return }
        let old = id
        if case .found(let s) = await store.load(old) {
            guard !cancelled else { return }
            apply(s)
        }
        for (key, loader) in loaders where sections[key]?.phase != .idle {
            if tasks[key] == nil { load(loader, force: true) } else { dirty.insert(key) }
        }
    }

    // MARK: sections

    /// Runs a section's loader. One run per key at a time, however many views ask; a loaded section is not reloaded unless `force`. The section keeps
    /// its items while it reloads (phase `.loading`) and after a failure (phase `.failed`).
    func load(_ loader: any MusicEntitySectionLoader, force: Bool = false) {
        let key = loader.key
        loaders[key] = loader
        if tasks[key] != nil { return }
        if !force, let s = sections[key], s.phase == .loaded || s.phase == .empty || s.phase == .partial { return }
        cancelled = false
        var s = sections[key] ?? MusicEntitySection(key: key)
        s.phase = .loading; s.errorMessage = nil
        sections[key] = s
        if s.items.isEmpty { keepsItems.remove(key) } else { keepsItems.insert(key) }
        sectionRuns[key, default: 0] += 1
        let eid = id, graph = store.graph
        let reporter = MusicSectionReporter { [weak self] partial in await self?.applyPartial(key, partial) }
        tasks[key] = Task { [weak self] in
            do {
                let result = try await loader.load(entity: eid, store: graph, report: reporter)
                try Task.checkCancellation()
                self?.finish(key, result)
            } catch is CancellationError {
                self?.cancelledSection(key)
            } catch {
                self?.failed(key, error)
            }
        }
    }

    private func applyPartial(_ key: String, _ r: MusicSectionResult) {
        guard !cancelled, tasks[key] != nil, !keepsItems.contains(key) else { return }
        var s = sections[key] ?? MusicEntitySection(key: key)
        s.items = r.items; s.provenance = r.provenance; s.explanation = r.explanation
        s.phase = .partial
        sections[key] = s
    }

    /// A load ended: the changes that arrived while it ran get one more pass.
    private func rerunIfDirty(_ key: String) {
        keepsItems.remove(key)
        guard dirty.remove(key) != nil, !cancelled, let loader = loaders[key] else { return }
        load(loader, force: true)
    }

    private func finish(_ key: String, _ r: MusicSectionResult) {
        tasks[key] = nil
        guard !cancelled else { return }
        defer { rerunIfDirty(key) }
        var s = sections[key] ?? MusicEntitySection(key: key)
        s.items = r.items; s.provenance = r.provenance; s.explanation = r.explanation; s.errorMessage = nil
        s.phase = r.items.isEmpty ? .empty : .loaded
        sections[key] = s
    }

    private func failed(_ key: String, _ error: Error) {
        tasks[key] = nil
        guard !cancelled else { return }
        defer { rerunIfDirty(key) }
        var s = sections[key] ?? MusicEntitySection(key: key)
        s.phase = .failed; s.errorMessage = String(describing: error)
        sections[key] = s
    }

    private func cancelledSection(_ key: String) {
        tasks[key] = nil
        keepsItems.remove(key); dirty.remove(key)
        guard var s = sections[key], s.phase == .loading || s.phase == .partial else { return }
        s.phase = s.items.isEmpty ? .idle : .loaded
        sections[key] = s
    }

    /// Leaving for good (the grace window ended): in-flight loads stop.
    func cancelAll() {
        cancelled = true
        openTask?.cancel(); openTask = nil
        for t in tasks.values { t.cancel() }
        let keys = Array(tasks.keys)
        tasks = [:]
        for k in keys { cancelledSection(k) }
        if phase == .loading { phase = .idle }
    }
}
