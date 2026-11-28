import Foundation
import SwiftUI
import Observation

/// The top-level places in Music. Listen Now (`home`), Explore, Recently Added, Search, Library and Radio are the main six; Downloads, Devices, Listen Together and
/// Settings sit in the sidebar's quiet "More" group (see `MusicSection.group`).
enum MusicSection: String, CaseIterable, Identifiable, Sendable {
    case home, explore, recentlyAdded, search, library, radio, downloads, devices, room, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: Localized.string("Listen Now")
        case .explore: Localized.string("Explore")
        case .recentlyAdded: Localized.string("Recently Added")
        case .search: Localized.string("Search")
        case .library: Localized.string("Your Library")
        case .radio: Localized.string("Radio")
        case .downloads: Localized.string("Downloads")
        case .devices: Localized.string("Devices")
        case .room: Localized.string("Listen Together")
        case .settings: Localized.string("Settings")
        }
    }
    var symbol: String {
        switch self {
        case .home: "play.circle"; case .explore: "safari"; case .recentlyAdded: "clock.badge.checkmark"; case .search: "magnifyingglass"; case .library: "heart.text.square"
        case .radio: "dot.radiowaves.left.and.right"
        case .downloads: "arrow.down.circle"; case .devices: "hifispeaker.2"; case .room: "person.2.wave.2"; case .settings: "gearshape"
        }
    }
    /// A drawn glyph where the icon set has one; the sidebar prefers it over the symbol.
    var glyph: MusicGlyph? {
        switch self {
        case .radio: .radio
        case .devices: .devices
        default: nil
        }
    }
}

/// Owns everything Music needs and nothing else: the provider registry, the person's library, the player and its helpers.
/// Nothing touches the network until the consent screen has been completed.
@MainActor @Observable
final class MusicHub {
    static let shared = MusicHub()

    let registry: MusicRegistry
    let library: MusicLibrary
    let resolver: MusicStreamResolver
    let player: MusicPlayer
    let lyrics: MusicLyricsService
    let downloads: MusicDownloads
    let scrobbler: MusicScrobbler
    let plugins: MusicPluginManager
    /// Goes up each time the person presses the toolbar's Refresh. A page that really refetches (Listen Now) compares it with the last one it handled.
    @ObservationIgnored var userRefreshToken = 0
    /// Set by Library's "Recently added" link: the Recently Added page then shows the dated list of what was saved first, for as long as that section stays selected (MusicMainView clears it when another is chosen).
    @ObservationIgnored var recentlyAddedLeadsWithLibrary = false
    /// A sidebar shortcut (Songs, Albums, Artists, Recently Added...) asks Your Library to show that tab; the page takes the request when it appears or changes.
    var libraryTabRequest: (tab: MusicLibraryTab, standalone: Bool)?
    /// The one list Your Library is showing on its own page (nil for the full library). The library page reports it; the sidebar lights that shortcut.
    var standaloneLibraryTab: MusicLibraryTab?
    /// Goes up when the sidebar's Your Library row is pressed, so a library page opened on its own (Songs, Albums...) goes back to the full library.
    var libraryResetToken = 0
    /// Counts changes of the connection (online, offline, another kind of link). Pages that show a different thing offline watch it: the network watch itself is not observable.
    private(set) var networkRevision = 0
    @ObservationIgnored private let defaults: UserDefaults
    let searchModel: MusicSearchModel
    let sleepTimer: MusicSleepTimer
    let matchOverrides: MusicMatchOverrides
    /// The one translation service for lyrics. The lyrics panel and its toolbar use this instance.
    let translation: MusicLyricsTranslationService
    @ObservationIgnored var translationUID: String?
    /// The system translator behind it (macOS 15 and later); the lyrics view hosts its session. Nil where the system has none.
    let translationBridge: AnyObject?
    /// Listen Together: off until the person starts or joins a room.
    let room: MusicRoomSession
    var nav = MusicNav()
    /// The song whose "Choose another audio source" sheet is open; the main view presents it.
    var alternativesTrack: MusicTrack?
    /// The full-window Now Playing is open.
    var expandedPlayer = false
    /// The player bar shows its compact form even when the window is wide.
    var miniPlayer = UserDefaults.standard.bool(forKey: "music.bar.compact") {
        didSet { if miniPlayer != oldValue { UserDefaults.standard.set(miniPlayer, forKey: "music.bar.compact") } }
    }
    @ObservationIgnored private var attached = false
    /// True while the app is locked or a Kids profile is on. Nothing in Music talks to the network, listens for other devices or plays.
    private(set) var gated = false

