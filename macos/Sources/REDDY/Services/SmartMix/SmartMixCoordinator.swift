import Foundation

struct SmartMixKeyProvider: SMTMDBKeyProvider {
    let credentials: CredentialStore
    var apiKey: String? { ((try? credentials.load(ref: MetadataMatchService.keyRef)) ?? nil)?.password }
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

struct SmartMixHomeResult: Sendable {
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
    private let db: DatabaseManager
    private let catalog: SQLiteCatalogRepository
    private let memory: RecommendationMemory
    private let keys: SMTMDBKeyProvider
    private let defaults: UserDefaults

    init(db: DatabaseManager, catalog: SQLiteCatalogRepository, memory: RecommendationMemory, credentials: CredentialStore, defaults: UserDefaults, session: URLSession = .shared) {
        self.db = db; self.catalog = catalog; self.memory = memory; self.defaults = defaults
        keys = SmartMixKeyProvider(credentials: credentials)
        source = SQLiteSmartMixCandidateSource(db: db)
        state = SQLiteSmartMixStateStore(db: db)
        trending = SMTrendingService(fetcher: SMTMDBTrendingClient(keys: keys, session: session), cache: DefaultsTrendingCache(defaults), policy: SMTrendingPolicy())
        self.session = SmartMixSession(source: source, state: state, trending: trending)
        Task { await self.trending.setPolicy(self.policy()) }
    }

    // MARK: TMDB switch

