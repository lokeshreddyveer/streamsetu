import SwiftUI
import Observation

/// Who is composing Listen Now: one at a time, so two tasks of the page do not compose twice (Refresh may overtake). A wipe or a reset forgets the
/// holder, so a compose still running from before it never blocks the next one.
struct HomeComposeGate: Sendable {
    private var serial = 0
    private(set) var holder: Int?
    mutating func begin(refresh: Bool) -> Int? {
        if holder != nil, !refresh { return nil }
        serial += 1; holder = serial
        return serial
    }
    mutating func end(_ ticket: Int) { if holder == ticket { holder = nil } }
    mutating func reset() { holder = nil }
}

/// Keeps Listen Now's feed: the last one is read from disk at launch (so the page paints at once), a new one is composed in the background by
/// `HomeEngine` from a snapshot of the library and what the sources answer, and it replaces the old one in place. Opening Home again within 90 seconds,
/// or coming back to it with Back, keeps the same feed, so nothing moves under the cursor; Refresh (the glass button or Cmd-R) draws a new seed and recomposes.
/// The page reads `feed`; nothing is composed while a view body is evaluated.
@MainActor @Observable
final class MusicHomeFeedModel {
    static let shared = MusicHomeFeedModel()


    private(set) var feed: HomeFeed?
    /// True while a new feed is being composed (the page dims its shelves a little and keeps its place).
    private(set) var composing = false
    /// True while a feed asked for with Refresh is being composed (a quiet recompose behind a cached page does not count).
    private(set) var refreshing = false
    /// The songs for Continue Listening, kept up to date as plays arrive (the rest of the feed does not move).
    private(set) var continueItems: [HomeItem] = []
    /// The graph block's shelves (films with soundtracks and the people behind the songs), built with the feed and refreshed when its pictures arrive.
    private(set) var graph: [MusicFillShelf] = []
    private(set) var graphPhase: MusicSectionPhase = .idle

    @ObservationIgnored private var previous: HomeSeedPolicy.Previous?
    @ObservationIgnored private var cacheRead = false
    @ObservationIgnored private var opening = HomeComposeGate()
    /// Bumped by every compose; a compose that finds a newer one has started drops its result instead of overwriting the newer feed.
    @ObservationIgnored private var generation = 0
    /// Counts wipes, so a cache read that started before one is dropped.
    @ObservationIgnored private var wipes = 0
    /// The last toolbar refresh this model acted on (see `MusicHub.userRefreshToken`).
    @ObservationIgnored var handledRefreshToken = 0

    /// The refresh token after Cmd-R. Only a refresh made on Listen Now counts as one for it; on another screen the token is left alone, so Listen Now
    /// does not reshuffle the next time the person visits.
    static func tokenAfterRefresh(_ token: Int, onHome: Bool) -> Int { onHome ? token + 1 : token }
    /// Listen Now itself is what is shown: the section, with no page opened on top of it.
    nonisolated static func isShowing(_ nav: MusicNav) -> Bool { nav.section == .home && nav.top == nil }
    /// The graph build the shown shelves came from; set only when a build finished, so one that was cancelled is asked for again.
    @ObservationIgnored private var graphKey = ""
    /// The seed the shown graph shelves were drawn with. A new seed replaces the shelves; the same seed (pictures arriving) only refreshes them in place.
    @ObservationIgnored private var graphSeed: UInt64?
    /// The songs "Because you played" passes over for one seed: read once when that seed is first drawn, so a rebuild of the same page picks the same song.
    @ObservationIgnored private var graphAvoid: (seed: UInt64, songs: Set<MusicEntityID>)?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    // MARK: cache

    /// At launch, before Home is opened: the saved feed is read so the first frame already has its shelves.
    func preload() async {
        guard !cacheRead else { return }
        cacheRead = true
        let epoch = wipes
        let saved = await Task.detached(priority: .userInitiated) { HomeFeedCache.load() }.value
        // A wipe while the file was being read: what was read is the wiped feed, it must not come back.
        guard epoch == wipes, let saved, feed == nil else { MusicDebugLog.log("home", "feed cache miss"); return }
        feed = saved; continueItems = saved.continueItems
        previous = HomeSeedPolicy.Previous(seed: saved.seed, at: saved.composedAt)
        MusicDebugLog.log("home", "feed cache hit: seed \(saved.seed), \(saved.sections.count) sections, age \(Int(Date().timeIntervalSince(saved.composedAt))) s")
    }

