import Foundation

/// The one thing services call for artwork, episodes and extra ids. Providers are never referenced from views. Offline-capable: reads come from the cache table.
/// fanart.tv rules (its terms): express lane only, one request per title until expiry (plus negative caching), a low global rate and a daily cap, no crawling.
actor MetadataHub {
    struct Settings: Sendable {
        var ctx = ArtContext()
        /// Wait this long after a title appears before asking (a quick scroll past asks nothing).
        var visibilityDebounce: TimeInterval = 0.5
    }

    private let store: HubStore
    private var artProviders: [HubSource: any ArtworkProvider]
    private var episodeProviders: [HubSource: any EpisodeProvider]
    private let access: [HubSource: HubAccess]
    private let isSendable: @Sendable (String) -> Bool
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void
    var settings: Settings

    private var buckets: [HubSource: TokenBucket] = [:]
    private var breakers: [HubSource: CircuitBreaker] = [:]
    private var queues: [HubSource: HubQueue] = [:]
    private var pendingExpress: [String: Task<Void, Never>] = [:]

    init(store: HubStore, artwork: [any ArtworkProvider], episodes: [any EpisodeProvider], access: [HubSource: HubAccess],
         settings: Settings = Settings(), isSendable: @escaping @Sendable (String) -> Bool = { _ in true },
         now: @escaping @Sendable () -> Date = { Date() }, sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }) {
        self.store = store; self.access = access; self.settings = settings; self.isSendable = isSendable; self.now = now; self.sleep = sleep
        artProviders = Dictionary(uniqueKeysWithValues: artwork.map { ($0.source, $0) })
        episodeProviders = Dictionary(uniqueKeysWithValues: episodes.map { ($0.source, $0) })
    }

    // MARK: reads (cache only, never the network)
    func image(_ item: String, _ kind: ArtKind, season: Int? = nil) -> String? {
        store.fact(item, Self.field(kind, season))?.fact.value.nilIfEmpty
    }
    func text(_ item: String, _ field: String) -> String? { store.fact(item, field)?.fact.value.nilIfEmpty }
    /// The sources behind what is stored for a title: lets a screen decide whether a TheTVDB footer is required.
    func provenance(_ item: String) -> Set<HubSource> { store.provenance(item) }
    func attributionFooter(_ item: String) -> String? { HubAttribution.footer(provenance: store.provenance(item)) }
    static func field(_ k: ArtKind, _ season: Int? = nil) -> String { k == .seasonPoster ? "seasonposter:\(season ?? 0)" : k.rawValue }

    // MARK: express lane
    /// A title appeared on screen or was opened. After the debounce, asks the services that can improve what is missing. Cancelled when the title leaves.
    func titleAppeared(_ item: String, identity: HubIdentity, kind: HubTitleKind) {
        pendingExpress[item]?.cancel()
        let delay = settings.visibilityDebounce
        pendingExpress[item] = Task { [weak self] in
            await self?.sleep(delay)
            if Task.isCancelled { return }
            await self?.refresh(item, identity: identity, kind: kind)
            await self?.finishedExpress(item)
        }
    }
    func titleGone(_ item: String) { pendingExpress[item]?.cancel(); pendingExpress[item] = nil }
    private func finishedExpress(_ item: String) { pendingExpress[item] = nil }

    /// What was done, for tests and diagnostics.
    struct Result: Sendable, Equatable { var asked: [HubSource] = []; var stored: [String] = []; var skipped: [HubSource: String] = [:] }

    @discardableResult func refresh(_ item: String, identity: HubIdentity, kind: HubTitleKind) async -> Result {
        var res = Result()
        guard isSendable(item) else { return res }                                    // locked folders and copies there are never requested
        let t = now()
        if let m = store.identity(item)?.missUntil, m > t { res.skipped[.tvmaze] = "remembered"; return res }          // the services did not know this title's ids: not asked again until new ids arrive
        let ctx = settings.ctx
        let wanted: [ArtKind] = [.logo, .backdrop, .poster]
        let missing = wanted.filter { !Arbiter.atTarget($0, stored: store.fact(item, Self.field($0))?.fact, ctx, now: t) }
        if !missing.isEmpty {
            for source in [HubSource.fanart, .tvdb] {
                guard let p = artProviders[source] else { continue }
                if let why = gate(source, item: item, field: "art:\(source.rawValue)", identity: identity, kind: kind) { res.skipped[source] = why; continue }
                res.asked.append(source)
                do {
                    let cands = try await p.artwork(for: identity, kind: kind)
                    breakers[source, default: CircuitBreaker()].success()
                    var any = false
                    for k in missing {
                        if let pick = Arbiter.pick(k, cands, ctx) {
                            if store.put(item, Self.field(k), value: pick.candidate.url, source: source, quality: pick.score, now: t, keep: HubPolicy.policy(for: source).keep) { res.stored.append(Self.field(k)); any = true }
                        }
                    }
                    let keep = HubPolicy.policy(for: source).keep
                    // one request per title until expiry, found or not
                    store.putMiss(item, "art:\(source.rawValue)", source: source, until: any || !cands.isEmpty ? t.addingTimeInterval(keep) : t.addingTimeInterval(NegativeCache.notFound), now: t)
                } catch { handle(error, source: source, item: item, field: "art:\(source.rawValue)", t: t) }
            }
        }
        if kind == .series, let p = episodeProviders[.tvmaze], gate(.tvmaze, item: item, field: "episodes", identity: identity, kind: kind) == nil {
            res.asked.append(.tvmaze)
            do {
                if let e = try await p.episodes(for: identity) {
                    breakers[.tvmaze, default: CircuitBreaker()].success()
                    store.saveIdentity(item, e.ids, from: .tvmaze, now: t)
                    if let n = e.next, let stamp = n.airstamp { store.put(item, "nextepisode", value: stamp, source: .tvmaze, quality: 100, now: t, keep: HubPolicy.tvmaze.keep); res.stored.append("nextepisode") }
                    store.putMiss(item, "episodes", source: .tvmaze, until: t.addingTimeInterval(Retention.episodesMiss), now: t)
                } else { store.putMiss(item, "episodes", source: .tvmaze, until: t.addingTimeInterval(NegativeCache.notFound), now: t) }
            } catch { handle(error, source: .tvmaze, item: item, field: "episodes", t: t) }
        }
        if !res.stored.isEmpty { TitleMetadataEvent.post([item]) }
        return res
    }

    /// Why a source must not be asked now, or nil. Checks, in order: toggle and key, ids, negative cache, breaker, daily cap, rate.
    private func gate(_ source: HubSource, item: String, field: String, identity: HubIdentity, kind: HubTitleKind) -> String? {
        let t = now()
        guard let a = access[source], a.origin != .none else { return "off" }
        if source == .fanart && FanartKeys.resolve(a) == nil { return "no key" }
        guard identity.queryID(for: source, kind: kind) != nil else { return "no id" }
        if let m = store.fact(item, field)?.missUntil, m > t { return "remembered" }
        if !breakers[source, default: CircuitBreaker()].allow(now: t) { return "breaker open" }
        var q = queues[source] ?? HubQueue(policy: .policy(for: source), now: t)
        q.enqueue(item + "#" + field, lane: .express)
        guard let n = q.next(now: t) else { queues[source] = q; return "daily cap" }
        q.finish(n.key); queues[source] = q
        var b = buckets[source] ?? TokenBucket(.policy(for: source), now: t)
        let wait = b.take(now: t); buckets[source] = b
        if wait > 0 { return "rate" }
        return nil
    }

    private func handle(_ error: Error, source: HubSource, item: String, field: String, t: Date) {
        if error is CancellationError { return }
        var outcome = NegativeCache.Outcome.offline
        if let n = error as? NetworkError, case .http(let s, let after) = n {
            outcome = NegativeCache.outcome(forStatus: s, retryAfter: after)
            if BuiltInKeyPause.isRefusal(s), let a = access[source] { a.markBuiltInRejected() }
        }
        if case .offline = outcome { return }                                         // offline just waits
        breakers[source, default: CircuitBreaker()].failure(now: t)
        if let until = NegativeCache.missUntil(outcome, now: t) { store.putMiss(item, field, source: source, until: until, now: t) }
        store.noteFailure(item, field)
        if case .notFound = outcome, source == .tvdb || source == .tvmaze, let until = NegativeCache.missUntil(outcome, now: t) { store.setIdentityMiss(item, until: until) }          // an id lookup that finds nothing: the id is not known there
    }
}

