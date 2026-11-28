import SwiftUI
import Observation

// MARK: pure logic (covered by tests)

/// The type chips above the results.
enum MusicSearchKind: String, CaseIterable, Identifiable, Sendable {
    case all, songs, artists, albums, playlists
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: Localized.string("All"); case .songs: Localized.string("Songs"); case .artists: Localized.string("Artists")
        case .albums: Localized.string("Albums"); case .playlists: Localized.string("Playlists")
        }
    }
    /// What the All chip asks for; the other chips ask for one type and can page.
    var types: Set<MusicSearchType> {
        switch self {
        case .all: [.track, .artist, .album, .playlist]
        case .songs: [.track]; case .artists: [.artist]; case .albums: [.album]; case .playlists: [.playlist]
        }
    }
    var pages: Bool { self != .all }
}

/// Where a search looks. The switch shows only when there is more than one place to look.
enum MusicSearchScope: String, CaseIterable, Identifiable, Sendable {
    case everything, library, local
    var id: String { rawValue }
    var title: String {
        switch self { case .everything: Localized.string("Everything"); case .library: Localized.string("Your library"); case .local: Localized.string("Local files") }
    }
    var placeholder: String {
        switch self {
        case .everything: Localized.string("Songs, artists, albums or playlists")
        case .library: Localized.string("Search Your library")
        case .local: Localized.string("Search your Local files")
        }
    }
    /// The sentence for a search that found nothing.
    func nothingFound(for query: String) -> String {
        switch self {
        case .everything: Localized.string("No results for “%@”", query)
        case .library: Localized.string("Nothing in Your library matches “%@”.", query)
        case .local: Localized.string("Nothing in Local files matches “%@”.", query)
        }
    }
    /// Scopes to offer: only Local files adds a second place to look, so without it there is no switch.
    static func available(localFilesOn: Bool) -> [MusicSearchScope] { localFilesOn ? [.everything, .library, .local] : [.everything] }
}

/// Searches the songs, artists, albums and playlists kept on this Mac. It needs no source and no sign-in.
enum MusicLibrarySearch {
    struct Hits: Equatable, Sendable {
        var tracks: [MusicTrack] = []; var artists: [MusicArtist] = []; var albums: [MusicAlbum] = []; var playlists: [MusicPlaylist] = []
    }

    static func run(_ query: String, liked: [MusicTrack], playlists: [LocalPlaylist], history: [PlayRecord], artists: [MusicArtist], albums: [MusicAlbum]) -> Hits {
        let words = MusicTrackFilter.apply
        let pool = MusicDedupe.by(liked + playlists.flatMap(\.tracks) + history.map(\.track), key: \.uid)
        var hits = Hits()
        hits.tracks = MusicSearchRanker.rank(words(pool, query), query: query, name: \.title)
        hits.artists = MusicSearchRanker.rank(artists.filter { MusicSearchRanker.normalise($0.name).contains(MusicSearchRanker.normalise(query)) }, query: query, name: \.name)
        hits.albums = MusicSearchRanker.rank(albums.filter {
            let n = MusicSearchRanker.normalise(query)
            return MusicSearchRanker.normalise($0.title).contains(n) || MusicSearchRanker.normalise($0.artists.first?.name ?? "").contains(n)
        }, query: query, name: \.title)
        hits.playlists = playlists.filter { MusicSearchRanker.normalise($0.name).contains(MusicSearchRanker.normalise(query)) }
            .map { MusicPlaylist(id: $0.id.uuidString, providerID: MusicStatsRules.localProviderID, name: $0.name, trackCount: $0.tracks.count) }
        return hits
    }
}

/// Searches the person typed, newest first, kept on this Mac only.
struct MusicRecentSearches: Equatable {
    static let limit = 10
    /// Chips shown on the empty page; older searches stay stored but are not listed.
    static let chipLimit = 8
    static let key = "music.recentSearches"
    private(set) var items: [String] = []
    var chips: [String] { Array(items.prefix(Self.chipLimit)) }

    init(items: [String] = []) { self.items = Array(items.prefix(Self.limit)) }
    init(defaults: UserDefaults) { self.init(items: defaults.stringArray(forKey: Self.key) ?? []) }

    mutating func add(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return }
        items.removeAll { $0.caseInsensitiveCompare(q) == .orderedSame }
        items.insert(q, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
    }
    mutating func remove(_ query: String) { items.removeAll { $0 == query } }
    mutating func clear() { items = [] }
    func save(to defaults: UserDefaults) {
        if items.isEmpty { defaults.removeObject(forKey: Self.key) } else { defaults.set(items, forKey: Self.key) }
    }
}

enum MusicSearchMerge {
    /// Alternates between the sources' lists (so one busy source does not bury the others) and drops repeats of the same key.
    static func interleave<T>(_ lists: [[T]], key: (T) -> String) -> [T] {
        var out: [T] = []; var seen = Set<String>()
        let longest = lists.map(\.count).max() ?? 0
        for i in 0..<longest { for l in lists where i < l.count { if seen.insert(key(l[i])).inserted { out.append(l[i]) } } }
        return out
    }
    /// Appends a later page to what is shown, skipping what is already there.
    static func append<T>(_ old: [T], _ more: [T], key: (T) -> String) -> [T] {
        var seen = Set(old.map(key)); var out = old
        for m in more where seen.insert(key(m)).inserted { out.append(m) }
        return out
    }
}

