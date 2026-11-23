import SwiftUI

/// Library: what is yours: favourites, collections, watch history and statistics.
struct MoreView: View {
    var embedded = false
    @Environment(AppState.self) private var state
    @Environment(IOSRouter.self) private var router

    var body: some View {
        OptionalStack(embedded: embedded) {
            List {
                Section {
                    NavigationLink { LibraryRoute.favourites.destination } label: { LibraryRow(symbol: "heart.fill", tint: .pink, title: "Favourites", count: state.favoriteIDs.count) }.atlas("screen.ios.favourites")
                    NavigationLink { LibraryRoute.watchLater.destination } label: { LibraryRow(symbol: "bookmark.fill", tint: .orange, title: "Watch Later", count: state.watchLaterIDs.count) }.atlas("screen.ios.watchLater")
                    NavigationLink { LibraryRoute.collections.destination } label: { LibraryRow(symbol: "square.stack.fill", tint: .indigo, title: "Collections", count: nil) }.atlas("screen.ios.collections")
                    NavigationLink { LibraryRoute.history.destination } label: { LibraryRow(symbol: "clock.arrow.circlepath", tint: .teal, title: "Watch History", count: nil) }.atlas("screen.ios.history")
                    NavigationLink { LibraryRoute.downloads.destination } label: { LibraryRow(symbol: "arrow.down.circle.fill", tint: .blue, title: "Downloads", count: nil) }.atlas("screen.ios.downloads")
                    NavigationLink { LibraryRoute.tonight.destination } label: { LibraryRow(symbol: "moon.stars.fill", tint: .indigo, title: "Tonight", count: nil) }.atlas("screen.ios.tonight")
                    NavigationLink { LibraryRoute.integrations.destination } label: { LibraryRow(symbol: "link.badge.plus", tint: .purple, title: "Trakt, Debrid and AI", count: nil) }.atlas("screen.ios.integrations")
                    NavigationLink { LibraryRoute.onYourDevice.destination } label: { LibraryRow(symbol: "iphone", tint: .teal, title: "On Your Device", count: nil) }.atlas("screen.ios.onYourDevice")
                    NavigationLink { LibraryRoute.files.destination } label: { LibraryRow(symbol: "externaldrive.fill", tint: .gray, title: "Files and Servers", count: nil) }.atlas("screen.ios.filesAndServers")
                }.glossRow()
                Section { NavigationLink { LibraryRoute.statistics.destination } label: { LibraryRow(symbol: "chart.bar.fill", tint: .green, title: "Statistics", count: nil) }.atlas("screen.ios.statistics") }.glossRow()
            }
            .navigationTitle("Library").atlasScreen("screen.ios.tab.library").themed("Library")
            .miniPlayerInset()
            .titleAndPersonDestinations(ownsStack: !embedded)
        }
    }
}

/// Where a row of the Library list goes. A value link, so the destination is built only when it is pushed and the stack owns the path.
enum LibraryRoute: String, Hashable {
    case favourites, watchLater, collections, history, downloads, tonight, integrations, onYourDevice, files, statistics
    @MainActor @ViewBuilder var destination: some View {
        switch self {
        case .favourites: FavouritesView(); case .watchLater: WatchLaterView(); case .collections: CollectionsView(); case .history: HistoryView(); case .downloads: DownloadsView()
        case .tonight: TonightView(); case .integrations: IntegrationsScreen().atlasScreen("screen.ios.integrations"); case .onYourDevice: OnYourDeviceView().atlasScreen("screen.ios.onYourDevice"); case .files: FilesView().atlasScreen("screen.ios.filesAndServers"); case .statistics: StatisticsView()
        }
    }
}

/// One line of the Library list: a coloured icon tile, the name, and how many are in it.
struct LibraryRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let count: Int?
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 36, height: 36).background(tint.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text(title).appFont(16, .medium)
            Spacer()
            if let count, count > 0 { Text("\(count)").appFont(14).foregroundStyle(.secondary) }
        }.padding(.vertical, 4)
    }
}

