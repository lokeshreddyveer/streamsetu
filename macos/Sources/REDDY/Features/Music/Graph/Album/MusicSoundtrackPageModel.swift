import Foundation
import Observation

// The page model of the album / soundtrack page. It holds the lease on the shared entity model (the page and the right panel read the same loads),
// starts each section when the page asks for it, loads the playable tracklist from the PROVIDER (so Play works the moment the page opens, whatever
// the metadata layer knows), and reads the typed values out of the sections. It never references the player's state beyond handing it a list.

@MainActor @Observable
final class MusicSoundtrackPageModel {
    enum SongsState: Equatable { case idle, loading, loaded, failed, empty, noEdition }

    let entity: MusicEntityID
    let hub: MusicHub
    private(set) var lease: MusicEntityLease?
    private(set) var songsState = SongsState.idle
    /// True when the first page of songs came but a later page failed: the list on screen is shorter than the album, and the page says so with a retry.
    private(set) var songsPartial = false
    @ObservationIgnored private var askedForFreshSongs = false
    @ObservationIgnored private var earlyKeys: [String] = []
    /// The song list failed or stopped short: rows that come from the graph alone are then not playable here, and the page offers "Try again" beside them.
    var songsNeedRetry: Bool { songsPartial || songsState == .failed }
    private(set) var rows: [MusicSoundtrackSongRow] = []
    /// The provider's tracks, in order. Play uses these directly.
    private(set) var tracks: [MusicTrack] = []
    /// The provider's own album value (Favorite, Share, Add to playlist work on it); nil when the album has no provider edition.
    private(set) var providerAlbum: MusicAlbum?
    /// The actor chosen in section E's filter, kept in the page memory so Back returns to it.
    private(set) var selectedActor: MusicEntityID?

    @ObservationIgnored private var loaders: [String: any MusicEntitySectionLoader] = [:]
    @ObservationIgnored private var requested = Set<String>()
    @ObservationIgnored private var songsTask: Task<Void, Never>?
    /// Names the load that is current; a finished or cancelled older load never clears the handle or the partial flag of a newer one.
    @ObservationIgnored private var loadToken = UUID()
    @ObservationIgnored private var singersTask: Task<Void, Never>?
    @ObservationIgnored private var singerLines: [MusicEntityID: [String]] = [:]
    @ObservationIgnored private var lites: [MusicSoundtrackTrackLite] = []
    /// The position of each provider track by uid, so a row finds its track without scanning the list on every redraw.
    @ObservationIgnored private var indexByUID: [String: Int] = [:]
    @ObservationIgnored private var recordings: [MusicSoundtrackRecording] = []

    @ObservationIgnored private let routeKey: String?

    init(entity: MusicEntityID, hub: MusicHub, memoryKey: String? = nil) {
        self.entity = entity; self.hub = hub; self.routeKey = memoryKey
    }

    private var center: MusicEntityModelCenter { MusicEntityRuntime.shared.center }
    private var graph: any MusicGraphStoring { MusicEntityRuntime.shared.store.graph }
    var model: MusicEntityModel? { lease?.model }
    private var memoryKey: String { routeKey ?? hub.nav.top?.scrollKey ?? MusicRoute.entity(entity).scrollKey }

    // MARK: lifecycle

    func start() {
        guard lease == nil else { return }
        lease = center.acquire(entity)
        let hooks = MusicSoundtrackHooks.app(hub: hub)
        for l in MusicSoundtrackLoaders.all(hooks: hooks) { loaders[l.key] = l }
        selectedActor = MusicPageMemoryCenter.shared.memory(for: memoryKey).filters["actor"].flatMap(MusicEntityID.init(rawValue:))
        // the top of the page loads at once; the shelves load when they come near the screen
        for key in [MusicSoundtrackKey.header, MusicSoundtrackKey.credits, MusicSoundtrackKey.cast] + earlyKeys { ensure(key) }
        earlyKeys = []
        lateReads = 0
        startSongs()
    }

    func stop() {
        songsTask?.cancel(); singersTask?.cancel()
        songsTask = nil; singersTask = nil
        loadToken = UUID()
        lease?.release(); lease = nil
        requested = []; earlyKeys = []
        if songsState == .loading { songsState = .idle }
    }

