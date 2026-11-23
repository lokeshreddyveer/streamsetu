import Foundation
import os

/// The credential for the weekly trending list: the person's own key, else the built-in token (see TMDBAccess).
struct SmartMixKeyProvider: SMTMDBKeyProvider {
    let access: TMDBAccess
    init(credentials: CredentialStore, defaults: UserDefaults) {
        access = TMDBAccess(ownKey: { ((try? credentials.load(ref: MetadataMatchService.keyRef)) ?? nil)?.password?.trimmingCharacters(in: .whitespacesAndNewlines) }, defaults: defaults)
    }
    var apiKey: String? { access.credential()?.secret }
    func reportRejected() { if access.source == .builtIn { access.markBuiltInRejected() } }
}

/// The weekly list kept in the app's own defaults: at most one list, at most 180 days, removed when the switch is off or the key is removed.
final class DefaultsTrendingCache: SMTrendingCacheStore, @unchecked Sendable {
    static let key = "smartmix.trending.cache"
    private let defaults: UserDefaults
    init(_ d: UserDefaults) { defaults = d }
    func load() -> SMTrendingCache? { defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(SMTrendingCache.self, from: $0) } }
    func save(_ cache: SMTrendingCache) { if let d = try? JSONEncoder().encode(cache) { defaults.set(d, forKey: Self.key) } }
    func clear() { defaults.removeObject(forKey: Self.key) }
}

struct SMGenreCount: Sendable, Equatable { var key: String; var count: Int }

struct SmartMixHomeResult: Sendable {
    var genreIndex: [SMGenreCount] = []
    var shelves: [DiscoverShelf]
    var heroOrder: [LibraryItem]
    var diagnostics: [String: SMDiagnostics]
    var folderItems: [LibraryItem] = []
}

/// Owns the Smart Mix pieces for the app and turns engine output into the shelves Home already draws. Everything heavy runs off the main thread.
final class SmartMixCoordinator: @unchecked Sendable {
    static let enabledKey = "smartmix.trending.enabled"
    static let homeShelf = "_home"

    let source: SQLiteSmartMixCandidateSource
    let state: SQLiteSmartMixStateStore
    let session: SmartMixSession
    let trending: SMTrendingService
    let lists: SMListsService
    private let db: DatabaseManager
    private let catalog: SQLiteCatalogRepository
    private let memory: RecommendationMemory
    private let keys: SMTMDBKeyProvider
    private let defaults: UserDefaults

    init(db: DatabaseManager, catalog: SQLiteCatalogRepository, memory: RecommendationMemory, credentials: CredentialStore, defaults: UserDefaults, session: URLSession = .shared) {
        self.db = db; self.catalog = catalog; self.memory = memory; self.defaults = defaults
        keys = SmartMixKeyProvider(credentials: credentials, defaults: defaults)
        source = SQLiteSmartMixCandidateSource(db: db)
        state = SQLiteSmartMixStateStore(db: db)
        trending = SMTrendingService(fetcher: SMTMDBTrendingClient(keys: keys, session: session), cache: DefaultsTrendingCache(defaults), policy: SMTrendingPolicy())
        lists = SMListsService(fetcher: SMTMDBListClient(keys: keys, session: session), cache: DefaultsListsCache(defaults), policy: SMTrendingPolicy())
        self.session = SmartMixSession(source: source, state: state, trending: trending, lists: lists)
        Task { await self.trending.setPolicy(self.policy()); await self.lists.setPolicy(self.policy()) }
    }

    // MARK: TMDB switch