/// Merges what several sources answered into one list: the same song from two sources is shown once (the copy that already has a stream
/// wins), and the best match for the words typed comes first.
enum MusicSearchRanker {
    static func normalise(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private static func words(_ s: String) -> [String] {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// Same recording: the same ISRC, or the same title and first artist with lengths within three seconds (an unknown length does not block a match).
    static func isSame(_ a: MusicTrack, _ b: MusicTrack) -> Bool {
        if let x = a.isrc?.uppercased(), let y = b.isrc?.uppercased(), !x.isEmpty, x == y { return true }
        guard normalise(a.title) == normalise(b.title), !normalise(a.title).isEmpty else { return false }
        guard normalise(a.artists.first?.name ?? "") == normalise(b.artists.first?.name ?? "") else { return false }
        if a.durationMs > 0, b.durationMs > 0 { return abs(a.durationMs - b.durationMs) <= 3_000 }
        return true
    }

    private static func hasStream(_ t: MusicTrack) -> Bool { !(t.directStreams ?? []).isEmpty }

    /// 3 exact, 2 one contains the other, 1 every word of the query appears, 0 otherwise.
    static func matchTier(query: String, title: String, artist: String) -> Int {
        let q = normalise(query), t = normalise(title), a = normalise(artist)
        guard !q.isEmpty, !t.isEmpty else { return 0 }
        if q == t || q == t + a || q == a + t { return 3 }
        if t.contains(q) || q.contains(t) { return 2 }
        let hay = t + a
        let ws = words(query)
        return !ws.isEmpty && ws.allSatisfy { hay.contains(normalise($0)) } ? 1 : 0
    }

    static func score(_ t: MusicTrack, query: String) -> Int {
        let fit = Int((max(0, MusicSearchScoring.score(track: t, query: query)) * 1_000).rounded())
        let pop = min(50, Int(log10(Double(max(0, t.popularity ?? 0)) + 1) * 10))
        return fit + (hasStream(t) ? 60 : 0) + pop
    }

    static func mergeTracks(_ lists: [[MusicTrack]], query: String) -> [MusicTrack] {
        var kept: [MusicTrack] = []
        for t in MusicSearchMerge.interleave(lists, key: { $0.uid }) {
            if let i = kept.firstIndex(where: { isSame($0, t) }) {
                let old = kept[i]
                if (!hasStream(old) && hasStream(t)) || (hasStream(old) == hasStream(t) && (t.popularity ?? 0) > (old.popularity ?? 0)) { kept[i] = t }
            } else { kept.append(t) }
        }
        // Each song is scored once, then sorted on the numbers (scoring inside the comparison repeated the work at every step of the sort).
        return kept.enumerated().map { (offset: $0.offset, element: $0.element, score: score($0.element, query: query)) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
            .map(\.element)
    }

    /// Orders any named item (artist, album, playlist) by how well its name fits the words typed; equal fits keep their order.
    static func rank<T>(_ items: [T], query: String, name: (T) -> String) -> [T] {
        items.enumerated().sorted { a, b in
            let x = matchTier(query: query, title: name(a.element), artist: ""), y = matchTier(query: query, title: name(b.element), artist: "")
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
    }
}

struct MusicSearchChunk: Sendable { var providerID: String; var results: [MusicSearchResult]; var next: MusicPagination? }

enum MusicSearchRunner {
    /// One source's answer for one query and chip. A source that does not offer a type answers with nothing, not an error.
    static func run(provider: any MusicMetadataProvider, query: String, kind: MusicSearchKind, page: MusicPagination?) async throws -> MusicSearchChunk {
        try await MusicSearchEnrichment.run(provider: provider, query: query, kind: kind, page: page, plain: plainRun)
    }

    static func plainRun(provider: any MusicMetadataProvider, query: String, kind: MusicSearchKind, page: MusicPagination?) async throws -> MusicSearchChunk {
        do {
            switch kind {
            case .all: return MusicSearchChunk(providerID: provider.id, results: try await provider.search(query, types: kind.types), next: nil)
            case .songs: let p = try await provider.searchTracks(query, page: page); return MusicSearchChunk(providerID: provider.id, results: p.items.map { .track($0) }, next: p.next)
            case .artists: let p = try await provider.searchArtists(query, page: page); return MusicSearchChunk(providerID: provider.id, results: p.items.map { .artist($0) }, next: p.next)
            case .albums: let p = try await provider.searchAlbums(query, page: page); return MusicSearchChunk(providerID: provider.id, results: p.items.map { .album($0) }, next: p.next)
            case .playlists: let p = try await provider.searchPlaylists(query, page: page); return MusicSearchChunk(providerID: provider.id, results: p.items.map { .playlist($0) }, next: p.next)
            }
        } catch MusicError.unsupported { return MusicSearchChunk(providerID: provider.id, results: [], next: nil) }
    }
}

// MARK: model

/// The search screen's state. It lives in the hub so the words and results survive a trip to another page; the requests do not (they are cancelled on leaving).
@MainActor @Observable
final class MusicSearchModel {
    var query = "" { didSet { if query != oldValue { queryChanged() } } }
    var kind = MusicSearchKind.all { didSet { if kind != oldValue, !keepKindQuiet { runNow() } } }
    @ObservationIgnored private var keepKindQuiet = false
    var scope = MusicSearchScope.everything { didSet { if scope != oldValue { resetResults(); runNow() } } }
    /// The words the shown results answer. While the field says something else, the page shows suggestions instead.
    private(set) var committed = ""
    private(set) var genres: [MusicBrowseGenre] = []
    @ObservationIgnored weak var library: MusicLibrary?
    private(set) var tracks: [MusicTrack] = []
    private(set) var artists: [MusicArtist] = []
    private(set) var albums: [MusicAlbum] = []
    private(set) var playlists: [MusicPlaylist] = []
    private(set) var state: MusicLoad<Int>?
    private(set) var loadingMore = false
    private(set) var recents: MusicRecentSearches
    private(set) var canLoadMore = false
    /// The fixed spelling the page also searched for, when the typed words found little and a known name sounds or spells nearly the same.
    private(set) var correctedTo: String?
    /// What the page draws, worked out once when results arrive (off the main actor) instead of on every redraw.
    private(set) var relevantArtists: [MusicArtist] = []
    private(set) var dedupedAlbums: [MusicAlbum] = []
    private(set) var dedupedPlaylists: [MusicPlaylist] = []
    private(set) var top: MusicSearchResult?
    /// Bumped by every new search; an answer to an older one is never installed.
    @ObservationIgnored private var generation = 0
    /// The newest partial answer being ranked; each partial holds everything so far, so a newer one replaces an older one.
    @ObservationIgnored private var partialTask: Task<Void, Never>?
    @ObservationIgnored private var nextPages: [String: MusicPagination] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let registry: MusicRegistry
    @ObservationIgnored private let defaults: UserDefaults

    init(registry: MusicRegistry, defaults: UserDefaults = .standard) {
        self.registry = registry; self.defaults = defaults; recents = MusicRecentSearches(defaults: defaults)
    }

    var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The person is typing something new: suggestions show, and the earlier results wait.
    var isTypingAhead: Bool { !trimmed.isEmpty && trimmed != committed }
    var scopes: [MusicSearchScope] { MusicSearchScope.available(localFilesOn: registry.isEnabled(MusicStatsRules.localProviderID)) }
    var hasResults: Bool { !(tracks.isEmpty && artists.isEmpty && albums.isEmpty && playlists.isEmpty) }
    /// Every switched-on source is asked, always: the person does not choose where a song comes from.
    private var providers: [any MusicMetadataProvider] {
        switch scope {
        case .everything: registry.metadata
        case .library: []
        case .local: registry.metadata.filter { $0.id == MusicStatsRules.localProviderID }
        }
    }
    /// How long the page waits for slow sources before showing what it has.
    static let overallCap = Duration.seconds(6)

    func cancel() { task?.cancel(); task = nil; if case .loading? = state { state = nil }; loadingMore = false }

    /// A search that was cancelled while it loaded (the person left the page) leaves its words and no results. Coming back must not show an empty page: the same search
    /// runs again, and the query cache usually answers it at once. Pure, so it can be checked on its own.
    nonisolated static func needsResume(trimmed: String, committed: String, state: MusicLoad<Int>?, hasResults: Bool) -> Bool {
        !trimmed.isEmpty && trimmed == committed && state == nil && !hasResults
    }
    func resumeIfNeeded() { if Self.needsResume(trimmed: trimmed, committed: committed, state: state, hasResults: hasResults) { runNow() } }

    func clearQuery() { query = ""; MusicSearchPersistenceStore(defaults: defaults).clear(); MusicDebugLog.log("search", "persisted search cleared by the person") }

    /// Brings back the last search (words, type chip, where it looks) when it was used within 24 hours, the field is empty and the mode is not gated. The same search runs again
    /// at once; the query cache usually answers it, and the page shows a skeleton, never an empty page, while it does.
    func restorePersisted(gated: Bool, now: Date = Date()) {
        let store = MusicSearchPersistenceStore(defaults: defaults)
        let decision = MusicSearchPersistence.decide(saved: store.load(), gated: gated, currentQuery: query, now: now)
        MusicDebugLog.log("search", "restore decision: \(String(String(describing: decision).prefix(60)))")
        switch decision {
        case .restore(let s):
            if let sc = MusicSearchScope(rawValue: s.scope), sc != scope, scopes.contains(sc) { scope = sc }
            keepKindQuiet = true; kind = MusicSearchKind(rawValue: s.kind) ?? .all; keepKindQuiet = false
            query = s.query
            runNow()
            savePersisted(gated: gated, now: now)
        case .expired, .blank: store.clear()
        case .gated, .nothingSaved, .fieldNotEmpty: break
        }
    }

    /// Keeps the words, chip and place so the page can open on them again; blank words forget. Does nothing in a gated mode. Every save renews the 24 hours.
    func savePersisted(gated: Bool, now: Date = Date()) {
        guard !gated else { return }
        MusicSearchPersistenceStore(defaults: defaults).save(MusicSearchPersistence.state(query: query, kind: kind.rawValue, scope: scope.rawValue, now: now))
    }
    func useRecent(_ q: String) { if query == q { newWordsStartBroad(q); runNow(remember: true) } else { query = q; newWordsStartBroad(q); runNow(remember: true) } }
    /// New words start on All (Apple's search guidance: start broad, let people narrow); a chip the person presses afterwards is theirs.
    private func newWordsStartBroad(_ words: String) {
        guard kind != .all, words.trimmingCharacters(in: .whitespacesAndNewlines) != committed else { return }
        keepKindQuiet = true; kind = .all; keepKindQuiet = false
    }
    func clearRecents() { recents.clear(); recents.save(to: defaults) }
    func removeRecent(_ q: String) { recents.remove(q); recents.save(to: defaults) }
    func submit() { newWordsStartBroad(trimmed); runNow(remember: true) }
    /// Opens a search for a category (a language) without adding it to the person's recent searches.
    func browse(_ words: String) {
        scope = .everything; kind = .all
        if query == words { runNow() } else { query = words; runNow() }
    }

    private func resetResults() {
        generation &+= 1; partialTask?.cancel(); partialTask = nil
        install(Ranked()); nextPages = [:]; canLoadMore = false; state = nil; loadingMore = false; committed = ""; correctedTo = nil
    }

    /// The categories shown on the empty page, from the browsing source. Failing quietly is right: the page just shows no tiles.
    func loadGenres() async {
        guard genres.isEmpty, let p = registry.activeMetadata, let list = try? await MusicDiscoveryFetch.genres(p) else { return }
        genres = MusicDedupe.by(list, key: \.id)
    }

    /// Typing only changes what the field says; suggestions answer it, and the full search runs when the person asks for it.
    private func queryChanged() {
        if trimmed.isEmpty { task?.cancel(); resetResults() }
    }

    private func runNow(remember: Bool = false) {
        task?.cancel(); generation &+= 1
        guard !trimmed.isEmpty else { resetResults(); return }
        committed = trimmed
        task = Task { [weak self] in await self?.search(remember: remember) }
    }

    private func search(remember: Bool = false) async {
        let q = trimmed, k = kind, list = providers
        if scope == .library { searchLibrary(q, remember: remember); return }
        guard !list.isEmpty else { resetResults(); committed = q; state = .failed(Localized.string("No music source is switched on. Switch one on in Settings.")); return }
        state = .loading; loadingMore = false; correctedTo = nil
        let gen = generation
        // Results appear as each source answers; a slow source never holds back the others.
        let outcome = await gather(list, query: q, kind: k, pages: [:]) { [weak self] partial in
            // An answer to a search that was replaced is dropped: only the words the page is now answering may change its results.
            guard let self, !Task.isCancelled, self.committed == q, gen == self.generation else { return }
            self.partialTask?.cancel()
            self.partialTask = Task { [weak self] in
                guard let self else { return }
                if await self.apply(partial.results, replacing: true, query: q, generation: gen), self.hasResults {
                    self.state = .loaded(self.tracks.count + self.artists.count + self.albums.count + self.playlists.count)
                }
            }
        }
        partialTask?.cancel(); partialTask = nil
        if Task.isCancelled { return }
        // A single source that failed is not shown; the page complains only when every source failed.
        guard let outcome else { state = .failed(Localized.string("Could not reach the music service. Check your connection and try again.")); return }
        nextPages = outcome.next
        canLoadMore = k.pages && !outcome.next.isEmpty
        guard await apply(outcome.results, replacing: true, query: q, generation: gen) else { return }
        state = .loaded(tracks.count + artists.count + albums.count + playlists.count)
        MusicGraphIngest.shared.ingest(tracks: tracks, limit: 20)    // fire and forget: nothing here waits for the graph
        if remember, hasResults { recents.add(q); recents.save(to: defaults) }
        // Few answers: the words may be misspelt. A known name that spells or sounds nearly the same is searched too and its results are added.
        // The same goes for a title whose edition notes the source does not match: the looser wording is asked when the exact one found little.
        if tracks.count + artists.count + albums.count < 4, !Task.isCancelled {
            var tried: Set<String> = [MusicText.normalize(q)]
            let spelled = await MusicLocalSuggestions.shared.didYouMean(q)
            for alt in [MusicQueryRelax.relaxed(q), spelled].compactMap({ $0 }) where tried.insert(MusicText.normalize(alt)).inserted {
                if Task.isCancelled { break }
                if let more = await gather(list, query: alt, kind: k, pages: [:]), !Task.isCancelled {
                    guard await apply(more.results, replacing: false, query: alt, generation: gen) else { return }
                    correctedTo = alt
                    state = .loaded(tracks.count + artists.count + albums.count + playlists.count)
                    if tracks.count + artists.count + albums.count >= 4 { break }
                }
            }
        }
        let names = tracks.flatMap { [$0.title] + $0.artists.map(\.name) } + albums.map(\.title) + artists.map(\.name)
        Task { await MusicLocalSuggestions.shared.add(names, kind: .other, weight: 1) }
    }

    private func searchLibrary(_ q: String, remember: Bool) {
        guard let lib = library else { state = .loaded(0); return }
        let hits = MusicLibrarySearch.run(q, liked: lib.liked, playlists: lib.playlists, history: lib.history, artists: lib.followedArtists, albums: lib.savedAlbums)
        install(Self.derive(Ranked(tracks: kind == .all || kind == .songs ? hits.tracks : [], artists: kind == .all || kind == .artists ? hits.artists : [],
                                   albums: kind == .all || kind == .albums ? hits.albums : [], playlists: kind == .all || kind == .playlists ? hits.playlists : []), query: q))
        nextPages = [:]; canLoadMore = false; loadingMore = false
        state = .loaded(tracks.count + artists.count + albums.count + playlists.count)
        if remember, hasResults { recents.add(q); recents.save(to: defaults) }
    }

    func loadMore() {
        guard canLoadMore, !loadingMore else { return }
        let q = trimmed, k = kind, pages = nextPages, gen = generation
        let list = providers.filter { pages[$0.id] != nil }
        guard !list.isEmpty else { canLoadMore = false; return }
        loadingMore = true
        task = Task { [weak self] in
            guard let self else { return }
            let outcome = await gather(list, query: q, kind: k, pages: pages)
            if Task.isCancelled { return }
            loadingMore = false
            guard let outcome else { return }
            nextPages = outcome.next
            canLoadMore = !outcome.next.isEmpty
            guard await apply(outcome.results, replacing: false, query: q, generation: gen) else { return }
            state = .loaded(tracks.count + artists.count + albums.count + playlists.count)
        }
    }

    struct Outcome { var results: [[MusicSearchResult]]; var next: [String: MusicPagination] }

    /// Asks every chosen source at once and reports each answer as it arrives. Gives up on slow sources after the overall cap. nil when no
    /// source answered at all (so the page can say so); partial failure shows what arrived.
    private func gather(_ list: [any MusicMetadataProvider], query: String, kind: MusicSearchKind, pages: [String: MusicPagination],
                        onPartial: (@MainActor (Outcome) -> Void)? = nil) async -> Outcome? {
        func build(_ got: [(Int, MusicSearchChunk)]) -> Outcome {
            let ok = got.sorted { $0.0 < $1.0 }
            var next: [String: MusicPagination] = [:]
            for (_, c) in ok { if let n = c.next { next[c.providerID] = n } }
            return Outcome(results: ok.map { $0.1.results }, next: next)
        }
        return await withTaskGroup(of: (Int, MusicSearchChunk?).self) { group -> Outcome? in
            for (i, p) in list.enumerated() {
                let page = pages[p.id]
                group.addTask { (i, try? await MusicSearchCache.run(provider: p, query: query, kind: kind, page: page)) }
            }
            group.addTask { try? await Task.sleep(for: Self.overallCap); return (-1, nil) }
            var got: [(Int, MusicSearchChunk)] = []
            var pending = list.count
            for await (i, chunk) in group {
                if i < 0 { group.cancelAll(); break }
                pending -= 1
                if let chunk { got.append((i, chunk)); onPartial?(build(got)) }
                if pending == 0 { group.cancelAll(); break }
            }
            return got.isEmpty ? nil : build(got)
        }
    }

    /// One batch of ranked answers plus what the page derives from them. Plain values, so the work runs anywhere.
    struct Ranked: Sendable {
        var tracks: [MusicTrack] = [], artists: [MusicArtist] = [], albums: [MusicAlbum] = [], playlists: [MusicPlaylist] = []
        var relevantArtists: [MusicArtist] = [], dedupedAlbums: [MusicAlbum] = [], dedupedPlaylists: [MusicPlaylist] = []
        var top: MusicSearchResult?
    }

    /// Merges and ranks `lists` (into `existing` when more results are added) and derives what the page shows. Pure: no state, no clock.
    nonisolated static func rank(_ lists: [[MusicSearchResult]], query: String, into existing: Ranked?) -> Ranked {
        var t: [[MusicTrack]] = [], ar: [[MusicArtist]] = [], al: [[MusicAlbum]] = [], pl: [[MusicPlaylist]] = []
        for l in lists {
            t.append(l.compactMap { if case .track(let x) = $0 { x } else { nil } })
            ar.append(l.compactMap { if case .artist(let x) = $0 { x } else { nil } })
            al.append(l.compactMap { if case .album(let x) = $0 { x } else { nil } })
            pl.append(l.compactMap { if case .playlist(let x) = $0 { x } else { nil } })
        }
        let rank = MusicSearchRanker.self
        let nt = rank.mergeTracks(t, query: query)
        let nar = rank.rank(MusicSearchMerge.interleave(ar, key: { rank.normalise($0.name) }), query: query, name: \.name)
        let nal = rank.rank(MusicSearchMerge.interleave(al, key: { rank.normalise($0.title + ($0.artists.first?.name ?? "")) }), query: query, name: \.title)
        let npl = rank.rank(MusicSearchMerge.interleave(pl, key: \.uid), query: query, name: \.name)
        var out = Ranked()
        if let e = existing {
            out.tracks = rank.mergeTracks([e.tracks, nt], query: query); out.artists = MusicSearchMerge.append(e.artists, nar, key: { rank.normalise($0.name) })
            out.albums = MusicSearchMerge.append(e.albums, nal, key: \.uid); out.playlists = MusicSearchMerge.append(e.playlists, npl, key: \.uid)
        } else { out.tracks = nt; out.artists = nar; out.albums = nal; out.playlists = npl }
        return derive(out, query: query)
    }

    /// The lists the page draws, from ranked ones: artists the query points to, albums and playlists without repeats, and the best single match.
    nonisolated static func derive(_ r: Ranked, query: String) -> Ranked {
        var out = r
        out.relevantArtists = MusicArtistRelevance.relevant(r.artists, query: query, tracks: r.tracks, albums: r.albums)
        out.dedupedAlbums = MusicResultDedupe.albums(r.albums)
        out.dedupedPlaylists = MusicResultDedupe.playlists(r.playlists)
        out.top = MusicTopResult.pick(query: query, tracks: r.tracks, artists: out.relevantArtists, albums: out.dedupedAlbums, playlists: out.dedupedPlaylists)
        return out
    }

    private var current: Ranked {
        Ranked(tracks: tracks, artists: artists, albums: albums, playlists: playlists, relevantArtists: relevantArtists, dedupedAlbums: dedupedAlbums, dedupedPlaylists: dedupedPlaylists, top: top)
    }

    private func install(_ r: Ranked) {
        tracks = r.tracks; artists = r.artists; albums = r.albums; playlists = r.playlists
        relevantArtists = r.relevantArtists; dedupedAlbums = r.dedupedAlbums; dedupedPlaylists = r.dedupedPlaylists; top = r.top
    }

    /// Ranks off the main actor (Swift 6.2: async work stays on the caller's actor unless sent elsewhere), then installs the result when it still belongs to
    /// the search that asked for it. Returns false when a newer search replaced this one.
    @discardableResult private func apply(_ lists: [[MusicSearchResult]], replacing: Bool, query: String, generation gen: Int) async -> Bool {
        let existing = replacing ? nil : current
        let r = await Task.detached(priority: .userInitiated) { Self.rank(lists, query: query, into: existing) }.value
        guard gen == generation, !Task.isCancelled else { return false }
        install(r)
        return true
    }
}

// MARK: page

struct MusicSearchPage: View {
    let hub: MusicHub
    @FocusState private var focused: Bool
    @State private var suggest = MusicSuggestModel()
    @State private var highlight: Int?
    @State private var trending = MusicTrendingModel()
    @State private var resultsWidth: CGFloat = 0
    @Environment(\.reddyAccent) private var accent
    @Environment(\.musicLayoutClass) private var cls
    @Environment(\.displayScale) private var displayScale
    private var model: MusicSearchModel { hub.searchModel }

    var body: some View {
        MusicScreen(title: Localized.string("Search")) {
            field(m: Bindable(hub.searchModel).query)
            if model.scopes.count > 1 { scopeSwitch }
            if model.trimmed.isEmpty { emptyPage }
            else if model.isTypingAhead { suggestions }
            else {
                if let c = model.correctedTo {
                    Text(verbatim: Localized.string("Also showing results for “%@”", c)).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                }
                MusicSearchEntitySection(hub: hub, query: model.trimmed, providerNames: providerNames); chips; results
            }
        }
        .task {
            focused = true
            model.library = hub.library
            model.restorePersisted(gated: hub.gated)
            model.resumeIfNeeded()
            model.savePersisted(gated: hub.gated)
            await MusicSuggestFeed.run(library: hub.library, recents: model.recents.items)
            await model.loadGenres()
            MusicGenreArtwork.shared.useSource(hub.registry.activeMetadata)
        }
        .task(id: MusicRegionChoice.shared.region) { await trending.load(hub: hub, region: MusicRegionChoice.shared.region) }
        .onChange(of: model.query) { _, q in
            highlight = nil
            suggest.update(typed: q, registry: hub.registry)
            model.savePersisted(gated: hub.gated)
        }
        .onChange(of: model.kind) { _, _ in model.savePersisted(gated: hub.gated) }
        .onChange(of: model.scope) { _, _ in model.savePersisted(gated: hub.gated) }
        .onDisappear { model.savePersisted(gated: hub.gated); model.cancel(); suggest.cancel() }
    }

    /// What the sources already returned, folded, so the graph section adds only what is new.
    private var providerNames: Set<String> {
        Set((model.artists.map(\.name) + model.albums.map(\.title) + model.playlists.map(\.name) + model.tracks.map(\.title)).map(MusicText.normalize))
    }

    // MARK: field

    private func field(m: Binding<String>) -> some View {
        HStack(spacing: MusicSpace.sm) {
            Image(systemName: "magnifyingglass").font(MusicTokens.iconMedium).foregroundStyle(ColorTokens.textTertiary)
            TextField(model.scope.placeholder, text: m).textFieldStyle(.plain).font(Typography.body).focused($focused)
                .onSubmit { submit() }
                .onKeyPress(.downArrow) { moveHighlight(1) }
                .onKeyPress(.upArrow) { moveHighlight(-1) }
                #if os(macOS)
                .onExitCommand { if model.trimmed.isEmpty { focused = false } else { model.clearQuery() } }
                #endif
                .accessibilityLabel("Search music").atlas("control.music.searchField")
            if !model.query.isEmpty {
                Button { model.clearQuery(); focused = true } label: {
                    Image(systemName: "xmark.circle.fill").font(MusicTokens.iconMedium).frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(ColorTokens.textSecondary).accessibilityLabel("Clear search").atlas("control.music.searchClearSearch")
            }
        }
        .padding(.leading, MusicSpace.md).padding(.trailing, model.query.isEmpty ? MusicSpace.md : MusicSpace.xxs).frame(height: 44).frame(maxWidth: 680)
        .podcastFieldStyle(focused: focused, accent: accent)
    }

    private var scopeSwitch: some View {
        MusicQuietChoice(label: Localized.string("Search in"), options: model.scopes, title: { $0.title }, selection: Binding(get: { model.scope }, set: { model.scope = $0 }))
            .accessibilityElement(children: .contain).accessibilityLabel("Where to search")
    }

    private var chips: some View {
        ScrollView(.horizontal) {
            MusicUnderlineTabs(tabs: Array(MusicSearchKind.allCases), title: { $0.title }, selection: Binding(get: { model.kind }, set: { model.kind = $0 }))
        }
        .scrollIndicators(.hidden)
    }

    // MARK: suggestions

    private var suggestionRows: [MusicSuggestionRow] {
        let tracks = suggest.forQuery == model.trimmed || suggest.forQuery.isEmpty ? suggest.tracks : []
        let completions = MusicSuggest.completions(typed: model.query, recents: model.recents.items, local: suggest.local, tracks: tracks)
        return MusicSuggest.rows(typed: model.query, completions: completions, tracks: model.scope == .library ? [] : tracks, correction: suggest.correction)
    }

    @ViewBuilder private var suggestions: some View {
        let rows = suggestionRows
        MusicSuggestPanel(hub: hub, typed: model.query, rows: rows, loading: suggest.loading && model.scope != .library, highlight: $highlight,
                          choose: { choose($0) }, fill: { model.query = $0 + " "; focused = true })
    }

    private func moveHighlight(_ delta: Int) -> KeyPress.Result {
        guard model.isTypingAhead else { return .ignored }
        highlight = MusicSuggest.move(highlight, by: delta, count: suggestionRows.count)
        return .handled
    }

    private func submit() {
        let rows = suggestionRows
        if model.isTypingAhead, let h = highlight, rows.indices.contains(h) { choose(rows[h]) } else { model.submit() }
    }

    private func choose(_ row: MusicSuggestionRow) {
        switch row {
        case .search(let s): model.query = s; model.submit()
        case .correction(let s): model.query = s; model.submit()
        case .completion(let s): model.useRecent(s)
        case .track(let t): hub.play([t], at: 0)
        }
    }

    // MARK: empty page

    @ViewBuilder private var emptyPage: some View {
        let items = model.recents.chips
        if !items.isEmpty { recents(items) }
        if model.scope == .everything && !hub.gated { MusicTrendingBlock(hub: hub, model: trending) { model.useRecent($0) } }
        if !model.genres.isEmpty && model.scope == .everything { categories }
        if items.isEmpty && model.genres.isEmpty && (model.scope != .everything || hub.gated) {
            MusicEmptyState(symbol: "magnifyingglass", title: Localized.string("Find something to play"), message: Localized.string("Search for a song, an artist, an album or a playlist."))
        }
    }

    private func recents(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            HStack {
                MusicSectionTitle(title: Localized.string("Recent searches"))
                Spacer()
                Button("Clear") { model.clearRecents() }.musicButton(.tertiary, size: .compact)
                    .accessibilityLabel("Clear recent searches").atlas("control.music.searchClearRecentSearches")
            }
            MusicChipFlow(spacing: MusicSpace.xs) {
                ForEach(items, id: \.self) { q in MusicRecentChip(query: q, open: { model.useRecent(q) }, remove: { model.removeRecent(q) }) }
            }
            Text("Recent searches stay on this Mac.").musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Browse all: every category as a cover tile.
    private var categories: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            MusicSectionTitle(title: Localized.string("Browse all"))
            MusicCategoryGrid(categories: model.genres.map { MusicCategory(name: $0.name, kind: .genre, target: .genre($0), thumbnails: $0.thumbnails) },
                              owner: "search.categories") { c in
                if case .genre(let g) = c.target { hub.open(.genre(g)) }
            }
        }
    }

    // MARK: results

    @ViewBuilder private var results: some View {
        switch model.state {
        case nil:
            // A restored or resumed search is about to run: a skeleton, never a blank page.
            if !model.hasResults && model.committed == model.trimmed {
                VStack(alignment: .leading, spacing: MusicSpace.sm) { ForEach(0..<6, id: \.self) { _ in MusicSkeletonRow() } }
                    .musicSkeletonShimmer().accessibilityElement().accessibilityLabel(Localized.string("Loading"))
            }
        case .loading?:
            if !model.hasResults {
                VStack(alignment: .leading, spacing: MusicSpace.sm) { ForEach(0..<6, id: \.self) { _ in MusicSkeletonRow() } }
                    .musicSkeletonShimmer().accessibilityElement().accessibilityLabel(Localized.string("Loading"))
            } else { resultBody }
        case .failed(let m)?: MusicErrorView(message: m) { model.submit() }
        case .loaded?:
            if model.hasResults { resultBody }
            else {
                MusicEmptyState(symbol: "magnifyingglass", title: nothingFoundTitle, message: nothingFoundHint)
            }
        }
    }

    private var nothingFoundTitle: String {
        model.kind == .all ? model.scope.nothingFound(for: model.trimmed)
            : Localized.string("No matches for “%@”.", model.trimmed)
    }
    private var nothingFoundHint: String {
        model.kind == .all ? Localized.string("Check the spelling or try fewer words.") : Localized.string("Pick All to look everywhere.")
    }

    @ViewBuilder private var resultBody: some View {
        let k = model.kind
        // Artists the query and the best songs and albums do not point to are not shown under All; their own chip lists everything.
        // Worked out once when the results arrived (off the main actor), not on every redraw.
        let artists = k == .all ? model.relevantArtists : model.artists
        let albums = model.dedupedAlbums
        let playlists = model.dedupedPlaylists
        let top = k == .all ? model.top : nil
        let showSongs = (k == .all || k == .songs) && !model.tracks.isEmpty
        let sideBySide = MusicSearchLayout.sideBySide(cls) && top != nil && showSongs
        let leftArtists = MusicSearchBalance.leftArtists(sideBySide: sideBySide, songRows: min(model.tracks.count, MusicSearchLayout.songLimit(cls)), artists: artists.count)
        VStack(alignment: .leading, spacing: MusicSpace.xl) {
            if sideBySide, let top {
                HStack(alignment: .top, spacing: MusicSpace.xl) {
                    VStack(alignment: .leading, spacing: MusicSpace.lg) {
                        MusicTopResultCard(result: top, hub: hub)
                        if leftArtists > 0 { compactArtists(artists, shown: leftArtists) }
                    }
                    .frame(width: MusicSearchLayout.topCardWidth)
                    songsGroup(k)
                }
            } else {
                if let top { MusicTopResultCard(result: top, hub: hub) }
                if showSongs { songsGroup(k) }
            }
            if (k == .all || k == .artists), !artists.isEmpty, leftArtists == 0 {
                group(Localized.string("Artists"), kind: .artists, count: artists.count) {
                    ForEach(visible(artists), id: \.uid) { a in MusicCard(artist: a, hub: hub, width: nil) }
                }
            }
            if (k == .all || k == .albums), !albums.isEmpty {
                group(Localized.string("Albums"), kind: .albums, count: albums.count) {
                    ForEach(visible(albums), id: \.uid) { a in MusicCard(album: a, hub: hub, width: nil) }
                }
            }
            if (k == .all || k == .playlists), !playlists.isEmpty {
                group(Localized.string("Playlists"), kind: .playlists, count: playlists.count) {
                    ForEach(visible(playlists), id: \.uid) { p in MusicCard(playlist: p, hub: hub, width: nil) }
                }
            }
            if k != .all && k != .songs && (model.canLoadMore || model.loadingMore) {
                HStack {
                    Spacer()
                    if model.loadingMore { MusicLoadingIcon(size: MusicIconSize.small) }
                    else { Button("Load more") { model.loadMore() }.musicButton(.secondary).accessibilityLabel("Load more results").atlas("control.music.searchLoadMoreResults") }
                    Spacer()
                }
            }
        }
        .musicReadWidth($resultsWidth)
        .task(id: prefetchSignature) { prefetchCovers() }
        .onDisappear { MusicArtworkPrefetcher.shared.cancel(owner: "search.results") }
    }

    private var capacity: Int { MusicSearchLayout.rowCapacity(width: resultsWidth, cls: cls) }

    /// All of a type's items when its chip is chosen; one row of them under All (the group's See all opens the rest).
    private func visible<T>(_ items: [T]) -> [T] {
        Array(items.prefix(MusicSearchLayout.visibleCount(total: items.count, capacity: capacity, kind: model.kind)))
    }

    /// The artists list under the Top result: circular portraits (or initials) and names, so the left column is as long as the songs beside it.
    private func compactArtists(_ artists: [MusicArtist], shown: Int) -> some View {
        VStack(alignment: .leading, spacing: MusicSpace.xxs) {
            groupHeader(Localized.string("Artists"), more: .artists, count: artists.count, shown: shown)
            ForEach(Array(artists.prefix(shown)), id: \.uid) { a in MusicArtistRow(artist: a, hub: hub) }
        }
    }

    @ViewBuilder private func songsGroup(_ k: MusicSearchKind) -> some View {
        let limit = MusicSearchLayout.songLimit(cls)
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            if k == .all { groupHeader(Localized.string("Songs"), more: .songs, count: model.tracks.count, shown: limit) }
            MusicTrackList(hub: hub, tracks: k == .all ? Array(model.tracks.prefix(limit)) : model.tracks, showsTools: k == .songs, numbered: false,
                           hasMore: k == .songs && model.canLoadMore, loadingMore: model.loadingMore,
                           loadMore: { model.loadMore() }, retry: { model.loadMore() })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var prefetchSignature: String { "\(model.committed)|\(model.kind.rawValue)|\(model.albums.count)|\(model.artists.count)|\(model.playlists.count)|\(capacity)" }

    private func prefetchCovers() {
        let px = MusicArtworkClass.tile.pixels(scale: displayScale)
        var urls: [String] = []
        urls += model.artists.prefix(capacity).compactMap { MusicArtworkService.pickThumbnail($0.thumbnails, neededPixels: px) }
        urls += model.albums.prefix(capacity).compactMap { MusicArtworkService.pickThumbnail($0.thumbnails, neededPixels: px) }
        urls += model.playlists.prefix(capacity).compactMap { MusicArtworkService.pickThumbnail($0.thumbnails, neededPixels: px) }
        MusicArtworkPrefetcher.shared.prefetch(addresses: urls, artworkClass: .tile, scale: displayScale, priority: .normal, owner: "search.results")
    }

    private func groupHeader(_ title: String, more: MusicSearchKind, count: Int, shown: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            MusicSectionTitle(title: title)
            Spacer()
            if model.kind == .all, MusicSearchLayout.showsSeeAll(total: count, shown: shown) {
                Button("See all") { model.kind = more }
                    .musicButton(.tertiary, size: .compact).accessibilityLabel("See all \(title)").atlas("control.music.seeAll")
            }
        }
    }

    /// A group of cards in a grid as wide as the page allows. No sideways scrolling and no arrows: what does not fit one row is behind See all.
    private func group<C: View>(_ title: String, kind: MusicSearchKind, count: Int, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            groupHeader(title, more: kind, count: count, shown: capacity)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: MusicSpace.md, alignment: .top), count: capacity), alignment: .leading, spacing: MusicSpace.lg) { content() }
        }
    }
}

