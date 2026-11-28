import Foundation
import SwiftUI
@testable import REDDY

// The scenario list. Shell scenarios draw the same regions as the app's Music shell (sidebar, header, page, context panel, player bar) from the
// real components, but on a private context-panel state and without the app's global hooks (menu bar item, key monitor, audio ownership), so a
// render never touches the running app.

enum MusicSnapshotSizes {
    static let all: [CGSize] = [
        CGSize(width: 640, height: 720), CGSize(width: 760, height: 640), CGSize(width: 900, height: 700), CGSize(width: 1100, height: 760),
        CGSize(width: 1400, height: 860), CGSize(width: 1700, height: 1000), CGSize(width: 2000, height: 1200),
    ]
    static let stress = CGSize(width: 1100, height: 760)
    /// The settings overlay sizes: the narrowest and shortest it may be resized to, up to the widest.
    static let settingsOverlay: [CGSize] = [CGSize(width: 520, height: 480), CGSize(width: 640, height: 560), CGSize(width: 760, height: 700), CGSize(width: 900, height: 900)]
    static let barHeight: CGFloat = 140
    /// The bottom strip of a shell render that holds the player bar (the bar is 76 pt; a little room for the check).
    static let barStrip: CGFloat = 84
    /// A render slower than this is flagged in the report (not a failure).
    static let renderBudgetSeconds = 1.5
    static func label(_ s: CGSize) -> String { "\(Int(s.width))x\(Int(s.height))" }
}

enum MusicSnapshotCase: String, CaseIterable, Sendable {
    case listenNow = "listen-now"
    case searchResults = "search-results"
    case libraryLiked = "library-liked"
    case libraryPlaylists = "library-playlists"
    case libraryArtists = "library-artists"
    case libraryAlbums = "library-albums"
    case libraryHistory = "library-history"
    case libraryEmpty = "library-empty"
    case roomIdle = "room-idle"
    case homeLanguage = "home-language"
    case chartHiddenRows = "chart-hidden-rows"
    case entityScaffold = "entity-scaffold"
    case settingsMetadata = "settings-metadata"
    case albumPage = "album-page"
    case artistPage = "artist-page"
    case playlistPage = "playlist-page"
    case localPlaylistPage = "local-playlist-page"
    case shellQueue = "shell-queue"
    case shellLyrics = "shell-lyrics"
    case playerBar = "player-bar"
    case settings = "settings"
    // The settings overlay alone (no shell) at overlay sizes, one scenario per tab.
    case settingsGeneral = "settings-general"
    case settingsPlayback = "settings-playback"
    case settingsLyrics = "settings-lyrics"
    case settingsPlugins = "settings-plugins"
    case settingsData = "settings-data"
    case settingsPrivacy = "settings-privacy"
    // Settings stress: the largest text step, and right to left.
    case stressSettingsText3 = "stress-settings-text3"
    case stressSettingsRTL = "stress-settings-rtl"
    case explore = "explore"
    case radio = "radio"
    case genrePage = "genre-page"
    case devices = "devices"
    case downloads = "downloads"
    case importPage = "import"
    case neverPlay = "never-play"
    case lyricsMiss = "lyrics-miss"
    case lyricsFound = "lyrics-found"
    case nowPlayingPanel = "now-playing-panel"
    /// The Now Playing tab alone at the narrowest and widest panel widths, with the lyrics preview under the controls.
    case nowPlayingPanelLyrics = "now-playing-panel-lyrics"
    /// The Related tab alone at the narrowest and widest panel widths: artist, album, more from the artist, similar artists and related songs.
    case relatedPanel = "related-panel"
    /// The bar hidden: the restore pill in the corner and the Now Playing card in the sidebar.
    case barHidden = "bar-hidden"
    /// The 3 pt line the bar collapses to while the Now Playing panel sits beside the page (wide windows only).
    case barCollapsed = "bar-collapsed"
    // The connected-universe pages, drawn from the recorded Awaara (1951) fixture graph.
    case soundtrackPage = "graph-soundtrack-page"
    case songPage = "graph-song-page"
    case personRajKapoor = "graph-person-raj-kapoor"
    case personMukesh = "graph-person-mukesh"
    case personShankarJaikishan = "graph-person-shankar-jaikishan"
    case filmPage = "graph-film-page"
    /// The Credits tab of the context panel beside the page, and alone at the narrowest and widest panel widths.
    case creditsTab = "graph-credits-tab"
    case creditsPanel = "graph-credits-panel"
    // Screens filled from the graph: Home with connected shelves, the Explore hub, Search with a best match and chips, a director with a full filmography.
    case graphHome = "graph-home"
    case graphExplore = "graph-explore"
    /// The connected shelves block of Home on its own (the full Home runs below the window).
    case graphHomeShelves = "graph-home-shelves"
    case graphSearch = "graph-search"
    case personDirector = "graph-person-director"
    // Charts, regional titles, autoplay and shuffle.
    case chartVersions = "chart-versions"
    case exploreIndia = "explore-india"
    case queueAutoplay = "queue-autoplay"
    case shuffleMenu = "shuffle-menu"
    case settingsShuffleAutoplay = "settings-shuffle-autoplay"
    // Stress set at 1100x760.
    case stressTextPlus3 = "stress-text-plus3"
    case stressRTL = "stress-rtl"
    case stressReduceTransparency = "stress-reduce-transparency"
    case stressIncreaseContrast = "stress-increase-contrast"
    case stressLongTitles = "stress-long-titles"

