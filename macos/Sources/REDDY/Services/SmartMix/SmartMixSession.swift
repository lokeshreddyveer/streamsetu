import Foundation

// Orchestration around the pure engine: candidate source (identity layer adapter), per-profile state, trending, caches, invalidation.
// Runs off the main thread (actor). The main thread only receives finished SMShelfResult values.

enum SMScope: Sendable, Equatable {
    case home                       // pool for hero / for-you / rediscover / lang-pref / top-week / trending-library
    case folder(String)             // pool for one folder row
}

/// Revision vector (03 cache invalidation). Any change makes cached results unusable.
struct SMRevision: Hashable, Sendable {
    var catalog = 0, restrict = 0, hidden = 0, profileEpoch = 0, prefs = 0, dismiss = 0, identVer = 0
    init() {}
}

/// What the canonical identity layer (SchemaV19 `content_identity`, `rec_dismissed`, restricted marks) must provide.
/// Candidates arrive with `restricted` / `dismissed` flags set at identity level (any twin copy restricted => all copies restricted).
/// The real adapter is not part of this change: code against this protocol; `InMemoryCandidateSource` is the test fake.
protocol SmartMixCandidateSource: Sendable {
    func candidates(profile: String, scope: SMScope, poolLimit: Int) async throws -> [SMCandidate]
    func revision(profile: String) async -> SMRevision
}

final class InMemoryCandidateSource: SmartMixCandidateSource, @unchecked Sendable {
    private let lock = NSLock()
    private var library: [SMCandidate] = []
    private var byKey: [String: [Int]] = [:]
    private var folderKeys: [String: Set<String>] = [:]
    private var rev = SMRevision()
    private(set) var requests = 0
    init(_ library: [SMCandidate]) { index(library) }

    private func index(_ lib: [SMCandidate]) {
        library = lib; byKey = [:]; folderKeys = [:]
        for (i, c) in lib.enumerated() {
            let k = c.kind.rawValue + "\u{1}" + c.key
            byKey[k, default: []].append(i)
            if let f = c.folder { folderKeys[f, default: []].insert(k) }
        }
    }

    func set(_ library: [SMCandidate], bump: WritableKeyPath<SMRevision, Int> = \.catalog) {
        lock.withLock { index(library); rev[keyPath: bump] += 1 }
    }

    /// Folder scope returns every copy of every title that has a copy in the folder (twins in other folders included),
    /// so restricted twins elsewhere still make the title restricted (the real adapter must do the same).
    func candidates(profile: String, scope: SMScope, poolLimit: Int) async throws -> [SMCandidate] {
        lock.withLock {
            requests += 1
            guard case .folder(let f) = scope else { return library }
            var out: [SMCandidate] = []
            for k in folderKeys[f] ?? [] { for i in byKey[k] ?? [] { out.append(library[i]) } }
            return out
        }
    }
    func revision(profile: String) async -> SMRevision { lock.withLock { rev } }
}

enum SMInvalidation: Sendable {
    case lockOrRestrictionChange          // lock / unlock / relock / Kids / hide-adult
    case hideChange
    case profileSwitch
    case syncChanged
    case dismissChange
    case prefsChange
    case memoryWarning
}