    // MARK: open and refresh

    /// Called when Home appears. `refresh` is true for the Refresh button and Cmd-R.
    func open(hub: MusicHub, refresh: Bool) async {
        // Two tasks of the page can ask at once on the first appear; the second waits for the first's feed instead of composing a second one.
        guard let ticket = opening.begin(refresh: refresh) else { return }
        defer { opening.end(ticket) }
        await preload()
        let arrivedByBack = hub.nav.arrivedByReturn
        let draw = HomeSeedPolicy.seed(now: Date(), previous: previous, refresh: refresh, returning: arrivedByBack)
        if draw.reused, let kept = feed, !refresh, stillFits(kept, hub: hub) {
            MusicDebugLog.log("home", "feed kept (seed \(draw.seed), back \(arrivedByBack))")
            previous = HomeSeedPolicy.Previous(seed: draw.seed, at: Date())   // the visit goes on: what asks next keeps this page too
            refreshContinue(hub: hub)
            if graph.isEmpty, !hub.gated { await loadGraph(hub: hub, seed: draw.seed, force: false) }
            return
        }
        MusicDebugLog.log("home", refresh ? "refresh: new seed \(draw.seed)" : "new visit: seed \(draw.seed)")
        await composeUntilCurrent(hub: hub, seed: draw.seed, userAsked: refresh)
    }

    /// Something the shown feed was made from changed while it is on screen (the lock, the language, the sources, a first like or import): it is composed
    /// again under the same seed when it no longer fits, and left alone when it does.
    func reconcile(hub: MusicHub) async {
        guard let kept = feed, !stillFits(kept, hub: hub), let ticket = opening.begin(refresh: false) else { return }
        defer { opening.end(ticket) }
        await composeUntilCurrent(hub: hub, seed: kept.seed, userAsked: false)
    }

    /// A feed made while offline or gated is not kept once the state changed (reconnected, unlocked); full-feed variants (new user, light, full) count as the same state.
    nonisolated static func sameState(_ kept: HomeFeed.Mode, _ now: HomeFeed.Mode) -> Bool {
        func bucket(_ m: HomeFeed.Mode) -> Int { m == .gated ? 1 : (m == .offline ? 2 : 0) }
        return bucket(kept) == bucket(now)
    }

    /// True while `kept` may stay on screen: the same lock and network state, language and sources, and no welcome page for a person who now has music saved.
    nonisolated static func fits(_ kept: HomeFeed, mode: HomeFeed.Mode, language: String, sources: [String], hasSavedMusic: Bool) -> Bool {
        sameState(kept.mode, mode) && (kept.language ?? language) == language && (kept.sources ?? sources) == sources && !(kept.mode == .newUser && hasSavedMusic)
    }

    /// The same rule the engine uses for a new listener: no counted play, and nothing liked, followed or kept in a playlist.
    private static func hasStarted(hub: MusicHub) -> Bool {
        let lib = hub.library
        if !lib.playlists.isEmpty || lib.liked.contains(where: { !lib.isBlacklisted($0) }) { return true }
        if lib.followedArtists.contains(where: { !lib.isBlacklisted(artist: MusicArtistRef(id: $0.id, name: $0.name)) }) { return true }
        let now = Date()
        return MusicTasteReset.visible(lib.history).contains { HomeTaste.shapesTaste($0, now: now) && !lib.isBlacklisted($0.track) }
    }

    /// Which 8 artists are asked for new releases: the first 8 for a person with few, and for one who follows many a different 8 on each new visit (the draw follows the
    /// visit's seed), so the same first follows are not the only ones ever checked.
    nonisolated static func releaseSeeds(_ seeds: [MusicArtist], seed: UInt64, count: Int = 8) -> [MusicArtist] {
        guard seeds.count > count else { return seeds }
        let start = Int(seed % UInt64(seeds.count))
        return (0..<count).map { seeds[(start + $0) % seeds.count] }
    }

    private func stillFits(_ kept: HomeFeed, hub: MusicHub) -> Bool {
        let mode: HomeFeed.Mode = hub.gated ? .gated : (MusicNetwork.watch.isOnline ? .full : .offline)
        return Self.fits(kept, mode: mode, language: Localized.activeCode, sources: hub.registry.enabled.sorted(), hasSavedMusic: Self.hasStarted(hub: hub))
    }