    static var responsive: [MusicSnapshotCase] { allCases.filter { !$0.rawValue.hasPrefix("stress-") } }
    static var stress: [MusicSnapshotCase] { allCases.filter { $0.rawValue.hasPrefix("stress-") } }
}

@MainActor
extension MusicSnapshotCase {
    var isStress: Bool { rawValue.hasPrefix("stress-") }
    var isBarOnly: Bool { self == .playerBar }
    var barIsAbsent: Bool { self == .barHidden || isSettingsOverlay }
    /// The settings overlay drawn alone at overlay widths (520 to 900), not inside the shell.
    var isSettingsOverlay: Bool { rawValue.hasPrefix("settings-") || rawValue.hasPrefix("stress-settings-") }
    var settingsTab: MusicSettingsTab {
        switch self {
        case .settingsPlayback, .settingsShuffleAutoplay: .playback
        case .settingsLyrics: .lyrics
        case .settingsPlugins, .stressSettingsText3: .plugins
        case .settingsData: .data
        case .settingsPrivacy, .stressSettingsRTL: .privacy
        default: .general
        }
    }
    var isPanelOnly: Bool { self == .nowPlayingPanelLyrics || self == .relatedPanel || self == .creditsPanel }
    /// A page drawn from the fixture graph: the graph is seeded before the first render.
    var isGraphScenario: Bool { rawValue.hasPrefix("graph-") }
    /// The widths the connected pages are checked at.
    static let graphWidths: Set<CGFloat> = [640, 900, 1100, 1400, 1700]
    var sizes: [CGSize] {
        if isGraphScenario && !isPanelOnly { return MusicSnapshotSizes.all.filter { Self.graphWidths.contains($0.width) } }
        if isSettingsOverlay { return MusicSnapshotSizes.settingsOverlay }
        if isStress { return [MusicSnapshotSizes.stress] }
        if isPanelOnly { return [CGSize(width: 300, height: 860), CGSize(width: 380, height: 860)] }
        return MusicSnapshotSizes.all
    }
    /// Pages that load from the sample catalogue need longer to settle.
    var settle: TimeInterval {
        if isBarOnly { return 0.3 }
        let slow: Set<MusicSnapshotCase> = [.lyricsFound, .lyricsMiss, .chartHiddenRows, .chartVersions, .entityScaffold, .nowPlayingPanel, .nowPlayingPanelLyrics, .relatedPanel, .exploreIndia]
        return slow.contains(self) || isGraphScenario ? 2.5 : 0.8
    }

