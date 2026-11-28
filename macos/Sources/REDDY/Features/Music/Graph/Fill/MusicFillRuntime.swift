import SwiftUI
import Observation

// The app side of the filled screens: one runtime that owns the track-context reader, the completeness requests and the roster write, and the
// navigation every tile, chip and menu item uses (typed pages by id, a radio, or a typed search; never a dead end).

extension MusicFillWording {
    /// Every word reads from the app's string tables; `%@` and `%1$@` are filled in with the names.
    static let localized = MusicFillWording(string: { Localized.string($0) }, format: { template, args in
        var out = template
        for (i, a) in args.enumerated() { out = out.replacingOccurrences(of: "%\(i + 1)$@", with: a) }
        var next = 0
        while next < args.count, let r = out.range(of: "%@") { out.replaceSubrange(r, with: args[next]); next += 1 }
        return out
    })
}

@MainActor @Observable
final class MusicFillRuntime {
    static let shared = MusicFillRuntime()

    @ObservationIgnored private(set) var contexts: MusicTrackContextReader
    @ObservationIgnored private var asked = Set<MusicEntityID>()
    @ObservationIgnored private var sessionCount = 0
    /// Bumped when the graph changed under the filled screens (a completeness pass finished), so views refresh their tiles in place.
    private(set) var revision = 0

    private init() {
        contexts = MusicTrackContextReader(store: MusicGraphRuntime.shared.store)
        // The stricter app rule for compilation credits backs the pure one.
        MusicLinkMatrix.hook.isCompilation = { MusicCompilationArtist.isCompilation($0) }
        MusicGraphRuntime.shared.onWipe { [weak self] in await self?.reset() }
    }

    var store: any MusicGraphStoring { MusicGraphRuntime.shared.store }
    var wording: MusicFillWording { .localized }

    private func reset() async {
        await contexts.clear()
        mirror = [:]; contextRevision += 1
        asked = []; sessionCount = 0
        UserDefaults.standard.removeObject(forKey: "music.fill.rosterVersion")      // the saved marker of the removed built-in list
    }

    /// The completeness pass for what a screen shows: people and films first, a bounded few per screen and per session, through the same enrichment the pages use.
    func request(_ ids: [MusicEntityID]) {
        if MusicListeningModes.profile.pausesBackgroundWork { return }
        let plan = MusicCompletenessPlanner.plan(ids, asked: asked, sessionCount: sessionCount)
        guard !plan.isEmpty else { return }
        asked.formUnion(plan); sessionCount += plan.count
        let enricher = MusicEntityRuntime.shared.store.enricher
        Task.detached(priority: .utility) { [weak self] in
            let worker: any MusicCompletenessRequesting = MusicEnricherCompleteness(enricher: enricher)
            var changed = Set<MusicEntityID>()
            for id in plan { changed.formUnion(await worker.complete(id)) }
            guard !changed.isEmpty else { return }
            await self?.graphChanged(changed)
        }
    }

    /// The graph changed under the screens: what was read about these things (and every empty answer) is read again, and the views refresh.
    func graphChanged(_ changed: Set<MusicEntityID>) async {
        await contexts.invalidate(changed)
        mirror = mirror.filter { !changed.contains($0.key) && !changed.contains($0.value.song) && !$0.value.isEmpty }
        MusicEntityRuntime.shared.store.notifyChanged(changed)
        revision += 1
    }

    // MARK: navigation

    /// Opens a tile: a mood searches, everything else is its typed page (Back and Forward keep the page memory).
    func open(_ tile: MusicFillTile, hub: MusicHub) {
        if tile.kind == .mood { search(tile.title, hub: hub); return }
        if let local = tile.localPlaylistID.flatMap(UUID.init(uuidString:)) { hub.open(.localPlaylist(local)); return }
        hub.open(tile.entity, role: tile.role)
    }

    func search(_ words: String, hub: MusicHub) {
        hub.searchModel.browse(words)
        hub.nav.select(.search)
    }

    /// Follows a link destination. A radio starts a station seeded by the entity and says so; a search opens a typed search for the missing link.
    func follow(_ d: MusicLinkDestination, hub: MusicHub) {
        switch d {
        case .page(let id, let role): hub.open(id, role: role)
        case .radio(let seed): Task { await startRadio(seed: seed, hub: hub) }
        case .search(let q, _): search(q, hub: hub)
        }
    }

    /// A radio from any entity: the graph's songs for it, the first one that can be found on the active source starts the station.
    func startRadio(seed: MusicEntityID, hub: MusicHub) async {
        guard let plan = await MusicRadioEntitySeeds.plan(for: seed, store: store, wording: wording) else {
            MusicToasts.shared.show(Localized.string("Nothing to play here yet.")); return
        }
        guard let provider = hub.registry.activeMetadata else { MusicToasts.shared.show(Localized.string("Nothing to play here yet.")); return }
        var queries: [String] = []
        for id in plan.seedSongs.prefix(4) {
            let live = (try? await store.resolve(id)) ?? id
            guard let s = try? await store.entity(live) else { continue }
            let c = await contexts.context(for: live)
            queries.append(([s.name] + (c.singers.first.map { [$0.name] } ?? [])).joined(separator: " "))
        }
        if queries.isEmpty { queries = [plan.title] }
        for q in queries {
            if let page = try? await provider.searchTracks(q, page: nil),
               let t = MusicRadioSeedPicking.pick(page.items, languageKey: nil, blocked: { hub.library.isBlacklisted($0) }) {
                await MusicQueueActions.startRadio(t, hub: hub)
                MusicToasts.shared.show(plan.explanation)
                request([seed])
                return
            }
        }
        request([seed])
        MusicToasts.shared.show(Localized.string("Nothing to play here yet."))
    }

    // MARK: songs

    /// A main-actor copy of the contexts already read, so a menu (built at once when it opens) can list the film, music director and cast without waiting.
    @ObservationIgnored private var mirror: [MusicEntityID: MusicTrackContext] = [:]
    func cachedContext(for t: MusicTrack) -> MusicTrackContext? { mirror[Self.songID(t)] }
    /// Goes up when `warmContexts` learned something new, so a view built from `cachedContext` (the sidebar's Recent group) builds again.
    private(set) var contextRevision = 0
    /// Reads what the graph already knows about these songs into the main-actor copy. It asks no completeness pass, and an empty answer is not kept (a later read may find more).
    func warmContexts(for tracks: [MusicTrack]) async {
        var learned = false
        for t in tracks {
            let id = Self.songID(t)
            if mirror[id] != nil { continue }
            let c = await contexts.context(for: id)
            if !c.isEmpty, mirror[id] == nil { mirror[id] = c; learned = true }
        }
        if learned { contextRevision += 1 }
    }
    /// Puts a context in the main-actor copy as a read would (tests).
    func remember(_ c: MusicTrackContext, for t: MusicTrack) { mirror[Self.songID(t)] = c; contextRevision += 1 }
    /// Reads (once, cached) what the graph knows about a song's makers and film; asks the completeness pass when the graph knows nothing yet.
    func context(for t: MusicTrack) async -> MusicTrackContext {
        let id = Self.songID(t)
        if let c = mirror[id] { return c }
        let c = await contexts.context(for: id)
        if mirror.count > 3_000 { mirror.removeAll(keepingCapacity: true) }
        mirror[id] = c
        if c.isEmpty { request([id]) }
        return c
    }

    /// The graph id a song row's links hang on: the provider uid's provisional id (the same one the song page and the credits ingest use).
    nonisolated static func songID(_ t: MusicTrack) -> MusicEntityID { .provisional(kind: .recording, providerUID: t.uid) }
}
