import Foundation
import Observation

/// The film page's view model: a lease on the film's shared entity model, the sections it asks that model to load, and the few things only the page
/// needs (the Watch Movie state, songs matched to a playable copy). No SwiftUI and no player: the page passes the matcher and the bridge in.
@MainActor @Observable
final class MusicFilmGraphModel {
    typealias Matcher = @Sendable ([MusicTrack]) async -> [MusicTrack?]

    private(set) var lease: MusicEntityLease?
    /// Playable twins found for songs that had no copy in the graph (recording id to track).
    private(set) var matched: [MusicEntityID: MusicTrack] = [:]
    private(set) var resolvingSongs = false
    private(set) var watch: MusicFilmWatchState = .hidden
    /// Taps on Watch Movie that reached the bridge (tests: one tap, one call).
    @ObservationIgnored private(set) var watchPresses = 0

    @ObservationIgnored private let center: MusicEntityModelCenter
    @ObservationIgnored private let watchLogic: MusicFilmWatchLogic
    @ObservationIgnored private let matcher: Matcher?
    @ObservationIgnored private var requested: Set<String> = []
    @ObservationIgnored private var matchTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var triedMatch: Set<MusicEntityID> = []
    @ObservationIgnored private var lastWatch: (ref: MusicFilmWatchRef?, gated: Bool)?
    /// False while the catalogue cannot be asked (setting off): songs are then not marked as tried, so turning it on asks them.
    @ObservationIgnored var canAsk: @Sendable () -> Bool = { true }
    static let matchBatch = 8   // what the matcher can answer within its time budget; the rest follow in the next batch

    init(center: MusicEntityModelCenter, watch: MusicFilmWatchLogic, matcher: Matcher? = nil) {
        self.center = center; self.watchLogic = watch; self.matcher = matcher
    }

    // MARK: lease

    var entity: MusicEntityModel? { lease?.model }
    var phase: MusicEntityPhase { entity?.phase ?? .idle }
    var isSeries: Bool { entity?.id.kind == .series }

    /// Takes the lease and starts the core sections. Safe to call again for the same page.
    func open(_ id: MusicEntityID) {
        guard lease == nil else { return }
        let l = center.acquire(id)
        lease = l
        for loader in MusicFilmLoaders.core { l.model.load(loader) }
    }

    /// Leaves: stops what only this page was waiting for and gives the lease back (the model stays for its grace window, so Back is instant).
    func close() {
        matchTask?.cancel(); matchTask = nil
        watchTask?.cancel(); watchTask = nil
        lease?.release(); lease = nil
        requested = []
        // A cancelled match must not leave the skeleton up, and the next film must not inherit this one's Watch Movie. The playable twins already found stay (and
        // so does the list of songs already asked about): going Back from an album or a person onto this page must not lose them. A page is built per film
        // (`.id(route.id)`), so a new film starts with a new model.
        resolvingSongs = false; watch = .hidden; lastWatch = nil
    }

    /// Starts a lazy section once (the page calls this when the section scrolls near).
    func loadLazy(_ key: String) {
        guard let l = lease, requested.insert(key).inserted, let loader = MusicFilmLoaders.lazy(key) else { return }
        l.model.load(loader)
    }

    /// True when at least one song of the film sits on an album that is not the background score (score cues live on the Score tab, so a film with only those has nothing for Songs).
    var hasSongsOutsideScore: Bool {
        let scores = Set(scoreAlbums.map(\.album))
        return songs.contains { !scores.contains($0.album) }
    }

    /// The page's "Try again" when the film itself could not be found: the entity model loads its row again (a reopened lease alone would not, since its
    /// phase is `.failed`, not `.idle`) and the core sections run afresh.
    func reload() {
        guard let l = lease else { return }
        l.model.restart()
        for loader in MusicFilmLoaders.core { l.model.load(loader, force: l.model.section(loader.key).phase == .failed) }
    }

    /// Reloads the sections that failed (the page's retry).
    func retry() {
        guard let l = lease else { return }
        for loader in MusicFilmLoaders.core where l.model.section(loader.key).phase == .failed { l.model.load(loader, force: true) }
        // A failed lazy shelf may be asked for again the next time it comes near the screen.
        for key in requested where l.model.section(key).phase == .failed { requested.remove(key) }
    }

    // MARK: typed reads