    var environment: MusicSnapshotEnvironment {
        var e = MusicSnapshotEnvironment()
        switch self {
        case .stressTextPlus3, .stressSettingsText3: e.textStep = .largest
        case .stressSettingsRTL: e.rightToLeft = true
        case .stressRTL: e.rightToLeft = true; e.accentName = "teal"
        case .stressReduceTransparency: e.reduceTransparency = true; e.theme = .liquidGlass
        case .stressIncreaseContrast: e.increaseContrast = true
        case .stressLongTitles: e.textStep = .large
        default: break
        }
        return e
    }

    var section: MusicSection {
        switch self {
        case .searchResults: .search
        case .libraryLiked, .libraryPlaylists, .libraryArtists, .libraryAlbums, .libraryHistory, .libraryEmpty, .localPlaylistPage, .stressLongTitles: .library
        case .settings: .settings
        case .explore, .genrePage, .exploreIndia, .graphExplore: .explore
        case .graphSearch: .search
        case .radio: .radio
        case .roomIdle: .room
        case .devices: .devices
        case .downloads: .downloads
        default: .home
        }
    }

    var panelTab: MusicContextPanelTab? {
        switch self {
        case .shellQueue, .queueAutoplay, .stressReduceTransparency, .stressLongTitles: .queue
        case .shellLyrics, .lyricsMiss, .lyricsFound: .lyrics
        case .nowPlayingPanel, .nowPlayingPanelLyrics, .barCollapsed: .nowPlaying
        case .relatedPanel: .related
        case .creditsTab, .creditsPanel: .credits
        default: nil
        }
    }

    /// Puts the hub where the scenario starts.
    func prepare(_ world: MusicSnapshotWorld) {
        let hub = world.hub
        hub.nav.select(section)
        if self == .barHidden { MusicBarVisibilityModel.shared.hide() } else { MusicBarVisibilityModel.shared.restore() }
        switch self {
        case .genrePage: hub.open(.genre(world.data.genres[0]))
        case .libraryEmpty: hub.library.clearAll(keepSettings: true)
        case .homeLanguage: break          // Listen Now has no language row any more: this scenario shows the plain page
        case .entityScaffold: hub.open(.entity(MusicEntityID.provisional(kind: .person, name: "Aria Lowell")))
        case .neverPlay: hub.open(.blacklist)
        case .lyricsMiss: world.hub.registry.register(MusicSnapshotLyricsSource(found: false)); world.hub.registry.setEnabled(true, id: MusicSnapshotLyricsSource.id, reason: .setup)
        case .lyricsFound, .nowPlayingPanel, .nowPlayingPanelLyrics: world.hub.registry.register(MusicSnapshotLyricsSource(found: true)); world.hub.registry.setEnabled(true, id: MusicSnapshotLyricsSource.id, reason: .setup)
        case .exploreIndia:
            UserDefaults.standard.set("IN", forKey: MusicDiscoveryRegion.defaultsKey)
            let regional = MusicSnapshotCatalogue(data: world.data, id: "discover-itunes-charts", name: "Apple charts", scope: .regional("in"))
            let global = MusicSnapshotCatalogue(data: world.data, id: "discover-audius-trending", name: "Worldwide chart", scope: .global)
            for p in [regional, global] { hub.registry.register(p); hub.registry.setEnabled(true, id: p.info.id, reason: .setup) }
        case .queueAutoplay:
            #if DEBUG
            hub.player.installSnapshotState(queue: Array(world.data.tracks.prefix(8)), startAt: 2, playing: true, position: 83, duration: 215,
                                            autoplay: Array(world.data.tracks.dropFirst(8).prefix(6)))
            #endif
        default: break
        }
        switch self {
        case .soundtrackPage, .songPage, .personRajKapoor, .personMukesh, .personShankarJaikishan, .filmPage, .creditsTab, .creditsPanel:
            if let route = MusicSnapshotGraph.route(for: self) { hub.open(route) }
        case .personDirector: if let route = MusicSnapshotGraph.route(for: self) { hub.open(route) }
        case .graphSearch:
            hub.searchModel.query = "Raj Kapoor"
            hub.searchModel.submit()
        case .albumPage: hub.open(.album(world.data.albums[0]))
        case .artistPage: hub.open(.artist(world.data.artists[0]))
        case .playlistPage: hub.open(.playlist(world.data.playlists[0]))
        case .localPlaylistPage: hub.open(.localPlaylist(world.localPlaylistID))
        case .searchResults:
            hub.searchModel.query = "night"
            hub.searchModel.submit()
        default: break
        }
    }