    /// The songs of Continue listening as they are right now.
    private func liveContinue(hub: MusicHub) -> [HomeItem] {
        let history = MusicTasteReset.visible(hub.library.history).filter { !hub.library.isBlacklisted($0.track) }
        return HomeEngine.continueItems(history: history, current: hub.player.current)
    }

    func refreshContinue(hub: MusicHub) {
        let items = liveContinue(hub: hub)
        if items != continueItems { continueItems = items }
    }

    /// Puts a composed feed on screen. Continue listening is given separately, read now: the feed's own copy was taken before the sources were asked.
    func publish(_ composed: HomeFeed, continueNow: [HomeItem]) {
        feed = composed
        if continueItems != continueNow { continueItems = continueNow }
    }

    func clearAll() {
        wipes += 1
        generation += 1   // a compose still running must not write its result back after the wipe
        opening.reset()   // and must not stand in the way of the compose that replaces it
        composing = false; refreshing = false; graphSeed = nil; graphAvoid = nil
        feed = nil; continueItems = []; graph = []; graphPhase = .idle; previous = nil; cacheRead = true; graphKey = ""
        MusicHomeSignalLoader.forget()
        HomeFeedCache.noteWipe()
        Task.detached(priority: .utility) { HomeFeedCache.clear() }
    }

    // MARK: compose

    /// Composes, and composes again when what the feed was made from changed meanwhile (three tries; the next change asks again).
    private func composeUntilCurrent(hub: MusicHub, seed: UInt64, userAsked: Bool) async {
        for attempt in 1...3 {
            guard await compose(hub: hub, seed: seed, userAsked: userAsked, last: attempt == 3), !Task.isCancelled else { return }
        }
    }