    /// Starts a section's load (once). Called when the shelf comes near the screen.
    func ensure(_ key: String) {
        // A shelf can come near the screen before the page has started: its request waits and runs from `start()` instead of being dropped.
        guard lease != nil else { if !earlyKeys.contains(key) { earlyKeys.append(key) }; return }
        guard let model, let loader = loaders[key], requested.insert(key).inserted else { return }
        model.load(loader)
    }

    /// Refresh metadata: every section that has loaded is read again, the entity row is re-read and the songs are asked for once more.
    func refreshMetadata() {
        for key in requested { reload(key) }
        Task { await model?.refresh() }
        retrySongs()
    }

    /// Runs a failed section again (a pull to refresh or the page coming back online).
    func reload(_ key: String) {
        guard let model, let loader = loaders[key] else { return }
        model.load(loader, force: true)
    }

    // MARK: typed sections

    private func section(_ key: String) -> MusicEntitySection { model?.section(key) ?? MusicEntitySection(key: key) }
    func phase(_ key: String) -> MusicSectionPhase { section(key).phase }
    func sources(_ key: String) -> [MusicSourceID] { section(key).provenance.compactMap(\.source) }

    var header: MusicSoundtrackHeaderFacts? { section(MusicSoundtrackKey.header).items(MusicSoundtrackHeaderFacts.self).first }

    /// What the header shows: the loaded facts, or (until they arrive) what the entity row alone says, so the title and cover appear in the first frame.
    var displayHeader: MusicSoundtrackHeaderFacts? {
        if let header { return header }
        guard let s = model?.snapshot else { return nil }
        return MusicSoundtrackHeaderFacts(title: MusicTitleCase.recordTitle(s.name, subkind: s.subkind), year: s.year, languageName: MusicSoundtrackBuild.languageName(s.lang), subkind: s.subkind, imageRef: s.imageRef,
                                          filmHint: s.attrs["filmHint"])
    }

    /// The cover: the provider's own artwork first (the original cover), then the entity's picture.
    var coverThumbs: [MusicThumbnail] {
        if let t = providerAlbum?.thumbnails, !t.isEmpty { return t }
        return MusicGraphThumbs.thumbs(displayHeader?.imageRef)
    }
    var creditGroups: [MusicSoundtrackCreditGroup] { section(MusicSoundtrackKey.credits).items(MusicSoundtrackCreditGroup.self) }
    /// Every (person, role) credit, unmerged: what the Credits pill, "View credits" and the contributor sheet read.
    var rawCredits: [MusicSoundtrackCredit] { section(MusicSoundtrackKey.credits).items(MusicSoundtrackCredit.self) }
    var cast: [MusicSoundtrackCast] { section(MusicSoundtrackKey.cast).items(MusicSoundtrackCast.self) }
    var allFilms: [MusicSoundtrackFilmItem] { section(MusicSoundtrackKey.moreFilms).items(MusicSoundtrackFilmItem.self) }
    var films: [MusicSoundtrackFilmItem] { MusicSoundtrackFilmFilter.apply(allFilms, actor: selectedActor) }
    var links: [MusicSoundtrackLink] { section(MusicSoundtrackKey.explore).items(MusicSoundtrackLink.self).filter { $0.target != .radio || !tracks.isEmpty } }

    /// The actors the film filter offers: those of this page's cast who appear in a listed film, in billing order.
    var filterActors: [MusicSoundtrackPerson] {
        var seen = Set<MusicEntityID>(), out: [MusicSoundtrackPerson] = []
        for f in allFilms { for a in f.actors where seen.insert(a.id).inserted { out.append(a) } }
        let order = Dictionary(uniqueKeysWithValues: cast.enumerated().map { ($1.person.id, $0) })
        return out.sorted { (order[$0.id] ?? Int.max, $0.name) < (order[$1.id] ?? Int.max, $1.name) }
    }

    /// Shelves F, G, I and J after cross-section de-duplication (a soundtrack shown in an earlier shelf is not repeated, and the opened album's own cluster never appears).
    struct Shelves {
        var soundtracksOfCast: [MusicSoundtrackAlbum] = []
        var byComposers: [MusicSoundtrackEntry] = []
        var related: [MusicSoundtrackAlbum] = []
        var classic: [MusicSoundtrackAlbum] = []
    }