/// One artist in the compact list: a 44 pt circle, the name and "Artist". Opens the artist.
struct MusicArtistRow: View {
    let artist: MusicArtist
    let hub: MusicHub
    static let portrait: CGFloat = 44

    var body: some View {
        Button { hub.open(.artist(artist), nameSearch: hub.searchModel.committed.isEmpty ? hub.searchModel.query : hub.searchModel.committed) } label: {
            HStack(spacing: MusicSpace.sm) {
                MusicCoverImage(thumbs: MusicArtistPortrait.portraits(artist.thumbnails), artworkClass: .artistPortrait, size: Self.portrait, corner: MusicCardGeometry.roundCorner,
                                seed: artist.name, initials: MusicArtistPortrait.initials(artist.name), subject: .derive(artist))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: MusicSpace.xxs / 2) {
                    Text(verbatim: artist.name).musicText(.card).lineLimit(1).foregroundStyle(ColorTokens.textPrimary)
                    Text("Artist").musicText(.caption).foregroundStyle(ColorTokens.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, MusicSpace.xxs).frame(minHeight: MusicTokens.hitTarget).contentShape(Rectangle())
        }
        .buttonStyle(.plain).hoverHighlight()
        .contextMenu { MusicCardMenu(entity: .artist(artist), hub: hub) }
        .accessibilityLabel("Open artist \(artist.name)").atlas("control.music.searchArtistRow")
    }
}

/// The best match for the words typed: a 72 pt cover, what it is, and Play and Start radio.
struct MusicTopResultCard: View {
    let result: MusicSearchResult
    let hub: MusicHub
    @Environment(\.reddyAccent) private var accent