    /// True when the result was dropped because the lock, language, sources or saved music changed while it was being made.
    private func compose(hub: MusicHub, seed: UInt64, userAsked: Bool, last: Bool) async -> Bool {
        generation += 1
        let mine = generation
        let started = Date()
        composing = true
        refreshing = userAsked
        defer { if mine == generation { composing = false; refreshing = false } }
        let gated = hub.gated
        let offline = !MusicNetwork.watch.isOnline
        let language = Localized.activeCode
        let sources = hub.registry.enabled.sorted()
        let wording = MusicFillWording.localized
        var signals = HomeSignals()
        signals.history = MusicTasteReset.visible(hub.library.history)
        signals.allHistory = hub.library.history
        signals.liked = hub.library.liked.filter { !hub.library.isBlacklisted($0) }
        signals.followed = hub.library.followedArtists.filter { !hub.library.isBlacklisted(artist: MusicArtistRef(id: $0.id, name: $0.name)) }
        signals.playlists = hub.library.playlists
        signals.current = hub.player.current
        signals.downloaded = Set(hub.downloads.items.filter { $0.state == .done }.map(\.id))
        signals.history.removeAll { hub.library.isBlacklisted($0.track) }
        let hidden = MusicHiddenRecommendations.shared.set

        if !gated, !offline {
            let taste = HomeTaste.build(history: signals.history, liked: signals.liked, followed: signals.followed, now: started)
            let seeds = MusicHomeSignalLoader.seedArtists(taste: taste, followed: signals.followed, limit: 16)
            async let releases = MusicHomeSignalLoader.releases(hub: hub, seeds: Self.releaseSeeds(seeds, seed: seed))
            async let adjacent = MusicHomeSignalLoader.adjacent(hub: hub, taste: taste, seeds: seeds, visit: seed)
            async let genrePicks = MusicHomeSignalLoader.genreShelves(hub: hub, taste: taste, wording: wording)
            async let playlists = MusicHomeSignalLoader.playlistsForYou(hub: hub, taste: taste)
            async let graphDone: Void = loadGraph(hub: hub, seed: seed, force: true)
            signals.releases = (await releases).filter { r in !r.artists.contains { hub.library.isBlacklisted(artist: $0) } }
            // A song marked Never Play after an answer was cached must not come back from the cache.
            let allowed: (HomeItem) -> Bool = { item in
                !item.isBlocked(track: { hub.library.isBlacklisted($0) }, artist: { hub.library.isBlacklisted(artist: $0) })
            }
            signals.adjacent = hidden.filter(await adjacent).filter(allowed)
            signals.genreShelves = await genrePicks.map { c in var c = c; c.items = hidden.filter(c.items).filter(allowed); return c }
            signals.playlistsForYou = hidden.filter(await playlists).filter(allowed)
            await graphDone
            signals.films = graph.first { $0.id == "fill.personal.films" }?.tiles.prefix(4).map {
                HomeFilmPick(entityRaw: $0.entity.rawValue, title: $0.title, subtitle: $0.subtitle, imageURL: $0.imageRef)
            } ?? []
        } else {
            if mine == generation { graph = []; graphPhase = .idle }
        }
        if !gated { signals.localTracks = await MusicHomeSignalLoader.localSample(hub: hub, seed: seed) }
        if Task.isCancelled || mine != generation { return false }

        var ctx = HomeContext()
        ctx.now = started; ctx.seed = seed; ctx.gated = gated; ctx.offline = offline
        // The history starts with the hero on screen; a compose of the same seed must keep it, so that one is not counted as already shown.
        ctx.heroHistory = feed?.seed == seed ? Array((feed?.heroHistory ?? []).dropFirst()) : (feed?.heroHistory ?? [])
        ctx.wording = wording
        let input = signals
        let ctxCopy = ctx
        var composed = hidden.filter(await Task.detached(priority: .userInitiated) { HomeEngine.compose(input, ctx: ctxCopy) }.value)
        if Task.isCancelled || mine != generation { return false }
        composed.language = language
        composed.sources = sources
        // Locked or unlocked, a language or source switched, or a first like while the sources were being asked: this answer belongs to the old state.
        if !last, !stillFits(composed, hub: hub) { return true }

        withAnimation(.easeInOut(duration: 0.25)) { publish(composed, continueNow: liveContinue(hub: hub)) }
        previous = HomeSeedPolicy.Previous(seed: seed, at: started)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let shown = composed
        MusicDebugLog.log("home", "composed in \(ms) ms: mode \(shown.mode.rawValue), seed \(seed), sections [\(shown.sections.map { "\($0.id)=\($0.items.count)" }.joined(separator: ", "))], top tracks \(shown.topTracks.count)")
        MusicDebugLog.log("home", "hero: \(shown.hero.map { "\($0.kind.rawValue) '\($0.item.title)' reason '\($0.reason)'" } ?? "none")")
        MusicDebugLog.log("home", "hidden: \(shown.hidden.joined(separator: "; "))")
        let toSave = composed
        let epoch = HomeFeedCache.wipeEpoch   // a wipe after this point makes the save write nothing
        Task.detached(priority: .utility) { HomeFeedCache.save(toSave, ifEpoch: epoch) }
        // Shelves from similarity services arrive after the page is already drawn.
        if !gated, !offline {
            let seen = signals.history, likedCount = signals.liked.count
            Task { [weak self] in await self?.addSimilarShelves(hub: hub, seed: seed, history: seen, likedCount: likedCount) }
        }
        // The completeness pass may have finished while this compose was running (the graph block skips such a revision): build again when the key moved.
        if !gated, graphKey != Self.graphKey(seed: seed, hub: hub) {
            Task { [weak self] in await self?.loadGraph(hub: hub, seed: seed, force: false) }
        }
        return false
    }