    var trendingEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.enabledKey); applyPolicy(); invalidate(.prefsChange) }
    }
    var hasOwnKey: Bool { !(keys.apiKey ?? "").isEmpty }
    /// ON by default, active only with the person's own key.
    func policy() -> SMTrendingPolicy { var p = SMTrendingPolicy(); p.enabled = trendingEnabled; p.hasOwnKey = hasOwnKey; return p }
    func applyPolicy() { let p = policy(); Task { await trending.setPolicy(p); await lists.setPolicy(p) } }
    /// Fetches the public weekly list when due (a request carries no information about the person). Fire and forget.
    func refreshTrendingIfNeeded() { Task.detached(priority: .utility) { [trending] in _ = await trending.refreshIfNeeded(now: Date()) } }

    /// Fetches the all-time list and the genre lists of today's genre shelves when due. Fire and forget; without TMDB access nothing is requested.
    func refreshListsIfNeeded(genres: [String]) {
        let keys = [SMListKey.top] + genres.flatMap { [SMListKey.week($0), SMListKey.allTime($0)] }
        Task.detached(priority: .utility) { [lists] in await lists.refresh(keys, now: Date()) }
    }

    // MARK: shelf mode (Trending in Your Library and every genre shelf): this week or all-time top, remembered per profile and shelf

    func mode(profile: String, shelf: String) -> SMShelfMode { SMShelfModes.get(defaults, profile: profile, shelf: shelf) }
    func setMode(_ mode: SMShelfMode, profile: String, shelf: String) {
        SMShelfModes.markChosen(defaults, profile: profile, shelf: shelf)
        SMShelfModes.set(defaults, mode, profile: profile, shelf: shelf)       // no invalidation: the session keeps each view of a shelf under its own key
    }

    // MARK: invalidation

    func invalidate(_ event: SMInvalidation) {
        switch event {
        case .lockOrRestrictionChange: source.bump(\.restrict)
        case .hideChange: source.bump(\.hidden)
        case .profileSwitch: source.bump(\.profileEpoch)
        case .syncChanged: source.bump(\.catalog)
        case .dismissChange: source.bump(\.dismiss)
        case .prefsChange: source.bump(\.prefs)
        case .memoryWarning: break
        }
        Task { [session] in await session.invalidate(event) }
    }

    // MARK: reshuffle and dismiss (neither starts a sync, neither touches playback history)

    func reshuffle(profile: String) {
        state.bumpRefresh(profile: profile, shelves: [Self.homeShelf])
        Task { [session] in await session.invalidate(.prefsChange) }
    }

    /// "Remove from Continue Watching" also stops recommending the title: only the marker is written.
    @discardableResult func dismiss(profile: String, itemID: String) -> Bool {
        let ok = (try? memory.dismiss(profileID: profile, itemID: itemID)) ?? false
        if ok { invalidate(.dismissChange) }
        return ok
    }
    func undismiss(profile: String, itemID: String) { try? memory.undismiss(profileID: profile, itemID: itemID); invalidate(.dismissChange) }

    // MARK: Home

    /// nil when the identity table is not ready (the caller keeps the older Home) or the build failed.
    func home(profile: String, sourceID: UUID?, preferredLanguage: String, kids: Bool = false, now: Date = Date()) async -> SmartMixHomeResult? {
        guard source.coverageOK() else { return nil }
        let lang = OtherLanguages.preferredName(preferredLanguage)
        source.configure(sourceID: sourceID, preferredLanguage: lang)
        let cur = await trending.current(now: now)
        var tk = Set<String>()
        for e in cur.entries ?? [] { tk.insert(IdentityKey.make(e.title)); if let o = e.original, !o.isEmpty { tk.insert(IdentityKey.make(o)) } }
        source.setTrendingKeys(tk)
        let ctx = context(profile: profile, lang: lang, kids: kids, now: now, modes: [:])
        var results: [SMShelfResult] = []
        for attempt in 0..<2 {
            do { results = try await session.shelves(SMShelf.all + SMShelf.contextual + [SMShelf.genresAuto], ctx: ctx, now: now, commit: true); break }
            catch SmartMixSession.SessionError.stale { if attempt == 1 { return nil } }
            catch { return nil }
        }
        // Default view per row: a row the person never chose opens on "All time" when this week's list found too few titles here and the all-time list found enough.
        var autoModes = Set<String>(), ctx2 = ctx
        let candidates = results.filter { ($0.shelfId == SMShelf.trendingLibrary || SMShelf.isGenre($0.shelfId)) && !$0.isHidden && $0.diag.caption != .trendingTMDB
            && SMShelfModes.chosen(defaults, profile: profile, shelf: $0.shelfId) == nil }
        if !candidates.isEmpty {
            var probe = ctx
            for c in candidates { probe.modes[c.shelfId] = .allTime }
            if let alt = try? await session.shelves(candidates.map(\.shelfId), ctx: probe, now: now, commit: false) {
                for r in alt where r.diag.caption == .trendingTMDB && !r.isHidden {
                    let pick = SMModeDefault.choose(chosen: nil, weeklyOrdered: false, allTimeOrdered: true)
                    guard pick.auto, let i = results.firstIndex(where: { $0.shelfId == r.shelfId }) else { continue }
                    results[i] = r; autoModes.insert(r.shelfId); ctx2.modes[r.shelfId] = .allTime
                }
            }
        }
        return await materialize(results, language: lang, ctx: ctx2, autoModes: autoModes, sourceID: sourceID, now: now)
    }

    /// The one-line subtitle of a ranked shelf (short on purpose: it sits beside the two-option control and must never truncate).
    static func viewCaption(mode: SMShelfMode, tmdb: Bool) -> String {
        switch (mode, tmdb) { case (.weekly, true): "Trending this week"; case (.weekly, false): "Popular here"; case (.allTime, true): "Best of all time"; case (.allTime, false): "Highest rated here" }
    }

    private static let signposter = OSSignposter(subsystem: "app.streamsetu.mac", category: "SmartMix")
    /// How many section-local view builds ran (a test reads it: switching a shelf's view never builds Home).
    private(set) nonisolated(unsafe) static var shelfViewBuilds = 0

    private func context(profile: String, lang: String?, kids: Bool, now: Date, modes overrides: [String: SMShelfMode]) -> SMContext {
        let affinity = (try? db.read { try Self.affinity($0, profile: profile) }) ?? SMAffinity()
        var modes: [String: SMShelfMode] = [:]
        for id in [SMShelf.trendingLibrary] + SMGenres.table.map({ SMGenres.shelfId($0.key) }) { let m = mode(profile: profile, shelf: id); if m != .weekly { modes[id] = m } }
        for (k, v) in overrides { modes[k] = v }
        var ctx = SMContext(profile: profile, dayKey: FeaturedPolicy.dayKey(now), refreshCounter: state.refreshCounter(profile: profile, shelf: Self.homeShelf), preferredLang: lang, affinity: affinity)
        ctx.poolCap = nil; ctx.kids = kids; ctx.modes = modes; ctx.oversample = 10
        return ctx
    }

    /// Section-local switch: the one shelf (`smartID`: "trending-library" or "genre:<key>") in the given view, built on its own. Nothing else is rebuilt, nothing is committed
    /// (repeat suppression untouched), and the session keeps both views of a shelf (the cache key has the view), so switching back is instant.
    /// `then` = views to warm in the background afterwards (the other view of each listed shelf), in one pass over the pool.
    func shelfView(profile: String, sourceID: UUID?, preferredLanguage: String, smartID: String, mode: SMShelfMode, kids: Bool = false, avoid: Set<String> = [], now: Date = Date()) async -> DiscoverShelf? {
        let sp = Self.signposter, sid = sp.makeSignpostID(), whole = sp.beginInterval("shelfView", id: sid)
        defer { sp.endInterval("shelfView", whole) }
        guard source.coverageOK() else { return nil }
        Self.shelfViewBuilds += 1
        let lang = OtherLanguages.preferredName(preferredLanguage)
        source.configure(sourceID: sourceID, preferredLanguage: lang)
        let ctx = context(profile: profile, lang: lang, kids: kids, now: now, modes: [smartID: mode])
        for attempt in 0..<2 {
            do {
                let r = try await session.shelves([smartID], ctx: ctx, now: now, commit: false)
                return await materialize(r, language: lang, ctx: ctx, sourceID: sourceID, now: now, avoid: avoid).shelves.first
            } catch SmartMixSession.SessionError.stale { if attempt == 1 { return nil } }
            catch { return nil }
        }
        return nil
    }

    /// Builds the other view of the given shelves (smart ids with the view they show now) in one pass, so toggling is instant. Result is only the session cache.
    func warmOtherViews(profile: String, sourceID: UUID?, preferredLanguage: String, shelves: [(id: String, mode: SMShelfMode)], kids: Bool = false, now: Date = Date()) async {
        guard !shelves.isEmpty, source.coverageOK() else { return }
        let lang = OtherLanguages.preferredName(preferredLanguage)
        source.configure(sourceID: sourceID, preferredLanguage: lang)
        var other: [String: SMShelfMode] = [:]
        for s in shelves { other[s.id] = s.mode == .weekly ? .allTime : .weekly }
        let ctx = context(profile: profile, lang: lang, kids: kids, now: now, modes: other)
        _ = try? await session.shelves(shelves.map(\.id), ctx: ctx, now: now, commit: false)
    }

    // MARK: folder rows

    static func folderKey(kind: ContentKind, name: String) -> String { "\(kind.rawValue)|\(IdentityKey.words(name).joined(separator: " "))" }

    /// About 12 tiles for one folder from the engine's folder shelf: quality and newness first, lightly shuffled, stable for the session, titles shown recently held back.
    /// Never called for a locked or hidden folder; restricted titles are excluded by the engine whatever the session says.
    func folderItems(profile: String, sourceID: UUID?, kind: ContentKind, folderName: String, preferredLanguage: String, now: Date = Date()) async -> [LibraryItem] {
        guard source.coverageOK() else { return [] }
        let lang = OtherLanguages.preferredName(preferredLanguage)
        source.configure(sourceID: sourceID, preferredLanguage: lang)
        let ctx = SMContext(profile: profile, dayKey: FeaturedPolicy.dayKey(now), refreshCounter: state.refreshCounter(profile: profile, shelf: Self.homeShelf), preferredLang: lang)
        let id = SMShelf.folder(Self.folderKey(kind: kind, name: folderName))
        for attempt in 0..<2 {
            do {
                let r = try await session.shelves([id], ctx: ctx, now: now, commit: true)
                return await materialize(r, language: lang).folderItems
            } catch SmartMixSession.SessionError.stale { if attempt == 1 { return [] } }
            catch { return [] }
        }
        return []
    }

    /// Remembers that a folder was opened (for "recent first"). Device-local, per profile.
    func noteFolderOpened(profile: String, categoryID: String) {
        _ = try? db.write { try $0.execute("INSERT INTO folder_recent(profile_id, category_id, last_opened_at, opens) VALUES(?,?,?,1) ON CONFLICT(profile_id, category_id) DO UPDATE SET last_opened_at = excluded.last_opened_at, opens = opens + 1", [profile, categoryID, Date()]) }
    }

    func recentFolders(profile: String) -> [String] {
        (try? db.read { try $0.query("SELECT category_id FROM folder_recent WHERE profile_id=? ORDER BY last_opened_at DESC LIMIT 30", [profile]) { $0.string(0) } }) ?? []
    }

    private func materialize(_ results: [SMShelfResult], language: String?, ctx: SMContext? = nil, autoModes: Set<String> = [], sourceID: UUID? = nil, now: Date = Date(), avoid: Set<String> = []) async -> SmartMixHomeResult {
        let catalog = self.catalog, db = self.db
        let day = SMDayContext(date: now)
        return await Task.detached { () -> SmartMixHomeResult in
            // One batched check that every title may be shown (not locked, not hidden, no copy in such a folder), then plain reads: asking the restricted view title by title costs seconds when many folders are locked.
            let ok = (try? catalog.recommendableIDs(results.flatMap { $0.picks.map(\.id) + $0.collections.flatMap(\.memberIds) })) ?? []
            func item(_ id: String, _ kind: SMKind) -> LibraryItem? {
                guard ok.contains(id) else { return nil }
                if kind == .series { return (try? catalog.seriesItem(id: id)).flatMap { $0 }.map { .series($0) } }
                return (try? catalog.movie(id: id)).flatMap { $0 }.map { .movie($0) }
            }
            func item(_ p: SMPick) -> LibraryItem? { item(p.id, p.kind) }
            let kids = ctx?.kids ?? false
            var shelves: [DiscoverShelf] = [], hero: [LibraryItem] = [], folder: [LibraryItem] = [], diags: [String: SMDiagnostics] = [:], genreIndex: [SMGenreCount] = []
            var rowResults: [SMShelfResult] = []
            for r in results {
                diags[r.shelfId] = r.diag
                if r.shelfId == SMShelf.genresIndex {
                    genreIndex = SMGenres.table.filter { (r.genreCounts[$0.key] ?? 0) >= SMGenres.minTitles && (!kids || $0.kidsSafe) }.map { SMGenreCount(key: $0.key, count: r.genreCounts[$0.key] ?? 0) }
                } else if r.shelfId == SMShelf.hero { if !r.isHidden { hero = r.picks.prefix(12).compactMap(item) } }
                else if SMShelf.isFolder(r.shelfId) { if !r.isHidden { folder = r.picks.compactMap(item) } }
                else if !r.isHidden { rowResults.append(r) }
            }
            // Composition: one title per screen (priority = display order), re-rank for variety, exploration slots, placement by weekday and time of day.
            let affinity = ctx?.affinity ?? SMAffinity()
            var rows: [SMComposedRow]
            if rowResults.count == 1, let only = rowResults.first, only.shelfId != SMShelf.collections {
                rows = [SMComposedRow(shelfId: only.shelfId, picks: SMCompose.single(only, avoid: avoid, affinity: affinity))]
            } else {
                rows = SMCompose.compose(results: rowResults, affinity: affinity, context: day, kids: kids, seed: ctx)
            }
            let byId = Dictionary(rowResults.map { ($0.shelfId, $0) }, uniquingKeysWith: { a, _ in a })
            func local(_ s: String, _ args: CVarArg...) -> String { args.isEmpty ? Localized.string(s) : Localized.string(s, args[0]) }
            for row in rows {
                guard let r = byId[row.shelfId] else { continue }
                var items = row.picks.compactMap(item)
                let id = row.shelfId, tmdb = r.diag.caption == .trendingTMDB
                if id == SMShelf.collections {
                    var tiles: [CollectionTile] = []
                    for c in r.collections {
                        let members = c.memberIds.prefix(30).compactMap { mid in r.picks.first { $0.id == mid }.flatMap(item) ?? (item(mid, .movie) ?? item(mid, .series)) }
                        guard members.count >= SMCollections.minTitles, let lead = row.picks.first(where: { $0.franchise == c.key }).flatMap(item) ?? members.first else { continue }
                        tiles.append(CollectionTile(id: c.key, name: SMFranchise.name(titles: members.map(\.title), key: c.key), lead: lead, members: members, count: members.count))
                    }
                    guard tiles.count >= SMCollections.minTiles else { continue }
                    shelves.append(DiscoverShelf(id: "collections", title: local(SMNaming.collections.title), caption: local(SMNaming.collections.subtitle), items: tiles.map(\.lead), collections: tiles))
                    continue
                }
                guard items.count >= min(4, SMCompose.minimum(id)) else { continue }
                items = FolderTileOrder.preferPosters(items)
                if SMShelf.isGenre(id) {
                    guard items.count >= SMGenres.minTitles, let def = SMGenres.byKey[String(id.dropFirst(SMGenres.shelfPrefix.count))] else { continue }
                    let mode = ctx?.mode(id) ?? .weekly
                    let caption = autoModes.contains(id) ? local(SMNaming.quietWeek) : Self.viewCaption(mode: mode, tmdb: tmdb)
                    shelves.append(DiscoverShelf(id: "genre-" + def.key, title: local(SMNaming.genreTitle(def.key)), caption: caption, items: items, ranked: false, smartID: id, mode: mode, genre: def.key))
                    continue
                }
                if let mood = SMShelf.isMood(id) ? SMMoods.byKey[String(id.dropFirst(SMShelf.moodPrefix.count))] : nil {
                    shelves.append(DiscoverShelf(id: id, title: local(mood.title), caption: local(mood.subtitle), items: items)); continue
                }
                let n: SMNaming.Row
                switch id {
                case SMShelf.topWeek: n = tmdb ? SMNaming.topWeek : SMNaming.topWeekLocal
                case SMShelf.trendingLibrary: n = SMNaming.trending
                case SMShelf.forYou: n = SMNaming.forYou
                case SMShelf.rediscover: n = SMNaming.rediscover
                case SMShelf.fresh: n = SMNaming.fresh
                case SMShelf.movieNight: n = SMNaming.movieNight
                case SMShelf.binge: n = SMNaming.binge
                case SMShelf.langPref: n = SMNaming.Row(title: local(SMNaming.languageRow, language ?? "Your Language"), subtitle: "In the language you prefer")
                default: continue
                }
                var title = n.title.isEmpty ? id : local(n.title), caption = local(n.subtitle)
                if id == SMShelf.langPref { title = n.title }
                if id == SMShelf.forYou, let b = Self.because(items: items, db: db, catalog: catalog, sourceID: sourceID) {
                    title = local(SMNaming.becauseYouWatched, b.title); caption = local("Titles like it in your library"); items = b.items
                }
                let isTrending = id == SMShelf.trendingLibrary
                let mode = isTrending ? (ctx?.mode(id) ?? .weekly) : nil
                if isTrending { caption = autoModes.contains(id) ? local(SMNaming.quietWeek) : Self.viewCaption(mode: mode ?? .weekly, tmdb: tmdb) }
                shelves.append(DiscoverShelf(id: isTrending ? "trending" : id, title: title, caption: caption, items: items, ranked: id == SMShelf.topWeek && tmdb,
                                             smartID: isTrending ? id : nil, mode: mode))
            }
            return SmartMixHomeResult(genreIndex: genreIndex, shelves: shelves, heroOrder: hero, diagnostics: diags, folderItems: folder)
        }.value
    }

    /// "Because You Watched X": the recent title (one of the last 3 movies and 2 series watched) whose real similar titles (franchise, director, genre, cast, story: `SimilarService`) cover at
    /// least 3 of the row's titles. Those titles lead the row. nil = no seed explains the row, so it keeps the plain name "Picked for You".
    static func because(items: [LibraryItem], db: DatabaseManager, catalog: SQLiteCatalogRepository, sourceID: UUID?) -> (title: String, items: [LibraryItem])? {
        let ids: [String] = (try? db.read { c in
            try c.query("SELECT item_id FROM recently_watched WHERE kind='movie' ORDER BY last_played DESC LIMIT 3", [], { $0.string(0) })
                + c.query("SELECT DISTINCT e.series_id FROM (SELECT item_id FROM recently_watched WHERE kind='episode' ORDER BY last_played DESC LIMIT 12) r JOIN episodes e ON e.id = r.item_id LIMIT 2", [], { $0.string(0) })
        }) ?? []
        let service = SimilarService(catalog: catalog)
        let rowIDs = Set(items.map(\.id))
        var best: (seed: LibraryItem, hit: Set<String>)? = nil
        for id in ids {
            guard let seed = ((try? catalog.movie(id: id)).flatMap { $0 }.map { LibraryItem.movie($0) }) ?? ((try? catalog.seriesItem(id: id)).flatMap { $0 }.map { LibraryItem.series($0) }),
                  sourceID == nil || seed.sourceID == sourceID, !rowIDs.contains(seed.id) else { continue }
            let hit = Set(service.suggestions(for: seed, extras: nil).filter { $0.reason != "Same language" }.map(\.item.id)).intersection(rowIDs)
            if hit.count >= 3, hit.count > (best?.hit.count ?? 0) { best = (seed, hit) }
        }
        guard let best else { return nil }
        let title = DisplayTitle.labels([(best.seed.id, best.seed.title)])[best.seed.id] ?? best.seed.title
        return (title, items.filter { best.hit.contains($0.id) } + items.filter { !best.hit.contains($0.id) })
    }

    /// Top languages, folders and decades of the 150 titles watched most recently: counts only, no titles.
    static func affinity(_ c: Connection, profile: String) throws -> SMAffinity {
        let ids = try c.query("""
            SELECT item_id FROM recently_watched WHERE kind='movie' ORDER BY last_played DESC LIMIT 100
            """, [], { $0.string(0) }) + (try c.query("""
            SELECT e.series_id FROM (SELECT item_id FROM recently_watched WHERE kind='episode' ORDER BY last_played DESC LIMIT 100) r JOIN episodes e ON e.id = r.item_id
            """, [], { $0.string(0) }))
        guard !ids.isEmpty else { return SMAffinity() }
        var genreCounts: [String: Int] = [:]
        var langs: [String: Int] = [:], folders: [String: Int] = [:], decades: [Int: Int] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 300).map({ Array(ids[$0..<min($0 + 300, ids.count)]) }) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            for r in try c.query("SELECT lang, folder_key, year FROM content_identity WHERE item_id IN (\(marks))", chunk.map { $0 as (any SQLConvertible)? }, { ($0.optString(0), $0.optString(1), $0.optInt(2)) }) {
                if let l = r.0 { langs[l, default: 0] += 1 }
                if let f = r.1 { folders[f, default: 0] += 1 }
                if let y = r.2 { decades[y / 10 * 10, default: 0] += 1 }
            }
        }
        for chunk in stride(from: 0, to: ids.count, by: 300).map({ Array(ids[$0..<min($0 + 300, ids.count)]) }) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let args = chunk.map { $0 as (any SQLConvertible)? }
            for (table, kind) in [("movies", SMKind.movie), ("series", SMKind.series)] {
                for g in try c.query("SELECT genre FROM \(table) WHERE id IN (\(marks)) AND genre IS NOT NULL", args, { $0.string(0) }) {
                    for k in SMGenres.keys(genres: SMGenres.tokens(g), kind: kind) { genreCounts[k, default: 0] += 1 }
                }
            }
        }
        func top<K: Hashable & Comparable>(_ d: [K: Int], _ n: Int) -> [K] { d.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(n).map(\.key) }
        return SMAffinity(topLangs: top(langs, 2), topFolders: top(folders, 3), topGenres: [], topDecades: top(decades, 2), genreKeys: top(genreCounts, 3))
    }
}