    static var supportDirectory: URL { MusicStorage.root }

    init(directory: URL = MusicHub.supportDirectory, defaults: UserDefaults = .standard) {
        let registry = MusicRegistry(defaults: defaults)
        let library = MusicLibrary(directory: directory)
        let resolver = MusicStreamResolver(registry: registry)
        self.defaults = defaults
        self.registry = registry
        self.library = library
        self.resolver = resolver
        let player = MusicPlayer(resolver: resolver, library: library)
        self.player = player
        self.sleepTimer = MusicSleepTimer(player: player)
        self.room = MusicRoomSession(player: player, hasAudioSource: { !registry.audio.isEmpty })
        self.matchOverrides = MusicMatchOverrides(directory: directory)
        resolver.matchOverrides = self.matchOverrides
        resolver.log = MusicPlaybackLog.shared
        resolver.chain = MusicSourceChain(store: .shared, registry: registry)
        self.lyrics = MusicLyricsService(registry: registry, cacheDirectory: directory.appendingPathComponent("Lyrics", isDirectory: true))
        self.downloads = MusicDownloads(resolver: resolver, directory: directory.appendingPathComponent("Downloads", isDirectory: true))
        self.scrobbler = MusicScrobbler(registry: registry, library: library)
        self.plugins = MusicPluginManager(registry: registry, directory: directory.appendingPathComponent("Plugins", isDirectory: true))
        self.searchModel = MusicSearchModel(registry: registry, defaults: defaults)
        let translation = MusicLyricsTranslationService(cacheDirectory: MusicStorage.caches.appendingPathComponent("LyricTranslations", isDirectory: true))
        var bridge: AnyObject?
        #if canImport(Translation)
        if #available(macOS 15.0, iOS 18.0, *), MusicAppleTranslation.isSupported {
            let b = MusicAppleTranslationBridge()
            translation.connect(b)
            bridge = b
        }
        #endif
        self.translation = translation
        self.translationBridge = bridge
        // Registering only lists what exists; the setup screen switches on the defaults.
        MusicBuiltIns.register(into: registry, library: library)
        // A source added by a later version starts on for an install that has already finished setup.
        registry.adoptNewBuiltIns(setupDone: library.settings.consentDone)
    }

    var needsConsent: Bool { !library.settings.consentDone }

    /// Connects the player to the app: audio ownership, the media keys and Now Playing, lyrics, downloads and scrobbling. Safe to call again (the first
    /// call wins). Wiring alone touches no network: sources are switched on only by the setup screen or the person.
    func attach(ownership: AudioOwnership = .shared, router: MediaCommandRouter = .shared, allowed: Bool = true) {
        // The last composed Listen Now feed is read now, so the first frame of Listen Now already has its shelves.
        Task { await MusicHomeFeedModel.shared.preload() }
        guard !attached else { return }
        attached = true
        MusicExtras.shared.attach(to: self)
        _ = devices          // restores the remote-control host after a relaunch, only if the person left it switched on
        let player = self.player
        // Music is one participant of the audio coordinator: another source taking the audio pauses it.
        ownership.register(ClosureAudioParticipant(.music, isPlaying: { player.isPlaying }, pause: { player.pauseForOtherAudio() }))
        player.onClaimAudio = { [weak ownership] in _ = ownership?.claim(.music, reason: .musicPlay) }
        player.onReleaseAudio = { [weak ownership] in _ = ownership?.release(.music, reason: .stopped) }
        router.register(player, for: .music)
        player.publishNowPlaying = { [weak router] info, playing in _ = router?.publish(info, playing: playing, from: .music) }
        player.onRemoteSupportChanged = { [weak router] in router?.supportChanged(for: .music) }
        player.lyrics = lyrics
        player.downloads = downloads
        let library = self.library
        downloads.qualityProvider = { library.settings.audioQuality }
        downloads.tagsEnabled = { library.settings.tagDownloads }
        downloads.cachedCopy = { [weak player] track in
            player?.audioCache?.cachedFile(key: MusicAudioCache.key(uid: track.uid, quality: library.settings.audioQuality))
        }
        player.registry = registry
        let scrobbler = self.scrobbler
        player.onTrackStarted = { [weak self] track in
            if !MusicPrivateListening.shared.isOn { scrobbler.started(track) }
            MusicGraphIngest.shared.ingest(track: track)    // read-only observation for the graph; playback never waits for it
            self?.publishNowPlayingArtwork(for: track)
            if let hub = self { hub.lyrics.trackStarted(track, queue: hub.player.queue, metered: MusicMotionLink.shared.isMetered) }
        }
        // A translation or romanisation belongs to one song: it resets when the current song changes, before any view asks for extras, never at audio start (that would wipe what the lyrics view just requested).
        player.onCurrentChanged = { [weak self] track, _ in
            guard let self, self.translationUID != track?.uid else { return }
            self.translationUID = track?.uid
            self.translation.reset()
        }
        // Smart shuffle reads the Automix analysis (read-only) for how energetic a song is; autoplay is held while Music is gated (Kids profile or lock).
        let analysis = player.automix.cache
        player.shuffleEnergy = { t in
            guard t.durationMs > 0, let a = analysis.analysis(trackUID: t.uid, duration: Double(t.durationMs) / 1000), !a.failed else { return nil }
            let mean = a.energy.isEmpty ? nil : Double(a.energy.reduce(0, +)) / Double(a.energy.count)
            return MusicShuffleEngine.energy(bpm: a.bpm, meanEnergy: mean)
        }
        player.autoplayAllow = { [gate = MusicGateFlag.shared] _ in !gate.isGated }
        player.onTrackFinished = { track, playedMs in if !MusicPrivateListening.shared.isOn { scrobbler.finished(track, playedMs: playedMs) }; Task { await MusicRecommenderRuntime.shared.historyChanged() } }
        scrobbler.bind(to: player)
        RadioService.shared.attach(hub: self)
        MusicStats.shared.attach(to: player)
        LocalMediaFolders.shared.startup()
        MusicPerfProbe.shared.start()
        MusicStorageGuard.shared.start { [weak player] in player?.audioCache }
        player.startOutputWatch()
        MusicStats.shared.importHistory(library.history)
        MusicGlobalSearch.install(registry: registry, library: library)
        _ = MusicChartBinding.resolver(for: self)    // the chart pipeline follows this hub's lock, Never play list and network rules
        lyrics.apply(settings: library.settings)
        observeSettingsForLyrics()
        syncRoomFlags()
        // The account layer needs the provider built with the shared session; registering it again replaces the guest one by id.
        let yt = YouTubeMusicFullProvider(session: YouTubeMusicAccountBuiltIns.session)
        registry.register(yt)
        MusicLyricsBuiltIns.connectYouTube(yt)
        YouTubeMusicAccountBuiltIns.attach(provider: yt)
        YouTubeMusicAccountBuiltIns.registerHistory(into: registry)
        attachKaraoke()
        attachNetwork()
        MusicEntityRuntime.shared.installMetadata(hub: self)
        MusicImportScheduler.shared.start(hub: self)
        MusicDesktopIntegration.shared.attach(hub: self)
        // Attaching while the app is locked or a Kids profile is on wires everything but leaves it all held.
        if !allowed { shutDown() }
    }

    /// Karaoke finds a song's audio through the same resolver the player uses, so it fetches nothing the player could not.
    private func attachKaraoke() {
        let center = MusicKaraokeCenter.shared
        player.karaoke = center
        let resolver = self.resolver
        let located = MusicKaraokeLocatedStreams()
        let locate: @Sendable (MusicTrack) async throws -> MusicKaraokeAudioLocation = { [weak self] track in
            guard let self else { throw MusicError.cancelled }
            let held = await self.gated
            if held { throw MusicError.cancelled }
            let stream = try await resolver.resolve(track, quality: .high)
            guard let url = URL(string: stream.url) else { throw MusicError.noPlayableSource(track.title) }
            located.set(stream, for: track.uid)
            return MusicKaraokeAudioLocation(url: url, headers: stream.headers, isDownloadable: stream.proto == .progressive)
        }
        // A fetch that fails drops the address that was tried, so the next attempt asks for a fresh one.
        center.attach(fetcher: MusicKaraokeEvictingFetcher(base: MusicKaraokeStreamFetcher(locate: locate), located: located) { track, stream in
            await MainActor.run { resolver.evict(track, stream: stream) }
        })
    }

    /// The player follows the app's network watch instead of keeping a monitor of its own.
    private func attachNetwork() {
        let watch = MusicNetwork.watch
        player.isOnline = { watch.isOnline }
        watch.onChange = { [weak self] _, new in
            MusicEnrichmentFlags.shared.setOffline(new == .none)
            self?.player.networkChanged(online: new != .none)
            self?.networkRevision &+= 1
        }
    }

    private func publishNowPlayingArtwork(for track: MusicTrack) {
        let player = self.player
        Task { @MainActor in
            let art = await MusicArtworkService.shared.nowPlayingArtwork(for: track.thumbnails)
            player.setNowPlayingArtwork(art, forTrack: track.uid)
        }
    }

    /// Lyrics follow the settings: applied now and again after every change.
    private func observeSettingsForLyrics() {
        withObservationTracking { _ = library.settings } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.lyrics.apply(settings: self.library.settings)
                self.observeSettingsForLyrics()
            }
        }
    }

    /// Keeps the player's room flags in step with the listening room: any role is "in a room", only a guest cannot edit the queue.
    private func syncRoomFlags() {
        withObservationTracking {
            player.inRoom = room.role != .none
            player.isRoomGuest = room.role == .guest
        } onChange: { [weak self] in
            Task { @MainActor in self?.syncRoomFlags() }
        }
    }

    /// Deletes everything Music keeps on this device: library, downloads, stats, covers, match choices, added sources and every cache. Sign-ins and
    /// source choices stay. The app's own "remove everything" calls this too.
    func wipeAll() async {
        for item in downloads.items { downloads.remove(item.id) }
        library.clearAll(keepSettings: true)
        MusicRecentlyAddedVisit.forget()
        MusicNativeNames.shared.reset()
        MusicExploreSeeAll.shared.section = nil
        matchOverrides.resetAll()
        player.audioCache?.clear()
        MusicStats.shared.clear()
        MusicPlaybackLog.shared.clear()
        MusicCatalogRuntime.shared.wipe()
        MusicGenreArtwork.shared.wipe()
        MusicEntityArtwork.shared.clear()
        MusicExploreMemory.forget(); MusicTrendingModel.forget()
        MusicRadioRecents.wipe(defaults); MusicRadioNow.shared.clear(); RadioService.shared.wipe()
        MusicHiddenRecommendations.shared.clear()   // what was hidden from recommendations is part of what the wipe forgets
        MusicHomeFeedModel.shared.clearAll(); MusicHomeDisk.removeAll(); Task { await MusicSuggestFeed.forget(); await MusicPageCache.shared.wipe(); await MusicSearchCache.chunks.clear() }; MusicEntityWarmer.shared.forget()
        AddonStore.shared.removeAll()
        MusicKaraokeCenter.shared.clearCache()
        MusicFilmCache.shared.wipe()
        await MusicPersonWikiInfoLoader.shared.wipe(); await MusicPersonFactsLoader.shared.wipe(); await MusicPersonAwardsLoader.shared.wipe()   // the people the person opened
        await MusicGraphRuntime.shared.wipe()
        MusicEntityRuntime.shared.wipe(); MusicPageMemoryCenter.shared.clear()
        translation.clearCache()
        lyrics.clearCache()
        await MusicArtworkService.shared.clear()
        let loudness = player.loudness
        await loudness?.forgetAll()
        MusicDefaultsKeys.wipeActivity(defaults)
        MusicTastePreferences.shared.update { $0 = MusicTastePrefs() }   // the picks live in memory too
        MusicFavoriteArtists.shared.reset()
    }

    /// Stops everything that talks or plays: the remote-control host, the listening room, scrobbling, karaoke work and addon traffic, then playback.
    /// The app locked, a Kids profile began, or Music became unavailable. `resumeAfterGate()` undoes it when Music is allowed again.
    func shutDown() {
        gated = true
        MusicGateFlag.shared.isGated = true
        room.shutDown()
        devices.host.stop()
        scrobbler.isAllowed = false
        resolver.chain?.isAllowed = false
        plugins.isAllowed = false
        MusicKaraokeCenter.shared.shutDown()
        MusicImportScheduler.shared.stop()
        player.blocked = true
        player.stop()
    }

    /// Music is allowed again: the pieces that were held come back. The remote-control host returns only if the person left it switched on.
    func resumeAfterGate() {
        guard gated else { return }
        gated = false
        MusicGateFlag.shared.isGated = false
        scrobbler.isAllowed = true
        resolver.chain?.isAllowed = true
        plugins.isAllowed = true
        player.blocked = false
        devices.restore()
        if attached { MusicImportScheduler.shared.start(hub: self) }
    }

    /// Ends first-run consent with exactly the providers the person ticked (none for "local library only").
    func completeConsent(enabling ids: Set<String>) {
        for p in registry.all { registry.setEnabled(ids.contains(p.id), id: p.id, reason: .setup) }
        // With every source on, the first one registered would become the browsing source; the full YouTube Music provider leads instead.
        if ids.contains(MusicSetupPresets.youTubeMusicID) { registry.setActiveMetadata(MusicSetupPresets.youTubeMusicID) }
        library.settings.consentDone = true
        registry.recordKnownBuiltIns()
        attach()
    }

    /// Re-runs the consent screen from Settings.
    func reopenConsent() { library.settings.consentDone = false }

    /// Set when a pasted or shared link could not be opened; the main view may show it.
    var linkError: String?
    /// Targets whose graph entity is being found right now: a repeat tap on the same one does nothing, a tap on another one still opens it.
    @ObservationIgnored private var openingKeys: Set<String> = []

    /// Opens a page. An artist, album or actor given as a provider value is pushed at once and `MusicProviderEntityPage` finds or saves its graph entity, so
    /// there is one album page and one person page (a provider page no longer exists; a value the graph cannot save shows a "not available" state with Try again).
    /// `music.graph.pages` only decides whether a typed name is resolved first (`nameSearch`). `nameSearch` is the typed name when the artist came from a name search:
    /// the person page then shows its "Did you mean" row.
    func open(_ r: MusicRoute, nameSearch: String? = nil) {
        // An album with no provider id has no page: every id-less album would resolve to the one shared "provider:" entity (another album's page).
        if case .album(let a) = r, !(!a.id.isEmpty && a.id != a.title) { MusicToasts.shared.show(Localized.string("This album has no page.")); return }
        // A page opened from the full-window player must be seen: the player steps aside (it never stops the music).
        if expandedPlayer { expandedPlayer = false }
        // Opening is instant: the page is pushed at once and finds (or saves) its graph entity while it draws its first frame (MusicProviderEntityPage), so a
        // tap never waits on the database. Only a name search needs the entity first, to remember what was typed.
        guard graphPagesOn, Self.graphLookup(r) != nil, nameSearch != nil else { nav.push(r); return }
        // A second tap while the first is still finding the entity does nothing (it would push the same page twice).
        var key = "route:" + r.scrollKey
        if case .artist(let a) = r, a.id.isEmpty { key += ":" + a.name }
        guard openingKeys.insert(key).inserted else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.openingKeys.remove(key) }
            let id = await self.entityID(for: r)
            if let q = nameSearch?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty, case .artist = r, let id {
                MusicPageMemoryCenter.shared.update(MusicRoute.person(id, role: nil).scrollKey) { $0.filters["nameSearch"] = q }
            }
            if let id { Self.forgetRememberedRole(id, role: Self.startingRole(r)) }
            self.nav.push(id.map { .entity($0, role: Self.startingRole(r)) } ?? r)
        }
    }

    /// The graph entity a provider value stands for: the one the graph already has, or (when it has none yet) the row saved right now from what the
    /// provider gave, so every album, artist and actor opens the same full page and none falls back to a bare one. Nil only when the graph cannot be written.
    func entityID(for r: MusicRoute) async -> MusicEntityID? {
        guard let (kinds, uid) = Self.graphLookup(r) else { return nil }
        // A provider artist with no id of its own (plain text credit) is told apart by name: "provider:" would be one shared identity for all of them.
        if case .artist(let a) = r, a.id.isEmpty {
            if let hits = try? await MusicGraphRuntime.shared.store.search(a.name, kinds: [.person, .group], limit: 5) {
                let want = MusicText.normalize(a.name)
                if let hit = hits.first(where: { MusicText.normalize($0.name) == want }) { return hit.id }
            }
            guard let draft = Self.seedDraft(r) else { return nil }
            return try? await MusicGraphRuntime.shared.store.upsert([draft]).first?.id
        }
        for k in kinds { if let id = try? await MusicGraphRuntime.shared.index.lookup(providerUID: uid, kind: k) { return id } }
        // An actor comes with a name only: the person the graph already holds under that name (never a second, empty one) is the page.
        if case .actor(let a) = r, let hits = try? await MusicGraphRuntime.shared.store.search(a.person.name, kinds: [.person], limit: 5) {
            let want = MusicText.normalize(a.person.name)
            if let hit = hits.first(where: { MusicText.normalize($0.name) == want }) { return hit.id }
        }
        guard let draft = Self.seedDraft(r) else { return nil }
        return try? await MusicGraphRuntime.shared.store.upsert([draft]).first?.id
    }

    private static func startingRole(_ r: MusicRoute) -> MusicRole? { if case .actor = r { .actor } else { nil } }

    private static func seedDraft(_ r: MusicRoute) -> MusicEntityDraft? {
        switch r {
        case .artist(let a): return MusicGraphAdapters.artistDraft(a)
        case .album(let a): return MusicGraphAdapters.albumDraft(a)
        case .actor(let a): return MusicEntityDraft(kind: .person, name: a.person.name, subkind: "actor", lang: a.language, provisional: true)
        case .playlist: return nil   // playlists keep their own page
        default: return nil
        }
    }

    private static func graphLookup(_ r: MusicRoute) -> ([MusicEntityKind], String)? {
        switch r {
        case .artist(let a): return ([.person, .group], a.uid)
        case .album(let a): return ([.release, .album], a.uid)
        case .actor(let a): return ([.person], "actor:" + MusicText.normalize(a.person.name))
        case .playlist(let p): return ([.playlist], p.uid)
        default: return nil
        }
    }

    /// Opens an entity page by id (a stable id, or a provisional one made from a provider uid with no database read). Navigation never touches the
    /// player: nothing here starts, stops or changes what is playing.
    func open(_ id: MusicEntityID, role: MusicRole? = nil) {
        MusicDebugLog.log("nav", "open entity \(id.rawValue)")
        if expandedPlayer { expandedPlayer = false }
        Self.forgetRememberedRole(id, role: role)
        nav.push(.entity(id, role: role))
    }

    /// A link that names a role opens that role: the role the person switched to on an earlier visit of the same page belongs to Back and Forward, not to a fresh link.
    static func forgetRememberedRole(_ id: MusicEntityID, role: MusicRole?) {
        guard role != nil else { return }
        MusicPageMemoryCenter.shared.update(MusicRoute.person(id, role: role).scrollKey) { $0.filters["role"] = nil }
    }

    /// Opens a provider artist on the role the link is about (a singer credit opens the singer view, a composer credit the composer view), once the graph has
    /// (or has saved) the person; with no entity yet it opens the plain provider page.
    func openArtist(_ a: MusicArtist, role: MusicRole) {
        let key = "artist:\(a.providerID):\(a.id):\(a.id.isEmpty ? a.name : ""):\(role.rawValue)"
        guard openingKeys.insert(key).inserted else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.openingKeys.remove(key) }
            if graphPagesOn, let id = await entityID(for: .artist(a)) { open(id, role: role) } else { open(.artist(a)) }
        }
    }
    func open(collection: MusicCollectionKey) { if expandedPlayer { expandedPlayer = false }; nav.push(.collection(collection)) }
    /// Provider values: every one opens the connected entity page (found or saved on open).
    func open(album: MusicAlbum) { open(.album(album)) }
    func open(artist: MusicArtist, nameSearch: String? = nil) { open(.artist(artist), nameSearch: nameSearch) }
    func open(playlist: MusicPlaylist) { open(.playlist(playlist)) }
    /// The connected pages are on unless the person turned them off.
    private var graphPagesOn: Bool { (defaults.object(forKey: MusicGraphKeys.pages) as? Bool) ?? true }

    /// Opens what a shared or pasted link points at. It only asks a source the person switched on, and it never starts playing.
    func openLink(_ t: MusicLinkTarget) async {
        do {
            switch try await MusicDeepLinks.resolve(t, registry: registry) {
            case .route(let r): open(r)
            case .track(_, let route): if let route { open(route) }
            case .section(let s): nav.select(s)
            }
        } catch { linkError = loadError(error) }
    }

    /// Opens the sheet that lists other recordings for a song.
    func chooseAudioSource(for t: MusicTrack) { alternativesTrack = t }

    /// Remembers the recording for the song and, when it is playing now, restarts it from that recording.
    func useAudioSource(_ s: MusicAudioSource, for t: MusicTrack) {
        matchOverrides.choose(s, for: t)
        refreshAfterOverrideChange(t)
    }

    func resetAudioSource(for t: MusicTrack) {
        matchOverrides.reset(for: t)
        refreshAfterOverrideChange(t)
    }

    private func refreshAfterOverrideChange(_ t: MusicTrack) {
        resolver.forgive(t)
        if player.current?.uid == t.uid { player.retryCurrent() }
    }
    func back() { nav.back() }

    /// Opens Your Library the one way every entry point does: a standalone page left by the sidebar's Songs/Albums/Artists is reset to the full library (tab bar and all),
    /// or, with a tab, opens that tab standalone as the sidebar's shortcuts do.
    func openLibrary(tab: MusicLibraryTab? = nil) {
        if let tab { libraryTabRequest = (tab, true) } else { libraryResetToken += 1 }
        nav.select(.library)
    }

    /// Deletes a playlist everywhere the same way: its extras go, a toast confirms, and its page leaves the stack and the history wherever it is (never "Playlist not found").
    func deletePlaylist(_ p: LocalPlaylist) {
        MusicPlaylistExtras.shared.forget(p.id)
        library.delete(p)
        MusicToasts.shared.success(Localized.string("Playlist deleted."))
        MusicShellSession.shared.history.purge { $0 == .localPlaylist(p.id) }
        nav.remove { $0 == .localPlaylist(p.id) }
    }

    /// Drops the pages of playlists that no longer exist from a history (a saved session can name one that was deleted since).
    func forgetMissingPlaylists(in history: inout MusicNavHistory) {
        history.purge { if case .localPlaylist(let id) = $0 { return library.playlist(id: id) == nil }; return false }
    }
    /// False, with the reason said, while a profile's playback is paused or a Listen Together guest follows the host: replacing the queue then would start audio that
    /// is not allowed or fight the room. Every way of starting something new (Play, Shuffle, a radio, a concert's songs) asks this first.
    func canReplaceQueue() -> Bool {
        if gated { MusicToasts.shared.show(Localized.string("Playback is paused for this profile.")); return false }
        if room.controlsLocked { MusicToasts.shared.show(Localized.string("Only the host can change the queue.")); return false }
        return true
    }

    func play(_ tracks: [MusicTrack], at index: Int, sourceName: String? = nil, sourceID: String? = nil) {
        MusicPerfProbe.shared.mark(.playPress, tracks.indices.contains(index) ? tracks[index].title : "queue")
        MusicDebugLog.log("play", "hub.play \(tracks.count) tracks from \(index): \(tracks.indices.contains(index) ? tracks[index].title : "-") (\(tracks.indices.contains(index) ? tracks[index].uid : "-"))")
        guard !tracks.isEmpty else { return }
        guard !gated else { MusicToasts.shared.show(Localized.string("Playback is paused for this profile.")); return }
        // A Listen Together guest follows the host's queue: a Play on any page would replace it and fight the room (the player bar's own controls are locked the same way).
        guard !room.controlsLocked else { MusicToasts.shared.show(Localized.string("Only the host can change the queue.")); return }
        // A song the person starts brings a hidden player bar back.
        MusicBarVisibilityModel.shared.restore()
        player.play(tracks, startAt: min(max(0, index), tracks.count - 1), sourceName: sourceName, sourceID: sourceID)
    }

    /// Shuffle Play for every page: the player's engine orders the list once (see `MusicPlayer.playShuffled`). Pages never shuffle a list themselves.
    func playShuffled(_ tracks: [MusicTrack], sourceName: String? = nil, sourceID: String? = nil) {
        guard !tracks.isEmpty else { return }
        guard !gated else { MusicToasts.shared.show(Localized.string("Playback is paused for this profile.")); return }
        guard !room.controlsLocked else { MusicToasts.shared.show(Localized.string("Only the host can change the queue.")); return }
        MusicBarVisibilityModel.shared.restore()
        player.playShuffled(tracks, sourceName: sourceName, sourceID: sourceID)
    }

    func loadError(_ e: Error) -> String { Self.friendlyMessage(e) }

    nonisolated static func friendlyMessage(_ e: Error) -> String {
        if let m = e as? MusicError {
            switch m {
            case .network: return Localized.string("Could not reach the music service. Check your connection and try again.")
            case .unsupported: return Localized.string("This music source does not offer that.")
            default: return m.errorDescription ?? Localized.string("Something went wrong.")
            }
        }
        if e is CancellationError { return Localized.string("Cancelled.") }
        return Localized.string("Something went wrong. Try again in a moment.")
    }

    func artist(from ref: MusicArtistRef, providerID: String) -> MusicArtist {
        MusicArtist(id: ref.id, providerID: providerID, name: ref.name, thumbnails: ref.thumbnails, externalURL: ref.externalURL)
    }
    func album(from ref: MusicAlbumRef, providerID: String) -> MusicAlbum {
        MusicAlbum(id: ref.id, providerID: providerID, title: ref.title, artists: ref.artists, thumbnails: ref.thumbnails,
                   releaseDate: ref.releaseDate, totalTracks: ref.totalTracks, albumType: ref.albumType, externalURL: ref.externalURL)
    }
    func providerName(_ id: String) -> String { registry.provider(id: id)?.info.name ?? id }
}

/// Thread-safe mirror of `MusicHub.gated`, for code that runs off the main actor (autoplay asks it before it adds a song).
final class MusicGateFlag: @unchecked Sendable {
    static let shared = MusicGateFlag()
    private let lock = NSLock()
    private var value = false
    var isGated: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}