    func section(_ key: String) -> MusicEntitySection { entity?.section(key) ?? MusicEntitySection(key: key) }
    var overview: MusicFilmOverview? { section(MusicFilmSectionKey.overview).items(MusicFilmOverview.self).first }
    var cast: [MusicFilmPersonItem] { section(MusicFilmSectionKey.cast).items(MusicFilmPersonItem.self) }
    var crew: [MusicFilmCrewItem] { section(MusicFilmSectionKey.crew).items(MusicFilmCrewItem.self) }
    var albums: [MusicFilmAlbumItem] { section(MusicFilmSectionKey.soundtracks).items(MusicFilmAlbumItem.self) }
    var originalAlbums: [MusicFilmAlbumItem] { albums.filter { $0.dubLanguage == nil } }
    /// The film's background-score albums (an original-language edition the classifier calls a score).
    var scoreAlbums: [MusicFilmAlbumItem] { originalAlbums.filter { edition(of: $0) == .score } }
    var dubbedAlbums: [MusicFilmAlbumItem] { albums.filter { $0.dubLanguage != nil } }
    /// The edition of one soundtrack album: the dub relationship, the title's words and the album's own songs agreeing (see `MusicFilmEditionRules`).
    func edition(of a: MusicFilmAlbumItem) -> MusicFilmEdition {
        MusicFilmEditionRules.classify(name: a.name, dubLanguage: a.dubLanguage, songs: songs.filter { $0.album == a.album })
    }
    var songs: [MusicFilmSongItem] { section(MusicFilmSectionKey.songs).items(MusicFilmSongItem.self) }
    /// The singers of the film's own (original-language) songs. A dubbed album's singers sing the dub, not the film, so they are not counted here.
    var singers: [MusicFilmSingerItem] { singers(for: .original) }
    /// The singers of the songs a language filter lets through (the film's own songs, or one dub).
    func singers(for filter: MusicFilmLanguageFilter) -> [MusicFilmSingerItem] {
        // The same songs the list shows: each recording once (it can sit on the original and a deluxe album) and no score cues.
        let scores = Set(scoreAlbums.map(\.album))
        let shown = songs.filter { (filter == .all ? $0.dubLanguage == nil : filter.matches(dubLanguage: $0.dubLanguage)) && !scores.contains($0.album) }
        return MusicFilmPageBuilders.singers(from: MusicFilmSongRules.uniqueRecordings(shown))
    }
    var versions: [MusicFilmVersionItem] { section(MusicFilmSectionKey.versions).items(MusicFilmVersionItem.self) }
    var related: [MusicFilmRelatedItem] { section(MusicFilmSectionKey.related).items(MusicFilmRelatedItem.self) }
    var directorFilms: [MusicFilmRelatedItem] { section(MusicFilmSectionKey.directorFilms).items(MusicFilmRelatedItem.self) }
    var composerMusic: [MusicFilmAlbumItem] { section(MusicFilmSectionKey.composerMusic).items(MusicFilmAlbumItem.self) }
    var castMusic: [MusicFilmAlbumItem] { section(MusicFilmSectionKey.castMusic).items(MusicFilmAlbumItem.self) }

    /// What the music part of the page shows now.
    var musicPlan: MusicFilmPageBuilders.MusicPlan {
        MusicFilmPageBuilders.musicPlan(soundtracks: section(MusicFilmSectionKey.soundtracks).phase, songs: section(MusicFilmSectionKey.songs).phase,
                                        haveAlbums: !albums.isEmpty, haveSongs: !songs.isEmpty,
                                        enriching: (entity?.isWorking ?? false) || (entity.map { MusicCompletenessTracker.shared.isRunning($0.id) } ?? false))
    }