    var shelves: Shelves {
        let f = section(MusicSoundtrackKey.soundtracksOfCast).items(MusicSoundtrackAlbum.self)
        let g = section(MusicSoundtrackKey.moreByComposers).items(MusicSoundtrackEntry.self)
        let i = section(MusicSoundtrackKey.related).items(MusicSoundtrackAlbum.self)
        let j = section(MusicSoundtrackKey.classic).items(MusicSoundtrackAlbum.self)
        let gAlbums = g.compactMap { e -> MusicSoundtrackAlbum? in if case .album(let a) = e { a } else { nil } }
        let seed = seedCluster
        let deduped = MusicSoundtrackDedupe.apply([f, gAlbums, i, j], excluding: seed.map { [$0] } ?? [])
        let keep = Set(deduped[1].map(\.cluster))
        var shown = Set<String>()
        let gOut = g.filter { e in
            switch e {
            case .album(let a): keep.contains(a.cluster)
            case .song(let s): shown.insert(s.id.rawValue).inserted
            }
        }
        return Shelves(soundtracksOfCast: deduped[0], byComposers: gOut, related: deduped[2], classic: deduped[3])
    }

    private var seedCluster: String? {
        guard let h = header else { return nil }
        return MusicSoundtrackCluster.key(id: entity, title: h.title, year: h.year, film: h.film?.id)
    }

    /// The H shelf. Songs by the singers, with no repeats of what G already lists.
    var bySingers: [MusicSoundtrackSong] {
        let g = Set(section(MusicSoundtrackKey.moreByComposers).items(MusicSoundtrackEntry.self).compactMap { e -> MusicEntityID? in if case .song(let s) = e { s.id } else { nil } })
        return section(MusicSoundtrackKey.moreBySingers).items(MusicSoundtrackSong.self).filter { !g.contains($0.id) }
    }

    // MARK: the filter in E

    func select(actor: MusicEntityID?) {
        selectedActor = actor
        MusicPageMemoryCenter.shared.update(memoryKey) { m in
            if let actor { m.filters["actor"] = actor.rawValue } else { m.filters["actor"] = nil }
        }
    }

    // MARK: songs (B): provider data first

    private func startSongs() {
        guard songsTask == nil else { return }
        songsState = .loading
        let token = UUID()
        loadToken = token
        songsTask = Task { [weak self] in
            await self?.loadSongs(token: token)
            if let self, self.loadToken == token { self.songsTask = nil }
        }
    }

    /// How many times a page with no songs has read them again because the graph changed (reset when the page opens), so it can never loop.
    private var lateReads = 0
    static let lateReadLimit = 4

    /// The graph changed under the page (enrichment landed). An album the graph had never seen opens with nothing to list: no edition, no songs. When the graph then learns its
    /// songs (from MusicBrainz, a catalogue, the film), a page still showing none reads them again by itself, quietly, instead of waiting for the person to press Try again.
    /// A page that already shows songs, or is reading them now, is left alone.
    func graphChanged() {
        guard songsTask == nil, tracks.isEmpty, rows.isEmpty, lateReads < Self.lateReadLimit, [SongsState.empty, .noEdition, .idle].contains(songsState) else { return }
        lateReads += 1
        let nth = lateReads, limit = Self.lateReadLimit
        MusicDebugLog.log("album", "graph changed with no songs on the page: reading them again (\(nth) of \(limit))")
        startSongs()
    }

    func retrySongs() {
        askedForFreshSongs = true
        songsTask?.cancel(); songsTask = nil
        songsPartial = false
        loadToken = UUID()
        startSongs()
    }

    /// The last-resort bound on pages read for one album; a normal album ends long before it.
    private static let pageCeiling = 100