    private var entity: MusicEntity? {
        switch result {
        case .track(let t): .track(t); case .artist(let a): .artist(a); case .album(let a): .album(a); case .playlist(let p): .playlist(p); case .user: nil
        }
    }
    private var thumbs: [MusicThumbnail] {
        switch result { case .track(let t): t.thumbnails; case .artist(let a): MusicArtistPortrait.portraits(a.thumbnails); case .album(let a): a.thumbnails; case .playlist(let p): p.thumbnails; case .user(let u): u.thumbnails }
    }
    private var title: String { entity?.title ?? "" }
    private var round: Bool { if case .artist = result { true } else { false } }
    private var subtitle: String {
        switch result {
        case .track(let t): [Localized.string("Song"), t.artistLine].filter { !$0.isEmpty }.joined(separator: " · ")
        case .artist: Localized.string("Artist")
        case .album(let a): [Localized.string("Album"), a.artists.first?.name ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        case .playlist(let p): [Localized.string("Playlist"), p.trackCount.flatMap { $0 > 0 ? Localized.plural($0, one: "%@ song", other: "%@ songs") : nil } ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        case .user: ""
        }
    }

    var body: some View {
        if let entity {
            HStack(spacing: 16) {
                MusicCoverImage(thumbs: thumbs, artworkClass: round ? .artistPortrait : .tile, size: 72, corner: round ? 36 : MusicTokens.radiusCard,
                                seed: title, initials: round ? MusicArtistPortrait.initials(title) : nil, subject: .derive(entity))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top result").font(Typography.eyebrow).tracking(1.2).foregroundStyle(ColorTokens.textTertiary).textCase(.uppercase)
                    Text(verbatim: title).font(Typography.title).lineLimit(2)
                    Text(verbatim: subtitle).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
                    HStack(spacing: 10) {
                        Button { Task { await MusicEntityActions.play(entity, hub: hub) } } label: { Label("Play", systemImage: "play.fill") }
                            .musicButton(.hero, size: .large)
                            .accessibilityLabel("Play \(title)").atlas("control.music.topResultPlay")
                        Button { Task { await MusicEntityActions.startRadio(entity, hub: hub) } } label: { Label("Start radio", systemImage: "dot.radiowaves.left.and.right") }
                            .musicButton(.secondary, size: .large)
                            .accessibilityLabel("Start radio from \(title)").atlas("control.music.topResultRadio")
                    }
                    .padding(.top, 6)
                }
                Spacer(minLength: 0)
            }
            .padding(Spacing.lg).frame(maxWidth: 680, alignment: .leading)
            .background(ColorTokens.elevated.opacity(0.55), in: RoundedRectangle(cornerRadius: MusicTokens.radiusPanel, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: MusicTokens.radiusPanel, style: .continuous).strokeBorder(ColorTokens.line, lineWidth: 0.75))
            .contentShape(Rectangle())
            .onTapGesture { if case .track = entity { return } else { MusicEntityActions.open(entity, hub: hub) } }
            .contextMenu { MusicCardMenu(entity: entity, hub: hub) }
            .accessibilityElement(children: .contain).atlas("control.music.searchPlay")
        }
    }
}

// MARK: - Layout decisions (pure)

/// How the results page lays its groups out. Pure functions of the layout class and the width, so they are tested without a screen.
enum MusicSearchLayout {
    static let minCardWidth: CGFloat = MusicCardSize.standard.width
    static let cardSpacing: CGFloat = MusicSpace.md
    static let topCardWidth: CGFloat = 400
    static let maxColumns = 6