struct FavouritesView: View {
    @Environment(AppState.self) private var state
    @Environment(\.container) private var container
    @State private var channels: [Channel] = []
    @State private var titles: [LibraryItem] = []
    @State private var sort: TitleSort = .recent
    @State private var editing = false
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if channels.isEmpty, titles.isEmpty, loaded {
                    EmptyState(symbol: "heart", title: "No favourites yet", message: "Tap the heart on a channel, movie or series.").frame(maxWidth: .infinity, minHeight: 360)
                }
                if !channels.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ListHeader(title: "Channels", count: channels.count)
                        ChannelTileGrid(channels: sort.apply(channels), editing: editing,
                                        onPlay: { c in if let container { Play.channel(c, queue: channels, container) } }, onRemove: { unfavourite($0.id, .channel) })
                    }
                }
                if !titles.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ListHeader(title: "Movies and Series", count: titles.count)
                        TitleGrid(items: sort.apply(titles), editing: editing, onRemove: { unfavourite($0.id, $0.kind) })
                    }
                }
            }.padding(16)
        }
        .navigationTitle("Favourites").atlasScreen("screen.ios.favourites").themed("Favourites")
        .editButton($editing, enabled: !channels.isEmpty || !titles.isEmpty)
        .listTools(sort: $sort, canClear: !channels.isEmpty || !titles.isEmpty, clearLabel: "Remove All Favourites", confirmTitle: "Remove all favourites?",
                   confirmMessage: "This removes every channel, movie and series from Favourites. The titles themselves stay in your library.") {
            for c in channels { state.toggleFavorite(c.id, kind: .channel) }
            for t in titles { state.toggleFavorite(t.id, kind: t.kind) }
            channels = []; titles = []; editing = false
        }
        .miniPlayerInset()
        .task(id: state.catalogVersion) { await load() }
    }

    private func unfavourite(_ id: String, _ kind: ContentKind) {
        state.toggleFavorite(id, kind: kind)
        channels.removeAll { $0.id == id }; titles.removeAll { $0.id == id }
        if channels.isEmpty && titles.isEmpty { editing = false }
    }

    private func load() async {
        guard let c = container else { return }
        let (ch, ti) = await Task.detached { () -> ([Channel], [LibraryItem]) in
            let cids = (try? c.favoritesRepo.favoriteIDs(kind: .channel)) ?? []
            var q = ChannelQuery(); q.collapseVariants = false; q.ids = cids
            let chans = cids.isEmpty ? [] : ((try? c.catalog.channels(q)) ?? [])
            let movies = ((try? c.favoritesRepo.favoriteIDs(kind: .movie)) ?? []).compactMap { try? c.catalog.movie(id: $0) }.map { LibraryItem.movie($0) }
            let series = ((try? c.favoritesRepo.favoriteIDs(kind: .series)) ?? []).compactMap { try? c.catalog.seriesItem(id: $0) }.map { LibraryItem.series($0) }
            return (chans, movies + series)
        }.value
        channels = ch; titles = ti; loaded = true
    }
}

struct HistoryView: View {
    @Environment(AppState.self) private var state
    @Environment(\.container) private var container
    @State private var items: [ContinueItem] = []
    @State private var confirmClear = false