    private func loadSongs(token: UUID) async {
        let reader = MusicSoundtrackReader(graph)
        let family = await reader.family(of: entity)
        recordings = await reader.recordings(family)
        guard !Task.isCancelled else { return }
        var loaded: [MusicTrack] = []
        var failed = false
        var anyFailed = false
        var album: MusicAlbum?
        var hadEdition = false
        // Every source that holds this album is tried in turn: when the first cannot give its songs (an error, an empty answer), the next one is asked.
        let refs = await MusicSoundtrackSongs.providerAlbums(reader, family: family, enabled: hub.registry.enabled)
        for ref in refs {
            guard loaded.isEmpty, !Task.isCancelled, let provider = hub.registry.metadataProvider(id: ref.provider) else { continue }
            failed = false
            hadEdition = true
            // "Refresh metadata" and "Try again" ask the source, not the saved copy; so does a local folder, whose files change under the app.
            if askedForFreshSongs || provider.id == LocalFilesProvider.providerID {
                askedForFreshSongs = false
                await MusicPageCache.shared.forgetAlbum(providerID: provider.id, id: ref.id)
            }
            do {
                var page: MusicPagination?
                // Pages are read until the source says there are no more. A source that repeats a cursor, or sends a page with nothing new, has stopped paging and
                // is treated as finished; 100 pages is only the last resort against a source that never ends, and then the list is marked as incomplete.
                var seenCursors = Set<MusicPagination>()
                var n = 0
                var seen = Set<String>()
                while true {
                    // The first page comes from the saved copy when there is one (and is refreshed behind it); later pages are always live.
                    let p = n == 0 ? try await MusicPageCache.shared.albumTracksFirstPage(provider: provider, id: ref.id).page
                                   : try await provider.albumTracks(id: ref.id, page: page)
                    // `seen` also drops a uid repeated inside one page, so row ids stay unique.
                    let fresh = MusicSoundtrackSongs.unseen(p.items, seen: &seen)
                    loaded += fresh
                    // The first page of songs is on screen at once; later pages and everything below only add to it.
                    if n == 0, !loaded.isEmpty, !Task.isCancelled { publishSongs(loaded, failed: false) }
                    guard let next = p.next, !fresh.isEmpty, seenCursors.insert(next).inserted else { break }
                    n += 1
                    if n >= Self.pageCeiling { if loadToken == token { songsPartial = true }; break }
                    page = next
                }
                album = await MusicPageCache.shared.album(provider: provider, id: ref.id)
            } catch {
                // A cancelled load (leave, retry) says nothing about the album and must not touch the state a newer load owns.
                if Task.isCancelled || error is CancellationError || loadToken != token { return }
                failed = loaded.isEmpty; songsPartial = !loaded.isEmpty
                if loaded.isEmpty { anyFailed = true }
                // The songs read so far are kept; the album itself (heart, artist line, library) still comes from the saved copy when there is one.
                if !loaded.isEmpty { album = await MusicPageCache.shared.album(provider: provider, id: ref.id) }
            }
        }
        guard !Task.isCancelled else { return }
        // A source that threw and a later one that answered with nothing is still a failed load (Try again), not "no songs".
        if loaded.isEmpty, anyFailed { failed = true }
        // A failed refresh must not wipe a list that is already on screen: keep the songs and rows, and say the list may be incomplete.
        if MusicAlbumPageLogic.keepsCurrentSongs(failed: failed, loadedCount: loaded.count, currentCount: tracks.count) {
            if loadToken == token { songsPartial = true; songsState = .loaded }
            return
        }
        publishSongs(loaded, failed: failed)
        // The graph knows songs of this album that no source listed: each is matched to a playable copy, so the row can be played (not only read).
        if loaded.isEmpty, !recordings.isEmpty { await resolveGraphOnlyRows(token: token) }
        guard !Task.isCancelled, loadToken == token else { return }
        // No edition of this album could be asked (no source holds it): that is not an empty answer from a source.
        if MusicAlbumPageLogic.isNoEdition(loadedCount: loaded.count, failed: failed, hadEdition: hadEdition) { songsState = .noEdition }
        refineSingers()
        // After the first paint: the album facts, the graph and the catalogue improvement (a failure or a slow answer keeps the plain list).
        guard let a = album else { return }
        providerAlbum = a
        if !loaded.isEmpty { MusicGraphIngest.shared.ingest(album: a, tracks: loaded) }
        guard !loaded.isEmpty, MusicCatalogRuntime.shared.isEnabled, let m = MusicCatalogRuntime.shared.matcher else { return }
        let plain = loaded
        let better = await MusicFirstPaint.improved(deadline: 12) { await m.enrichAlbum(a, tracks: plain).tracks }
        guard !Task.isCancelled, let better, MusicFirstPaint.shouldReplace(painted: plain.map(\.uid), enriched: better.map(\.uid)) else { return }
        publishSongs(better, failed: false)
        refineSingers()
    }

    /// Graph recording -> the uid of the playable copy found for it.
    private var resolvedRows: [MusicEntityID: String] = [:]