actor SmartMixSession {
    enum SessionError: Error { case stale }

    private let source: SmartMixCandidateSource
    private let state: SmartMixStateStore
    private let trending: SMTrendingService?
    private let lists: SMListsService?
    private var generation = 0
    private var cache: [String: SMShelfResult] = [:]     // L2, in memory only; never holds titles or URLs, never anything restricted
    private(set) var buildCount = 0

    init(source: SmartMixCandidateSource, state: SmartMixStateStore, trending: SMTrendingService? = nil, lists: SMListsService? = nil) {
        self.source = source; self.state = state; self.trending = trending; self.lists = lists
    }

    /// Cache and generation reset. Builds already running are discarded when they finish (`SessionError.stale`).
    func invalidate(_ event: SMInvalidation) {
        switch event {
        case .memoryWarning: cache.removeAll()     // L2 stays on disk in the real store; here everything is memory
        default: generation += 1; cache.removeAll()
        }
    }

    /// Builds the requested shelves for the context. `commit` records the shown rows (first successful render of a new load key).
    /// Throws `.stale` when a restriction / profile / sync event happened while building: nothing is published or cached from such a build.
    func shelves(_ ids: [String], ctx: SMContext, now: Date, commit: Bool = false) async throws -> [SMShelfResult] {
        let gen = generation
        buildCount += 1
        let rev = await source.revision(profile: ctx.profile)
        var entries: [SMTrendingEntry]? = nil
        var status = SMTrendingStatus.off
        if let trending {
            let cur = await trending.current(now: now)
            entries = cur.entries; status = cur.status
        }
        let listEntries = await lists?.current(now: now) ?? [:]
        let listsStamp = listEntries.keys.sorted().map { $0 + String(listEntries[$0]?.count ?? 0) }.joined(separator: ",")
        var out: [SMShelfResult] = []
        var home: SmartMixEngine.Prepared? = nil
        var fresh: [String: SMShelfResult] = [:]
        /// TMDB ranks for a shelf in its mode: the shelf's own list, else the whole-library list of that mode; nil when neither is cached (local ranking).
        let weekEntries = entries
        func ranks(_ shelf: String, _ prepared: SmartMixEngine.Prepared) -> [String: Int]? {
            let k = SMListKey.forShelf(shelf, mode: ctx.mode(shelf))
            for name in [k.own, k.general].compactMap({ $0 }) {
                let list = name == "week" ? weekEntries : listEntries[name]
                if let list, !list.isEmpty { return SMTrendingMatcher.match(entries: list, candidates: prepared.groups, normalize: IdentityKey.make) }
            }
            return nil
        }
        for shelf in ids {
            let key = cacheKey(rev, ctx, shelf, status, listsStamp)
            if let hit = cache[key] {
                if shelf == SMShelf.genresAuto, !hit.genreSelected.allSatisfy({ cache[cacheKey(rev, ctx, SMGenres.shelfId($0), status, listsStamp)] != nil }) { cache[key] = nil }
                else {
                    if shelf == SMShelf.genresAuto { for g in hit.genreSelected { if let r = cache[cacheKey(rev, ctx, SMGenres.shelfId(g), status, listsStamp)] { out.append(r) } } }
                    out.append(hit); continue
                }
            }
            if shelf == SMShelf.genresAuto {
                let prepared: SmartMixEngine.Prepared
                if let h = home { prepared = h } else { prepared = try await loadHome(ctx, entries); home = prepared }
                let counts = SmartMixEngine.genreCounts(prepared)
                let selected = SMGenres.select(counts: counts, ctx: ctx)
                var index = SMShelfResult(shelfId: SMShelf.genresIndex, picks: [], diag: SMDiagnostics())
                index.diag.hidden = true; index.genreCounts = counts; index.genreSelected = selected
                for g in selected {
                    let id = SMGenres.shelfId(g)
                    let loads = state.loadsAgo(profile: ctx.profile, shelf: id, loadKey: ctx.loadKey)
                    let r = SmartMixEngine.build(shelfId: id, prepared: prepared, ctx: ctx, loadsAgo: loads, ranks: ranks(id, prepared))
                    out.append(r); fresh[cacheKey(rev, ctx, id, status, listsStamp)] = r
                }
                out.append(index); fresh[key] = index
                continue
            }
            let prepared: SmartMixEngine.Prepared
            if SMShelf.isFolder(shelf) {
                var cs = try await source.candidates(profile: ctx.profile, scope: .folder(String(shelf.dropFirst(7))), poolLimit: 200)
                if let entries { Self.applyTrend(entries, &cs) }
                prepared = SmartMixEngine.prepare(cs, preferredLang: ctx.preferredLang)
            } else {
                if let h = home { prepared = h } else { prepared = try await loadHome(ctx, entries); home = prepared }
            }
            var mode = SmartMixEngine.TrendingMode(ordered: false, status: status.rawValue)
            if entries != nil && shelf == SMShelf.topWeek {
                mode.ordered = prepared.groups.reduce(0) { $0 + (!$1.restricted && $1.trend != nil ? 1 : 0) } >= SMTrendingPolicy.minMatchesForTopWeek
            }
            let loads = state.loadsAgo(profile: ctx.profile, shelf: shelf, loadKey: ctx.loadKey)
            let r = SmartMixEngine.build(shelfId: shelf, prepared: prepared, ctx: ctx, loadsAgo: loads, trending: mode, ranks: ranks(shelf, prepared))
            out.append(r)
            fresh[key] = r
        }
        guard gen == generation else { throw SessionError.stale }
        for (k, v) in fresh { cache[k] = v }
        if commit {
            for r in out where !r.diag.hidden && r.shelfId != SMShelf.genresAuto {
                state.recordShown(profile: ctx.profile, shelf: r.shelfId, loadKey: ctx.loadKey,
                                  rows: r.picks.prefix(SMCompose.size(r.shelfId) + (r.shelfId == SMShelf.hero ? -2 : 0)).map { SMShownRow(key: $0.key, year: $0.year, itemId: $0.id, seq: 0) })
            }
        }
        return out
    }

    private func loadHome(_ ctx: SMContext, _ entries: [SMTrendingEntry]?) async throws -> SmartMixEngine.Prepared {
        var cs = try await source.candidates(profile: ctx.profile, scope: .home, poolLimit: 2000)
        if let entries { Self.applyTrend(entries, &cs) }
        return SmartMixEngine.prepare(cs, preferredLang: ctx.preferredLang)
    }

    private static func applyTrend(_ entries: [SMTrendingEntry], _ cs: inout [SMCandidate]) {
        let m = SMTrendingMatcher.match(entries: entries, candidates: cs, normalize: IdentityKey.make)
        for i in cs.indices { cs[i].trend = m[cs[i].id] }
    }

    private func cacheKey(_ rev: SMRevision, _ ctx: SMContext, _ shelf: String, _ status: SMTrendingStatus, _ listsStamp: String = "") -> String {
        "\(ctx.profile)|\(shelf)|\(ctx.mode(shelf).rawValue)|\(ctx.kids)|\(ctx.affinity.genreKeys)|\(listsStamp)|\(ctx.loadKey)|\(ctx.preferredLang ?? "")|\(ctx.affinity.topLangs)\(ctx.affinity.topFolders)\(ctx.affinity.topGenres)\(ctx.affinity.topDecades)|\(status.rawValue)|\(rev.catalog).\(rev.restrict).\(rev.hidden).\(rev.profileEpoch).\(rev.prefs).\(rev.dismiss).\(rev.identVer)"
    }
}