    @ViewBuilder func page(_ world: MusicSnapshotWorld) -> some View {
        let hub = world.hub
        if let route = hub.nav.top { MusicRouteView(hub: hub, route: route) }
        else {
            switch self {
            case .searchResults, .graphSearch: MusicSearchPage(hub: hub)
            case .graphExplore: MusicExploreView(hub: hub)
            case .graphHomeShelves: MusicPageScaffold(hub: hub) { MusicConnectedHomeBlock(hub: hub, model: MusicHomeFeedModel.shared) }
            case .libraryLiked, .stressLongTitles: MusicLibraryPage(hub: hub, initialTab: .liked)
            case .libraryPlaylists: MusicLibraryPage(hub: hub, initialTab: .playlists)
            case .libraryArtists: MusicLibraryPage(hub: hub, initialTab: .artists)
            case .libraryAlbums: MusicLibraryPage(hub: hub, initialTab: .albums)
            case .libraryHistory: MusicLibraryPage(hub: hub, initialTab: .history)
            case .libraryEmpty: MusicLibraryPage(hub: hub, initialTab: .songs)
            case .roomIdle: MusicRoomPage(hub: hub)
            case .chartHiddenRows: MusicSnapshotChartPage(hub: hub, tracks: world.data.tracks)
            case .chartVersions: MusicSnapshotChartPage(hub: hub, tracks: Self.withVersions(world.data.tracks))
            case .shuffleMenu:
                VStack(alignment: .leading, spacing: MusicSpace.sm) { MusicShuffleMenuContent(hub: hub) }
                    .padding(MusicSpace.lg).frame(maxWidth: 360, maxHeight: .infinity, alignment: .topLeading)
            case .settings: MusicSettingsPage(hub: hub)
            case .explore, .exploreIndia: MusicExploreView(hub: hub)
            case .radio: MusicRadioView(hub: hub)
            case .devices: MusicDevicesPage(hub: hub)
            case .downloads: MusicDownloadsPage(hub: hub)
            case .importPage: MusicImportPage(hub: hub, job: SpotifyImportJob.shared)
            default: MusicHomePage(hub: hub)
            }
        }
    }

    /// The first rows, each with the same song listed again as a lyric video and an official video, the way a chart playlist lists copies of one song.
    static func withVersions(_ tracks: [MusicTrack]) -> [MusicTrack] {
        var out: [MusicTrack] = []
        for (i, t) in tracks.prefix(8).enumerated() {
            out.append(t)
            if i % 2 == 0 {
                for suffix in ["(Official Video)", "(Lyric Video)"] { var v = t; v.id = t.id + "-v" + suffix.prefix(4); v.title = t.title + " " + suffix; out.append(v) }
            }
        }
        return out
    }

    /// The whole picture for a size.
    func view(_ world: MusicSnapshotWorld, size: CGSize) -> AnyView {
        if self == .settingsMetadata {
            return AnyView(ScrollView { MusicMetadataSettingsSection(hub: world.hub).padding(MusicSpace.md) }
                .frame(width: size.width, height: size.height).background(ColorTokens.background))
        }
        if isSettingsOverlay {
            return AnyView(MusicSettingsPage(hub: world.hub, route: MusicSettingsRoute(tab: settingsTab))
                .frame(width: size.width, height: size.height).background(ColorTokens.background))
        }
        if isBarOnly {
            let cls = MusicLayoutClass.resolve(width: size.width)
            return AnyView(VStack(spacing: 0) {
                Spacer(minLength: 0)
                MusicPlayerBar(hub: world.hub, layout: cls)
            })
        }
        let panel = MusicContextPanelState(defaults: UserDefaults(suiteName: "music.snapshot.panel.\(UUID().uuidString)") ?? .standard)
        panel.enter(section)
        if let tab = panelTab { panel.show(tab) }
        if isPanelOnly {
            return AnyView(MusicContextPanel(hub: world.hub, state: panel).frame(width: size.width, height: size.height)
                .background(ThemeBackdrop().ignoresSafeArea()))
        }
        return AnyView(MusicSnapshotShell(hub: world.hub, panelState: panel, page: AnyView(page(world))))
    }