    var trendingEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.enabledKey); applyPolicy(); invalidate(.prefsChange) }
    }
    var hasOwnKey: Bool { !(keys.apiKey ?? "").isEmpty }
    /// ON by default, active only with the person's own key.
    func policy() -> SMTrendingPolicy { var p = SMTrendingPolicy(); p.enabled = trendingEnabled; p.hasOwnKey = hasOwnKey; return p }
    func applyPolicy() { let p = policy(); Task { await trending.setPolicy(p) } }
    /// Fetches the public weekly list when due (a request carries no information about the person). Fire and forget.
    func refreshTrendingIfNeeded() { Task.detached(priority: .utility) { [trending] in _ = await trending.refreshIfNeeded(now: Date()) } }

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
    func home(profile: String, sourceID: UUID?, preferredLanguage: String, now: Date = Date()) async -> SmartMixHomeResult? {
        guard source.coverageOK() else { return nil }
        let lang = OtherLanguages.preferredName(preferredLanguage)
        source.configure(sourceID: sourceID, preferredLanguage: lang)
        let cur = await trending.current(now: now)
        var tk = Set<String>()
        for e in cur.entries ?? [] { tk.insert(IdentityKey.make(e.title)); if let o = e.original, !o.isEmpty { tk.insert(IdentityKey.make(o)) } }
        source.setTrendingKeys(tk)
        let affinity = (try? db.read { try Self.affinity($0, profile: profile) }) ?? SMAffinity()
        var ctx = SMContext(profile: profile, dayKey: FeaturedPolicy.dayKey(now), refreshCounter: state.refreshCounter(profile: profile, shelf: Self.homeShelf), preferredLang: lang, affinity: affinity)
        ctx.poolCap = nil
        var results: [SMShelfResult] = []
        for attempt in 0..<2 {
            do { results = try await session.shelves(SMShelf.all, ctx: ctx, now: now, commit: true); break }
            catch SmartMixSession.SessionError.stale { if attempt == 1 { return nil } }
            catch { return nil }
        }
        return await materialize(results, language: lang)
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

    private func materialize(_ results: [SMShelfResult], language: String?) async -> SmartMixHomeResult {
        let catalog = self.catalog
        return await Task.detached { () -> SmartMixHomeResult in
            // One batched check that every title may be shown (not locked, not hidden, no copy in such a folder), then plain reads: asking the restricted view title by title costs seconds when many folders are locked.
            let ok = (try? catalog.recommendableIDs(results.flatMap { $0.picks.map(\.id) })) ?? []
            func item(_ p: SMPick) -> LibraryItem? {
                guard ok.contains(p.id) else { return nil }
                if p.kind == .series { return (try? catalog.seriesItem(id: p.id)).flatMap { $0 }.map { .series($0) } }
                return (try? catalog.movie(id: p.id)).flatMap { $0 }.map { .movie($0) }
            }
            var shelves: [DiscoverShelf] = [], hero: [LibraryItem] = [], folder: [LibraryItem] = [], diags: [String: SMDiagnostics] = [:]
            for r in results {
                diags[r.shelfId] = r.diag
                guard !r.isHidden else { continue }
                let items = r.picks.compactMap(item)
                if r.shelfId == SMShelf.hero { hero = items; continue }
                if SMShelf.isFolder(r.shelfId) { folder = items; continue }
                guard !items.isEmpty else { continue }
                let (id, title, caption): (String, String, String)
                switch r.shelfId {
                case SMShelf.topWeek:
                    (id, title) = ("top-week", "Top This Week")
                    caption = r.diag.caption == .trendingTMDB ? "This week's trending titles that are in your library" : "Popular and well rated in your library"
                case SMShelf.trendingLibrary:
                    (id, title) = ("trending", "Trending in Your Library")
                    caption = r.diag.caption == .trendingTMDB ? "Trending this week, found in your playlists" : "What is being watched and added most here"
                case SMShelf.forYou: (id, title, caption) = ("for-you", "Because You Watched", "Picked from what you watched lately")
                case SMShelf.rediscover: (id, title, caption) = ("rediscover", "Rediscover", "Good titles in your library you have not seen")
                case SMShelf.langPref: (id, title, caption) = ("lang-pref", "In \(language ?? "Your Language")", "In the language you prefer")
                default: continue
                }
                shelves.append(DiscoverShelf(id: id, title: title, caption: caption, items: (id == "rediscover" || id == "lang-pref") ? FolderTileOrder.preferPosters(items) : items, ranked: r.shelfId == SMShelf.topWeek && r.diag.caption == .trendingTMDB))
            }
            return SmartMixHomeResult(shelves: shelves, heroOrder: hero, diagnostics: diags, folderItems: folder)
        }.value
    }

    /// Top languages, folders and decades of the 150 titles watched most recently: counts only, no titles.
    static func affinity(_ c: Connection, profile: String) throws -> SMAffinity {
        let ids = try c.query("""
            SELECT item_id FROM recently_watched WHERE kind='movie' ORDER BY last_played DESC LIMIT 100
            """, [], { $0.string(0) }) + (try c.query("""
            SELECT e.series_id FROM (SELECT item_id FROM recently_watched WHERE kind='episode' ORDER BY last_played DESC LIMIT 100) r JOIN episodes e ON e.id = r.item_id
            """, [], { $0.string(0) }))
        guard !ids.isEmpty else { return SMAffinity() }
        var langs: [String: Int] = [:], folders: [String: Int] = [:], decades: [Int: Int] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 300).map({ Array(ids[$0..<min($0 + 300, ids.count)]) }) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            for r in try c.query("SELECT lang, folder_key, year FROM content_identity WHERE item_id IN (\(marks))", chunk.map { $0 as (any SQLConvertible)? }, { ($0.optString(0), $0.optString(1), $0.optInt(2)) }) {
                if let l = r.0 { langs[l, default: 0] += 1 }
                if let f = r.1 { folders[f, default: 0] += 1 }
                if let y = r.2 { decades[y / 10 * 10, default: 0] += 1 }
            }
        }
        func top<K: Hashable & Comparable>(_ d: [K: Int], _ n: Int) -> [K] { d.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(n).map(\.key) }
        return SMAffinity(topLangs: top(langs, 2), topFolders: top(folders, 3), topGenres: [], topDecades: top(decades, 2))
    }
}