// MARK: mapping from the identity layer (SchemaV19 `content_identity`)

/// One `content_identity` row joined with what the adapter reads from the item tables and the person's own marks.
/// The SQL adapter (candidate pool per shelf, `restricted` from the restriction gate for the active profile, `dismissed` from `rec_dismissed`,
/// watched/plays from history) belongs with the privacy layer and is not part of this change; this is the column mapping it must use.
struct SMIdentityRow: Sendable {
    var itemId: String
    var kind: String            // 'movie' | 'series'
    var identityKey: String
    var year: Int?
    var lang: String?
    var qualityRank: Int
    var isCam: Bool
    var folderKey: String?

    func candidate(sourceRank: Int, addedDays: Int?, hasPoster: Bool, hasBackdrop: Bool, ratingText: String?,
                   restricted: Bool, dismissed: Bool) -> SMCandidate {
        var c = SMCandidate(id: itemId)
        c.kind = SMKind(rawValue: kind) ?? .movie
        c.key = identityKey; c.year = year; c.lang = lang; c.q = min(5, max(0, qualityRank)); c.cam = isCam; c.folder = folderKey
        c.src = sourceRank; c.added = addedDays; c.poster = hasPoster; c.backdrop = hasBackdrop; c.rating = ratingText
        c.restricted = restricted; c.dismissed = dismissed
        return c
    }
}