    var body: some View {
        List {
            if items.isEmpty { EmptyState(symbol: "clock", title: "Nothing watched yet", message: "Movies and episodes you start appear here with their place saved.").listRowBackground(Color.clear).listRowSeparator(.hidden) }
            ForEach(items) { r in
                Button {
                    guard let c = container else { return }
                    switch r.content { case .movie(let m): Play.movie(m, c); case .episode(let e, let s): Play.episode(e, s, c) }
                } label: {
                    HStack(spacing: 14) {
                        ZStack(alignment: .bottom) {
                            ArtworkImage(url: r.artworkURL, kind: .backdrop, contentMode: .fill, symbol: "play.rectangle").frame(width: 132, height: 74)
                            ProgressStrip(fraction: r.progress.fraction)
                        }.clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .ratingBadge({ switch r.content { case .movie(let m): RatingRule.credible(m.rating); case .episode(_, let s): RatingRule.credible(s.rating) } }(), scale: 0.7)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(r.title).appFont(15, .semibold).lineLimit(2)
                            Text(r.progress.completed ? "Watched" : "\(Int(r.progress.fraction * 100))% watched").appFont(12).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }.buttonStyle(.press)
                .swipeActions { Button(role: .destructive) {
                    do { try container?.historyRepo.clearProgress(itemID: r.id); items.removeAll { $0.id == r.id }; state.catalogVersion += 1 }
                    catch { state.toasts.show("Could not remove it: \(error.localizedDescription)", symbol: "exclamationmark.triangle") }
                } label: { Label("Remove", systemImage: "trash") } }
                .atlas("gesture.ios.swipeHistory")
            }
        }
        .navigationTitle("Watch History").atlasScreen("screen.ios.history").themed("Watch History")
        .safeAreaInset(edge: .top, spacing: 0) {
            if !items.isEmpty {
                Button(role: .destructive) { confirmClear = true } label: { Label("Clear Watch History", systemImage: "trash").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large).padding(.horizontal, 16).padding(.vertical, 8).background(ColorTokens.background)
                    .atlas("control.ios.history.clear")
            }
        }
        .confirmationDialog("Clear watch history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Watch History", role: .destructive) {
                do { try container?.historyRepo.clearHistory(); try container?.historyRepo.clearResumePoints(sourcePrefix: nil); items = [] }
                catch { state.toasts.show("Could not clear the history: \(error.localizedDescription)", symbol: "exclamationmark.triangle") }
                state.catalogVersion += 1
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This removes everything you have watched and the places saved in each title. Favourites and lists are not touched.") }
        .task(id: state.catalogVersion) {
            guard let c = container else { return }
            let source = state.activeSourceID
            items = await Task.detached { (try? c.history.continueWatching(limit: 60, sourceID: source)) ?? [] }.value
        }
    }
}

struct PlaybackSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var confirmMPV = false

    var body: some View {
        @Bindable var s = settings
        Form {
            Section("Buffering") {
                Picker("Mode", selection: $s.bufferingMode) { ForEach(BufferingMode.allCases) { Text($0.rawValue).tag($0) } }.atlas("setting.bufferingMode")
                Text("A larger buffer gives a steadier picture on weak connections, with a little more delay on live channels.").font(.caption).foregroundStyle(.secondary)
            }.glossRow()
            Section("Resuming") {
                Toggle("Resume movies and episodes where I stopped", isOn: $s.resumeAutomatically).atlas("setting.resumeAutomatically")
                Toggle("Play the best version of a film first", isOn: $s.bestVersionFirst).atlas("setting.bestVersionFirst")
                Toggle("Remember my position", isOn: $s.rememberPosition).atlas("setting.rememberPosition")
                Toggle("Play the next episode automatically", isOn: $s.autoPlayNextEpisode).atlas("setting.autoPlayNextEpisode")
            }.glossRow()
            if AppEngineChoice.available {
                Section {
                    Picker("Player", selection: Binding(get: { settings.enginePreference },
                                                        set: { new in if new == .mpv, settings.enginePreference != .mpv { confirmMPV = true } else { settings.enginePreference = new } })) {
                        ForEach(PlaybackEnginePreference.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .atlas("setting.enginePreference")
                    ForEach(AppSettings.ViewingKind.allCases) { kind in
                        Picker("For \(kind.title)", selection: Binding(get: { settings.engineChoice(for: kind) }, set: { settings.setEngineChoice($0, for: kind) })) {
                            Text("Same as above").tag(PlaybackEnginePreference?.none)
                            ForEach(PlaybackEnginePreference.allCases) { Text($0.rawValue).tag(PlaybackEnginePreference?.some($0)) }
                        }
                        .atlas("setting.engineForKind")
                    }
                } header: { Text("Player engine") } footer: {
                    Text("Automatic uses Apple's player for movies, episodes and HLS, and MPV for live TV and for formats Apple's player can't open (MKV, RTSP, AVI). MPV doesn't support Picture in Picture or AirPlay.")
                }.glossRow()
            }
            Section("Picture quality") {
                Picker("Streams with several qualities", selection: $s.videoQuality) { ForEach(VideoQualityPreference.allCases) { Text($0.rawValue).tag($0) } }.atlas("setting.videoQuality")
            }.glossRow()
            Section("Language") {
                TextField("Preferred audio language (e.g. en)", text: $s.preferredAudioLanguage).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Preferred subtitle language (e.g. en)", text: $s.preferredSubtitleLanguage).textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Show subtitles by default", isOn: $s.subtitlesByDefault).atlas("setting.subtitlesByDefault")
                Toggle("Fetch subtitles automatically", isOn: $s.autoSubtitles).atlas("setting.autoSubtitles")
            }.glossRow()
            Section {
                OpenSubtitlesFields()
            } header: { Text("Subtitles online") } footer: { Text("From OpenSubtitles, using your own free account and API key (opensubtitles.com). They stay in the Keychain on this device and are sent only to OpenSubtitles when you ask for subtitles in the player.") }
            .glossRow()
            Section {
                Toggle("Remember settings for each title", isOn: Binding(get: { ItemMemory().enabled }, set: { ItemMemory().enabled = $0 })).atlas("setting.rememberPerTitle")
            } footer: { Text("Audio language, subtitles, speed and timing come back the next time you play the same title or channel.") }
            .glossRow()
            Section("Subtitle style") {
                VStack(alignment: .leading) { Text("Size \(Int(s.subtitleSize))%").font(.subheadline); Slider(value: $s.subtitleSize, in: 60...200, step: 10) }
                VStack(alignment: .leading) { Text("Background \(Int(s.subtitleBackground * 100))%").font(.subheadline); Slider(value: $s.subtitleBackground, in: 0...1) }
                Picker("Colour", selection: $s.subtitleColor) { ForEach(SubtitleColor.allCases) { Text($0.rawValue).tag($0) } }.atlas("setting.subtitleColor")
                Toggle("Outline", isOn: $s.subtitleOutline).atlas("setting.subtitleOutline")
            }.glossRow()
        }
        .navigationTitle("Playback").atlasScreen("screen.ios.settings.playback").themed("Playback")
        .alert("Switch to MPV?", isPresented: $confirmMPV) {
            Button("Use MPV") { settings.enginePreference = .mpv }.atlas("control.ios.playback.useMPV")
            Button("Keep Apple's Player", role: .cancel) {}
        } message: {
            Text("MPV can open movies faster and plays formats Apple's player can't. But with MPV there is no Picture in Picture and no AirPlay, the picture is drawn by the app, which can use more battery, and some titles may behave differently. Live TV already uses MPV. You can switch back here at any time.")
        }
    }
}

struct AboutView: View {
    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    BrandMark().frame(width: 56, height: 56)
                    VStack(alignment: .leading) {
                        Text("StreamSetu").font(.headline)
                        Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.glossRow()
            Section {
                Text("StreamSetu plays playlists and Xtream accounts you add yourself. It includes no channels or content, has no accounts, and keeps everything on this device.").font(.callout)
            }.glossRow()
            Section {
                if DiagnosticsUploader.availableInThisBuild { NavigationLink(value: AboutRoute.feedback) { Label("Send Feedback", systemImage: "envelope") }.atlas("screen.ios.settings.feedback") }
                NavigationLink(value: AboutRoute.crashReports) { Label("Crash Reports", systemImage: "ladybug") }.atlas("screen.ios.settings.crashReports")
            }.glossRow()
            if let t = UserDefaults.standard.dictionary(forKey: DefaultsKey.startupTimings) as? [String: Int], !t.isEmpty {
                Section("Last launch") {
                    ForEach(["library opened", "library read", "ready"], id: \.self) { k in if let ms = t[k] { LabeledContent(k.capitalized, value: String(format: "%.2f s", Double(ms) / 1000)) } }
                }.glossRow()
            }
            Section("Credits") { TMDBAttribution() }.glossRow()
            Section("Legal") {
                ForEach(LegalPage.allCases) { page in
                    NavigationLink(value: AboutRoute.legal(page)) { Text(page.title) }.atlas("control.ios.about.legal")
                }
            }.glossRow()
        }
        .navigationTitle("About").atlasScreen("screen.ios.settings.about").themed("About")
        .navigationDestination(for: AboutRoute.self) { route in
            switch route {
            case .feedback: FeedbackView()
            case .crashReports: CrashReportsView()
            case .legal(let page): LegalView(page: page).navigationTitle(page.title).navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}

enum AboutRoute: Hashable { case feedback, crashReports, legal(LegalPage) }

/// Settings: how the app behaves and looks, and its maintenance.
/// Every page of Settings, once: the iPhone lists them as rows that push, and the iPad shows the same list beside the chosen page.
enum SettingsPage: String, CaseIterable, Identifiable {
    case playback, health, appearance, parental, privacyReport
    case library, artwork, channels, alerts, profiles, icloud, lan, proxy, appDNS, vpn, backup, storage
    case about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .playback: "Playback"; case .health: "Playback Health"; case .appearance: "Appearance"; case .parental: "Parental Controls"; case .privacyReport: "Privacy Report"
        case .library: "Library and Guide"; case .artwork: "Artwork and Details"; case .channels: "Channel Manager"; case .alerts: "Subscriptions and Alerts"; case .profiles: "Profiles"
        case .icloud: "iCloud Sync"; case .lan: "Sync on this network"; case .proxy: "Proxy"; case .appDNS: "App DNS"; case .vpn: "VPN"; case .backup: "Backup and Restore"; case .storage: "Storage and Maintenance"
        case .about: "About"
        }
    }
    var symbol: String {
        switch self {
        case .playback: "play.rectangle"; case .health: "waveform.path.ecg"; case .appearance: "paintpalette"; case .parental: "lock.shield"; case .privacyReport: "hand.raised"
        case .library: "books.vertical"; case .artwork: "photo.on.rectangle.angled"; case .channels: "slider.horizontal.3"; case .alerts: "bell.badge"; case .profiles: "person.2"
        case .icloud: "icloud"; case .lan: "wifi"; case .proxy: "network"; case .appDNS: "lock.rectangle.stack"; case .vpn: "lock.shield"; case .backup: "externaldrive"; case .storage: "internaldrive"
        case .about: "info.circle"
        }
    }
    static let groups: [(title: String?, pages: [SettingsPage])] = [
        ("Viewing", [.playback, .health, .appearance, .parental, .privacyReport]),
        ("Library", [.library, .artwork, .channels, .alerts, .profiles, .icloud, .lan, .proxy, .appDNS, .vpn, .backup, .storage]),
        (nil, [.about]),
    ]
    @MainActor @ViewBuilder var destination: some View {
        switch self {
        case .playback: PlaybackSettingsView(); case .health: PlaybackHealthView(); case .appearance: AppearanceView(); case .parental: ParentalView(); case .privacyReport: PrivacyReportScreen().atlasScreen("screen.ios.settings.privacyReport")
        case .library: LibrarySettingsView(); case .artwork: ArtworkSettingsView(); case .channels: ChannelManagerView(); case .alerts: GuideToolsView(); case .profiles: ProfilesView()
        case .icloud: CloudSyncView(); case .lan: LanSyncView(); case .proxy: ProxyView(); case .appDNS: AppDNSView(); case .vpn: VPNView(); case .backup: BackupView(); case .storage: StorageView()
        case .about: AboutView()
        }
    }
}

struct SettingsView: View {
    var embedded = false
    var body: some View {
        OptionalStack(embedded: embedded) {
            List {
                ForEach(Array(SettingsPage.groups.enumerated()), id: \.offset) { _, group in
                    Section(group.title ?? "") {
                        ForEach(group.pages) { page in NavigationLink { page.destination } label: { Label(page.title, systemImage: page.symbol) }.accessibilityIdentifier("settings.row.\(page.rawValue)").atlasCovers("screen.ios.tab.settings") }
                    }.glossRow()
                }
            }
            .navigationTitle("Settings").atlasScreen("screen.ios.tab.settings").themed("Settings")
            .miniPlayerInset()
        }
    }
}

/// iPad: the list of Settings pages beside the chosen page, instead of pushing each page over the last.
struct IPadSettings: View {
    @SceneStorage("ipad.settings.page") private var saved = SettingsPage.playback.rawValue
    var body: some View {
        let page = SettingsPage(rawValue: saved) ?? .playback
        HStack(spacing: 0) {
            List {
                ForEach(Array(SettingsPage.groups.enumerated()), id: \.offset) { _, group in
                    Section(group.title ?? "") {
                        ForEach(group.pages) { p in
                            Button { saved = p.rawValue } label: { Label(p.title, systemImage: p.symbol).foregroundStyle(.primary) }
                                .listRowBackground(p == page ? ColorTokens.accentDefault.opacity(0.16) : Color.clear)
                                .accessibilityAddTraits(p == page ? .isSelected : [])
                                .atlasCovers("screen.ios.tab.settings")
                        }
                    }
                }
            }
            .listStyle(.sidebar).scrollContentBackground(.hidden).background(ColorTokens.surface)
            .safeAreaInset(edge: .top, spacing: 0) { Text("Settings").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 12).background(ColorTokens.surface) }
            .frame(width: 300)
            Divider()
            NavigationStack { page.destination }.id(page)
        }
    }
}

/// Whether this build contains the MPV engine.
enum AppEngineChoice {
    static var available: Bool {
        #if STREAMSETU_MPV
        true
        #else
        false
        #endif
    }
}

/// Playlists: add, switch, refresh and remove them.
struct PlaylistRoute: Hashable { let id: UUID }

struct PlaylistsView: View {
    var embedded = false
    @Environment(AppState.self) private var state
    @Environment(IOSRouter.self) private var router
    @Environment(\.container) private var container
    @State private var pendingDelete: PlaylistSource?