    enum GroupStyle: Equatable { case list, row, grid }

    /// Songs are a list; the other types are one row of cards under All and a full grid under their own chip.
    static func style(_ kind: MusicSearchKind, chosen: MusicSearchKind) -> GroupStyle {
        if kind == .songs { return .list }
        return chosen == .all ? .row : .grid
    }

    /// Cards that fit one row of `width` points (2 to 6); before the width is known the layout class decides.
    static func rowCapacity(width: CGFloat, cls: MusicLayoutClass) -> Int {
        guard width.isFinite, width > 0 else { return min(max(MusicLayoutGrid.columns(for: cls), 2), maxColumns) }
        return min(max(Int(((width + cardSpacing) / (minCardWidth + cardSpacing)).rounded(.down)), 2), maxColumns)
    }

    static func visibleCount(total: Int, capacity: Int, kind: MusicSearchKind) -> Int { kind == .all ? min(total, capacity) : total }
    static func showsSeeAll(total: Int, shown: Int) -> Bool { total > shown }
    static func songLimit(_ cls: MusicLayoutClass) -> Int { cls >= .expanded ? 8 : (cls == .medium ? 6 : 5) }
    /// The Top result card sits beside the songs when there is room for both.
    static func sideBySide(_ cls: MusicLayoutClass) -> Bool { cls >= .expanded }
}

/// A recent search as a chip: the words (run again) and a remove button, each its own control of at least 28 pt.
struct MusicRecentChip: View {
    let query: String
    let open: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: MusicSpace.xxs) {
            Button(action: open) {
                Text(verbatim: query).lineLimit(1).frame(maxWidth: 240)
            }
            .musicButton(.chip, size: .compact)
            .musicTooltip(verbatim: query)
            .accessibilityLabel("Search for \(query)").atlas("control.music.searchSearchFor")
            Button(action: remove) {
                Image(systemName: "xmark")
            }
            .musicButton(.icon, size: .compact)
            .musicTooltip(verbatim: Localized.string("Remove from recent searches"))
            .accessibilityLabel("Remove \(query) from recent searches").atlas("control.music.searchRemoveFromRecentSearches")
        }
    }
}

/// Lays its children out left to right and wraps to a new line when the row is full.
struct MusicChipFlow: Layout {
    var spacing: CGFloat = MusicSpace.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = arrange(width: bounds.width, subviews: subviews)
        for (i, f) in r.frames.enumerated() { subviews[i].place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: ProposedViewSize(f.size)) }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        var frames: [CGRect] = []
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: s))
            x += s.width + spacing; rowH = max(rowH, s.height); maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: width.isFinite ? width : maxX, height: y + rowH), frames)
    }
}