    /// "Picked for you" (ListenBrainz) and "Because you play X" (Last.fm), both from the person's own listening. Nothing
    /// personal is asked for in a private session; after a reset only the listening since the reset is used; a thin history gets no generic list in its place.
    private func addSimilarShelves(hub: MusicHub, seed: UInt64, history: [PlayRecord], likedCount: Int) async {
        let state = MusicSimilarityRules.personal(isPrivate: MusicPrivateListening.shared.isOn, seedCount: history.count + likedCount)
        guard state != .privateSession else { return }
        let sources = hub.registry.metadata.filter { !MusicSearchEnrichment.isCatalogueOnly($0.capabilities) }
        guard !sources.isEmpty else { return }
        let hidden = MusicHiddenRecommendations.shared.set
        let service = MusicSimilarityService.shared
        // Songs that sound alike come from every language; the shelf keeps to the languages this person actually plays (read from their plays, for anyone).
        let played = history.filter { HomeTaste.counts($0) && !($0.track.isPodcast ?? false) }.prefix(300).map(\.track)
        let graphStore = MusicEntityRuntime.shared.store.graph
        // A song's language comes from its source, its script, or the graph's record of its film or album (most titles are in Latin letters and state nothing).
        let playedLanguages = await MusicGraphLanguage.languages(of: Array(played), store: graphStore)
        let listened = MusicSimilarityRules.listenedLanguages(Array(played), known: playedLanguages)
        func tracks(_ candidates: [MusicSimilarCandidate]) async -> [MusicTrack] {
            let found = await service.resolve(candidates, using: sources, limit: 12)
            let candidateLanguages = listened.isEmpty ? [:] : await MusicGraphLanguage.languages(of: found, store: graphStore)
            return MusicSimilarityRules.filtered(found, hidden: hidden, isBlocked: { hub.library.isBlacklisted($0) }, languages: listened, known: candidateLanguages)
        }
        var sections: [HomeSection] = []
        func shelf(_ id: String, _ kind: HomeSectionKind, _ title: String, _ reason: String?, _ raw: [MusicTrack], because: String? = nil) {
            var seenIDs = Set<String>()
            let list = raw.filter { seenIDs.insert(HomeItem.make($0).id).inserted }   // one tile per song: a repeated id would break the ForEach
            guard list.count >= 4, !(feed?.sections.contains { $0.id == id } ?? false) else { return }   // a similar shelf is added once, even if two composes share a seed
            sections.append(HomeSection(id: id, kind: kind, title: title, reason: reason, items: list.map { var i = HomeItem.make($0); i.becauseOf = because; return i }))
        }
        if state == .allowed {
            let mine = await tracks(await service.personal(state, afterReset: MusicTasteReset.cutoff != nil))
            shelf("similar.personal", .madeForYou, Localized.string("Picked for you"), Localized.string("Based on what you have listened to"), mine)
            var counts: [String: (MusicTrack, Int)] = [:]
            for r in history.prefix(300) where HomeTaste.counts(r) && !(r.track.isPodcast ?? false) && !hidden.hides(r.track) { let k = HomeKeys.recording(r.track); counts[k] = (r.track, (counts[k]?.1 ?? 0) + 1) }
            if let top = counts.values.max(by: { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.uid > $1.0.uid })?.0 {
                let like = await tracks(await service.similar(to: top))
                shelf("similar.because", .because, Localized.string("Because you play %@", top.title), nil, like, because: top.artistLine)
            }
        }
        guard !sections.isEmpty, !Task.isCancelled, feed?.seed == seed else { return }
        // Checked again here, after the awaits: another compose of the same seed may have added these shelves while this one was asking.
        let have = Set(feed?.sections.map(\.id) ?? [])
        let fresh = sections.filter { !have.contains($0.id) }
        guard !fresh.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.25)) { feed?.sections.append(contentsOf: fresh) }
    }

    // MARK: graph block

    /// Builds the graph shelves (see `MusicConnectedHome`). Called with the feed and again when the completeness pass changes the graph.
    nonisolated static func graphKey(seed: UInt64, historyRevision: Int, fillRevision: Int) -> String { "\(seed)|\(historyRevision)|\(fillRevision)" }
    private static func graphKey(seed: UInt64, hub: MusicHub) -> String {
        graphKey(seed: seed, historyRevision: hub.library.historyRevision, fillRevision: MusicFillRuntime.shared.revision)
    }

    func loadGraph(hub: MusicHub, seed: UInt64, force: Bool) async {
        guard !hub.gated else { graph = []; graphPhase = .idle; return }
        let rt = MusicFillRuntime.shared
        let key = Self.graphKey(seed: seed, hub: hub)
        let needs = await applyGraph(key: key, seed: seed, force: force) { avoid in
            let history = MusicTasteReset.visible(hub.library.history).filter { !hub.library.isBlacklisted($0.track) }
            let seeds = await Task.detached(priority: .utility) { Self.listenedSeeds(history: history) }.value
            let affinity = await MusicRecommenderRuntime.shared.affinity.vector()
            // A song marked Never Play, or by an artist the person hid, must not head "Because you played ..." however much it was played.
            let hidden = MusicHiddenRecommendations.shared.set
            let silenced = Set(hub.library.history.map(\.track).filter { hub.library.isBlacklisted($0) || hidden.hides($0) }.map(MusicFillRuntime.songID))
            let input = MusicConnectedHomeInput(affinity: affinity, region: "", language: nil, preferredLanguages: [], seed: seed, recentSongs: seeds.map(MusicFillRuntime.songID), avoidSongs: avoid, excludeSongs: silenced)
            var built = await MusicConnectedHome.build(input, store: rt.store, wording: rt.wording)
            // A person the listener blocked (Never Play) is not offered as a singer, composer or actor tile. The block list holds source ids; the graph tiles carry names, so the
            // names of the blocked artists are read from the songs the library knows.
            // Nothing blocked (the usual case): the whole history is not read for it.
            let blockedNames: Set<String> = hub.library.blacklist.isEmpty ? [] : Set(hub.library.history.map(\.track).flatMap(\.artists).filter { hub.library.isBlacklisted(artist: $0) }.map { MusicText.normalize($0.name) })
            if !blockedNames.isEmpty {
                var hiddenByBlock = MusicHiddenSet(); hiddenByBlock.names = blockedNames
                built.shelves = MusicConnectedHomeBlock.withoutHidden(built.shelves, hidden: hiddenByBlock)
            }
            return built
        }
        if let needs { rt.request(needs) }
    }

    /// Runs one graph build and puts its shelves in place. `build` is handed the songs to pass over. Returns what the graph still lacks, or nil when
    /// nothing was applied (already shown, cancelled, or overtaken by a wipe or a newer compose).
    @discardableResult
    func applyGraph(key: String, seed: UInt64, force: Bool, build: @MainActor (Set<MusicEntityID>) async -> MusicFillResult) async -> [MusicEntityID]? {
        let built = generation   // taken before any await: a wipe or a newer compose during the reads below makes this answer stale
        let newDraw = graphSeed != seed
        if !force, key == graphKey, graphPhase == .loaded { return nil }
        if graph.isEmpty { graphPhase = .loading }
        if graphAvoid?.seed != seed { graphAvoid = (seed, Self.recentBecause(defaults)) }
        let result = await build(graphAvoid?.songs ?? [])
        // A newer compose started while this one was building: its graph wins, this answer is dropped.
        guard built == generation, !Task.isCancelled else { return nil }
        if newDraw, let shown = result.shelves.first(where: { $0.id == "fill.related.byComposer" })?.seeds.first { Self.noteBecause(shown, defaults) }
        let shelves = result.shelves.filter { $0.tiles.count >= HomeEngine.minItems }
        graph = newDraw ? shelves : MusicFillModel.merge(old: graph, new: shelves)
        graphSeed = seed
        graphKey = key
        graphPhase = graph.isEmpty ? .empty : .loaded
        let summary = graph.map { "\($0.id)=\($0.tiles.count)" }.joined(separator: ", ")
        MusicDebugLog.log("home", "graph shelves: \(summary)")
        return result.needsCompleteness
    }

    private nonisolated static let becauseKey = "music.home.becauseRecent"
    /// The songs "Because you played" named in the last few visits.
    nonisolated static func recentBecause(_ d: UserDefaults = .standard) -> Set<MusicEntityID> { Set((d.stringArray(forKey: becauseKey) ?? []).compactMap(MusicEntityID.init(rawValue:))) }
    nonisolated static func noteBecause(_ id: MusicEntityID, _ d: UserDefaults = .standard) {
        var list = (d.stringArray(forKey: becauseKey) ?? []).filter { $0 != id.rawValue }
        list.insert(id.rawValue, at: 0)
        d.set(Array(list.prefix(3)), forKey: becauseKey)
    }

    /// The songs the person really listened to lately, strongest first (at least half heard, the last 30 days, a play loses half its weight every 10 days).
    nonisolated static func listenedSeeds(history: [PlayRecord], limit: Int = 6, now: Date = Date()) -> [MusicTrack] {
        let since = now.addingTimeInterval(-30 * 86_400)
        var score: [String: (track: MusicTrack, s: Double, last: Date)] = [:]
        for r in history where r.at >= since && r.at <= now.addingTimeInterval(3600) && HomeTaste.counts(r) && !(r.track.isPodcast ?? false) {
            let w = pow(0.5, max(0, now.timeIntervalSince(r.at)) / 86_400 / 10)
            let e = score[r.track.uid]
            score[r.track.uid] = (r.track, (e?.s ?? 0) + w, max(e?.last ?? .distantPast, r.at))
        }
        return score.values.sorted { $0.s != $1.s ? $0.s > $1.s : ($0.last != $1.last ? $0.last > $1.last : $0.track.uid < $1.track.uid) }.prefix(limit).map(\.track)
    }
}