    /// Whether the context panel is meant to be open in this scenario (the shell only opens it with a song playing).
    var wantsPanel: Bool { panelTab != nil }
}

/// The shell's regions built from the real components. Mirrors `MusicMainView.shell` (sidebar choice, geometry, overlay or inline panel, bar slot).
struct MusicSnapshotShell: View {
    @Bindable var hub: MusicHub
    var panelState: MusicContextPanelState
    let page: AnyView
    var sidebarExpanded = true

    var body: some View {
        GeometryReader { geo in
            let wanted = panelState.isOpen && hub.player.current != nil
            let g = MusicShellGeometry.resolve(totalWidth: geo.size.width, sidebarExpanded: sidebarExpanded, panelOpen: wanted)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    MusicSidebar(hub: hub, collapsed: !g.navExpanded, canExpand: g.shellClass >= .expanded, width: g.navWidth, toggle: {})
                    VStack(spacing: 0) {
                        MusicHeaderBar(hub: hub, canBack: hub.nav.canGoBack, canForward: false, back: {}, forward: {}, refresh: {},
                                       panelOpen: wanted, showsPanelToggle: hub.player.current != nil, togglePanel: {})
                        page.frame(maxWidth: .infinity, maxHeight: .infinity)
                            .environment(\.musicLayoutClass, g.contentClass)
                    }
                    if g.panelInline { MusicContextPanel(hub: hub, state: panelState).frame(width: g.panelWidth) }
                }
                .overlay(alignment: .trailing) {
                    if wanted && !g.panelInline {
                        ZStack(alignment: .trailing) {
                            MusicTokens.scrim
                            MusicContextPanel(hub: hub, state: panelState, isOverlay: true)
                                .frame(width: min(g.panelWidth, max(0, geo.size.width))).musicElevation(.overlay, cornerRadius: 0)
                        }
                    }
                }
                MusicShellPlayerBarSlot(hub: hub, layout: g.shellClass, panelState: panelState, panelInline: g.panelInline)
            }
        }
        .background(ThemeBackdrop().ignoresSafeArea())
    }
}


/// A chart list in which every third row has no playable copy, so the "songs hidden" note and the rank gaps show.
struct MusicSnapshotChartPage: View {
    let hub: MusicHub
    let tracks: [MusicTrack]
    @State private var session: MusicChartSession?

    var body: some View {
        MusicPageScaffold(hub: hub) {
            MusicPageHeader(title: "Top songs", kind: "Chart") { EmptyView() }
            if let session { MusicChartList(hub: hub, session: session) }
        }
        .onAppear {
            guard session == nil else { return }
            let rows = Array(tracks.prefix(18))
            var deps = MusicChartDependencies()
            deps.twin = { t in
                guard let i = rows.firstIndex(where: { $0.uid == t.uid }), i % 3 != 2 else { return nil }
                var c = MusicCatalogCanon.make(from: t)
                c.twins = [MusicCanonicalTwin(providerID: "youtube-music", sourceID: "v-" + t.id, title: t.title, artist: t.artistLine + " - Topic", album: "Album",
                                              durationMs: t.durationMs, score: 0.9)]
                return c
            }
            let s = MusicChartSession(chartID: "snapshot", tracks: rows, deps: deps, cache: nil, config: MusicChartConfig())
            s.eager = true
            session = s
            s.start()
        }
    }
}
