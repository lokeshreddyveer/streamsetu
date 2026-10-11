import SwiftUI
import Observation

/// State of the top-bar search. It holds the text, the chosen results tab and the current results, and nothing about the
/// screen underneath: the query is global. Typing is debounced, every keystroke cancels the query before it, and a result
/// that arrives for an older query is dropped. The work happens off the main actor (see `GlobalSearchService`).
@MainActor @Observable
final class GlobalSearchModel {
    var term = ""
    var tab: SearchTab = .all
    private(set) var results = GlobalSearchResults()
    private(set) var selectedID: String?
    private(set) var loading = false
    private(set) var searched = false
    /// Extra pages the user asked for, per kind.
    private var pages: [SearchResultKind: Int] = [:]

    private let service: GlobalSearchService
    private let debounce: UInt64
    private var task: Task<Void, Never>?
    private var generation = 0

    init(service: GlobalSearchService, debounceMilliseconds: UInt64 = 150) {
        self.service = service
        self.debounce = debounceMilliseconds * 1_000_000
    }

    // MARK: derived

    var visible: [SearchResult] { results.results(for: tab) }
    var selected: SearchResult? { visible.first { $0.id == selectedID } }
    var isActive: Bool { !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func count(_ t: SearchTab) -> Int { results.count(for: t) }

    // MARK: querying

    /// Called whenever the text changes.
    func schedule() {
        task?.cancel()
        generation += 1
        let gen = generation, text = term
        guard isActive else { reset(); return }
        pages = [:]
        loading = true
        task = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.debounce)
            if Task.isCancelled { return }
            await self.run(text, generation: gen)
        }
    }

    func selectTab(_ t: SearchTab) {
        guard t != tab else { return }
        tab = t
        selectedID = visible.first?.id
        if isActive, t != .all, (results.byKind[t.kinds.first ?? .channel] ?? []).count < GlobalSearchService.pageSize, results.hasMore.contains(t.kinds.first ?? .channel) {
            Task { await loadMore(t.kinds.first ?? .channel) }
        }
    }

    /// Runs one query. Results for a query that has since been replaced are discarded.
    func run(_ text: String, generation gen: Int? = nil) async {
        let mine = gen ?? { generation += 1; return generation }()
        let limits = pages
        var merged = GlobalSearchResults(query: text)
        do {
            // The first page of every type, in one pass; types the user asked for more of are re-run with their larger limit.
            merged = try await service.search(text, tab: .all, limit: GlobalSearchService.pageSize)
            for (kind, extra) in limits where extra > 0 {
                let r = try await service.search(text, tab: tabFor(kind), limit: GlobalSearchService.pageSize * (extra + 1))
                merged.byKind[kind] = r.byKind[kind] ?? []
                if r.hasMore.contains(kind) { merged.hasMore.insert(kind) } else { merged.hasMore.remove(kind) }
            }
        } catch { if error is CancellationError { return } }
        if Task.isCancelled || mine != generation { return }
        results = merged
        searched = true
        loading = false
        if !visible.contains(where: { $0.id == selectedID }) { selectedID = visible.first?.id }
    }

    /// Shows more of one type. Bounded: each press adds one page.
    func loadMore(_ kind: SearchResultKind) async {
        pages[kind, default: 0] += 1
        generation += 1
        await run(term, generation: generation)
    }

    private func tabFor(_ kind: SearchResultKind) -> SearchTab {
        switch kind { case .channel: .liveTV; case .movie: .movies; case .series: .series; case .episode: .episodes; case .programme: .tvGuide; case .folder, .collection: .all }
    }

    // MARK: selection

    func moveSelection(_ delta: Int) {
        let items = visible
        guard !items.isEmpty else { return }
        let i = items.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : 0)
        selectedID = items[((i + delta) % items.count + items.count) % items.count].id
    }
    func select(_ id: String) { selectedID = id }

    func clear() { reset(); term = "" }

    private func reset() {
        task?.cancel(); generation += 1
        results = GlobalSearchResults(); selectedID = nil; searched = false; loading = false; pages = [:]; tab = .all
    }
}