    /// Songs of one album group that the player can start now (a direct copy, or a matched twin), in order.
    func playable(in group: [MusicFilmSongItem]) -> [MusicTrack] { MusicFilmSongRules.queue(songs: group, matched: matched) }
    /// The music videos of the film's songs: only where the music service itself says a song has a video twin (or the copy is itself a video). Nothing is searched for and no
    /// unofficial upload is added; a song whose service names no video simply has none here.
    var musicVideos: [MusicTrack] {
        var seen = Set<String>()
        return playableOriginals.compactMap { t -> MusicTrack? in
            var v = t
            if t.isVideo == true { v.videoID = t.videoID ?? t.id }
            else if let twin = t.counterpartVideoID, !twin.isEmpty { v.id = twin; v.videoID = twin; v.isVideo = true; v.counterpartVideoID = t.id }
            else { return nil }
            return seen.insert(v.videoID ?? v.id).inserted ? v : nil
        }
    }
    /// The film's own songs that count as songs: original-language albums except background-score editions (their cues are not songs), each recording once.
    var ownSongs: [MusicFilmSongItem] {
        let scores = Set(scoreAlbums.map(\.album))
        let all = songs.filter { $0.dubLanguage == nil && !scores.contains($0.album) }
        return MusicFilmSongRules.uniqueRecordings(all)
    }
    var playableOriginals: [MusicTrack] { playable(in: ownSongs) }
    /// Songs of the film that exist in the graph but have no copy to play on the person's sources.
    var unplayableCount: Int { songs.filter { !$0.playsDirectly && matched[$0.recording] == nil }.count }
    /// The same count for what the Songs tab shows under a language choice: each recording once, background-score cues left out (they are not songs).
    func unplayableCount(for filter: MusicFilmLanguageFilter) -> Int {
        let scores = Set(scoreAlbums.map(\.album))
        let shown = songs.filter { filter.matches(dubLanguage: $0.dubLanguage) && !scores.contains($0.album) }
        return MusicFilmSongRules.uniqueRecordings(shown).filter { !$0.playsDirectly && matched[$0.recording] == nil }.count
    }

    // MARK: songs without a copy

    /// Asks the catalogue for playable twins of the songs the graph holds no copy of: a bounded batch, in the background, and cancelled on leaving.
    /// A song that finds no twin is not shown as playable and is not asked again.
    func resolveUnplayable() {
        guard matchTask == nil, let matcher else { return }
        // Only songs the page can show are looked up: no score cues (Songs and the header leave them out), and the film's own songs before any dub.
        let hiddenAlbums = Set(scoreAlbums.map(\.album))
        let candidates = songs.filter { !$0.playsDirectly && matched[$0.recording] == nil && !triedMatch.contains($0.recording) && !hiddenAlbums.contains($0.album) }
        let pending = (candidates.filter { $0.dubLanguage == nil } + candidates.filter { $0.dubLanguage != nil }).prefix(Self.matchBatch)
        guard !pending.isEmpty else { return }
        let items = Array(pending)
        resolvingSongs = true
        let rows = items.map(MusicFilmSongRules.catalogueRow)
        matchTask = Task { [weak self] in
            let twins = await matcher(rows)
            guard !Task.isCancelled, let self else { return }
            let asked = self.canAsk()
            if asked { for i in items { self.triedMatch.insert(i.recording) } }
            var found: [MusicEntityID: MusicTrack] = [:]
            for (i, t) in twins.enumerated() where i < items.count { if let t { found[items[i].recording] = t } }
            self.matched.merge(found) { $1 }
            self.resolvingSongs = false
            self.matchTask = nil
            if asked { self.resolveUnplayable() }   // the next batch, until every song has been asked once
        }
    }

    // MARK: Watch Movie

    /// Works out the button: needs the film's TMDB id (from the graph), so it is recomputed when the film row or its ids change.
    func refreshWatch(gated: Bool, force: Bool = false) {
        watchTask?.cancel()
        guard let l = lease else { watch = .hidden; return }
        if gated { watch = .hidden; lastWatch = nil; return }   // forgotten, so lifting the gate works the button out again
        let graph = center.store.graph, id = l.model.id
        watchTask = Task { [weak self] in
            let snap = try? await graph.entity(id)
            let ids = (try? await graph.externalIDs(of: id)) ?? []
            guard !Task.isCancelled, let self else { return }
            let ref = MusicFilmWatchRefs.ref(snapshot: snap, externalIDs: ids)
            // The library match is a database read on the main actor: the same film asked again with the same gate keeps its answer (a press that was refused forces a fresh one).
            if !force, let last = self.lastWatch, last.ref == ref, last.gated == gated { return }
            self.lastWatch = (ref, gated)
            self.watch = self.watchLogic.state(for: ref, gated: gated)
        }
    }

    /// The Watch Movie tap: one call to the bridge, no other effect. The music queue and the player are not referenced here.
    @discardableResult
    func pressWatch(gated: Bool) -> MusicFilmWatchLogic.Outcome {
        guard case .available(let ref) = watch else { return .unavailable }
        watchPresses += 1
        let outcome = watchLogic.press(ref)
        if outcome == .unavailable { refreshWatch(gated: gated, force: true) }
        return outcome
    }
}