    /// Finds a playable copy for each song the graph lists on this album when no source gave a track list. Rows keep their graph identity (Song details still opens); only
    /// their playing is added. A song with no copy stays "Not playable from here".
    private func resolveGraphOnlyRows(token: UUID) async {
        // The singers are read first: a match needs a credited name to tell a song from a same-titled one.
        if singerLines.isEmpty {
            let lines = await MusicSoundtrackBuild.singerLines(MusicSoundtrackReader(graph), recordings: recordings.map(\.id))
            guard !Task.isCancelled, loadToken == token else { return }
            singerLines = lines
        }
        let names = (providerAlbum?.artists ?? []).map(\.name)
        let cands = recordings.map { r -> MusicTrack in
            let singers = singerLines[r.id] ?? []
            let artists = (singers.isEmpty ? names : singers).map { MusicArtistRef(id: "", name: $0) }
            return MusicTrack(id: r.id.rawValue, providerID: "catalogue", title: r.title, durationMs: Int64(r.durationMs ?? 0), artists: artists)
        }
        let found = await MusicFilmCatalogueMatch.run(cands)
        guard !Task.isCancelled, loadToken == token else { return }
        var add: [MusicTrack] = []
        for (i, t) in found.enumerated() where i < recordings.count {
            guard let t else { continue }
            resolvedRows[recordings[i].id] = t.uid
            add.append(t)
        }
        guard !add.isEmpty else { return }
        tracks += add
        indexByUID = Dictionary(tracks.enumerated().map { ($1.uid, $0) }, uniquingKeysWith: { first, _ in first })
        rebuildRows()
    }

    private func publishSongs(_ loaded: [MusicTrack], failed: Bool) {
        if !loaded.isEmpty { resolvedRows = [:] }
        tracks = loaded
        indexByUID = Dictionary(loaded.enumerated().map { ($1.uid, $0) }, uniquingKeysWith: { first, _ in first })
        lites = loaded.map { MusicSoundtrackTrackLite(uid: $0.uid, title: $0.title, durationMs: $0.durationMs, artistLine: $0.artistLine, disc: $0.discNumber, number: $0.trackNumber, explicit: $0.explicit) }
        rebuildRows()
        songsState = failed ? .failed : (loaded.isEmpty ? .empty : .loaded)
    }

    private func rebuildRows() {
        rows = MusicSoundtrackSongs.rows(provider: lites, recordings: recordings, singers: singerLines, resolved: resolvedRows)
    }

    /// Reads the singers of the rows from the graph and swaps them in place (the row's line box is fixed, so nothing moves).
    func refineSingers() {
        singersTask?.cancel()
        let ids = rows.map(\.id)
        guard !ids.isEmpty else { return }
        let graph = self.graph
        singersTask = Task { [weak self] in
            let lines = await MusicSoundtrackBuild.singerLines(MusicSoundtrackReader(graph), recordings: ids)
            guard !Task.isCancelled, let self, lines != self.singerLines else { return }
            self.singerLines = lines
            self.rebuildRows()
        }
    }

    /// The provider track behind a row.
    func track(for row: MusicSoundtrackSongRow) -> MusicTrack? { row.trackUID.flatMap { indexByUID[$0] }.map { tracks[$0] } }

    // MARK: actions (plain values to the hub; nothing here touches the player's state)

    var canPlay: Bool { !tracks.isEmpty }

    /// The country of the store the songs were asked from, in words (nil when none is chosen).
    var storefrontName: String? { MusicCatalogRuntime.shared.country.map { MusicDiscoveryRegion.name($0) } }

    func play(row: MusicSoundtrackSongRow) {
        guard let uid = row.trackUID, let i = indexByUID[uid] else { return }
        hub.play(tracks, at: i, sourceName: displayHeader?.title)
    }

    var totalDurationMs: Int64 { tracks.reduce(0) { $0 + $1.durationMs } }

    /// The link to hand out: the source's own album link (it opens on any device that has that source), else this page's entity link (it opens only where the
    /// graph already holds the album). A folder of local files has no link another device could open.
    var shareURL: URL? {
        if let a = providerAlbum, a.providerID != LocalFilesProvider.providerID, let url = MusicDeepLinks.link(album: a) { return url }
        return MusicDeepLinks.link(route: .albumPage(entity))
    }
}