    var body: some View {
        OptionalStack(embedded: embedded) {
            List {
                Section {
                    if state.canCombinePlaylists {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("All Playlists")
                                Text("Channels, movies and series from every playlist together").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if state.showsAllPlaylists { Image(systemName: "checkmark.circle.fill").foregroundStyle(ColorTokens.accentDefault).accessibilityLabel("Active") }
                            else { Button("Use") { state.switchToAllPlaylists() }.buttonStyle(.bordered).controlSize(.small).atlas("control.ios.playlists.use") }
                        }
                    }
                    ForEach(state.sources) { s in
                        NavigationLink(value: PlaylistRoute(id: s.id)) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.name)
                                    Text(status(s)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if state.activeSourceID == s.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(ColorTokens.accentDefault).accessibilityLabel("Active") }
                                else if s.enabled { Button("Use") { state.switchPlaylist(s.id) }.buttonStyle(.bordered).controlSize(.small).atlas("control.ios.playlists.use") }
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { pendingDelete = s } label: { Label("Delete", systemImage: "trash") }
                            Button { state.sync(s.id, forceGuide: true) } label: { Label("Refresh", systemImage: "arrow.clockwise") }.tint(.blue)
                        }
                        .contextMenu {
                            if state.activeSourceID != s.id, s.enabled { Button { state.switchPlaylist(s.id) } label: { Label("Use This Playlist", systemImage: "checkmark.circle") } }
                            Button { state.sync(s.id, forceGuide: true) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                            Button(role: .destructive) { pendingDelete = s } label: { Label("Delete…", systemImage: "trash") }
                        }
                        .atlas("context.ios.playlist")
                    }
                    Button { router.presentAdd = true } label: { Label("Add Playlist", systemImage: "plus") }.atlas("control.ios.playlists.add")
                    if !state.sources.isEmpty { Button { state.syncAll() } label: { Label(state.isSyncing ? "Refreshing…" : "Refresh All", systemImage: "arrow.clockwise") }.disabled(state.isSyncing).atlas("control.ios.playlists.refreshAll") }
                }.glossRow()
            }
            .navigationTitle("Playlists").atlasScreen("screen.ios.tab.playlists").themed("Playlists")
            .miniPlayerInset()
            .navigationDestination(for: PlaylistRoute.self) { PlaylistDetailView(sourceID: $0.id) }
            .confirmationDialog("Delete \(pendingDelete?.name ?? "this playlist")?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
                Button("Delete Playlist", role: .destructive) { if let s = pendingDelete { delete(s) }; pendingDelete = nil }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { Text("Its channels, movies, series and saved login are removed from this device. Your provider account is not affected. You can add it again any time.") }
        }
    }

    private func status(_ s: PlaylistSource) -> String {
        if let p = state.syncProgress[s.id], p.state.isBusy { return p.state.label }
        if case .failed(let m)? = state.syncProgress[s.id]?.state { return "Could not update: \(m)" }
        return s.lastSync.map { "Updated " + $0.formatted(.relative(presentation: .named)) } ?? "Not updated yet"
    }

    private func delete(_ s: PlaylistSource) {
        guard let c = container else { return }
        do { try c.sources.remove(s.id) }
        catch { state.toasts.show("Could not remove \(s.name): \(error.localizedDescription)", symbol: "exclamationmark.triangle") }
        state.reload()
    }
}
