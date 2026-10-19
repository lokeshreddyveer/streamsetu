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
                    NavigationLink { FavouritesView() } label: { LibraryRow(symbol: "heart.fill", tint: .pink, title: "Favourites", count: state.favoriteIDs.count) }
                    NavigationLink { WatchLaterView() } label: { LibraryRow(symbol: "bookmark.fill", tint: .orange, title: "Watch Later", count: state.watchLaterIDs.count) }
                    NavigationLink { CollectionsView() } label: { LibraryRow(symbol: "square.stack.fill", tint: .indigo, title: "Collections", count: nil) }
                    NavigationLink { HistoryView() } label: { LibraryRow(symbol: "clock.arrow.circlepath", tint: .teal, title: "Watch History", count: nil) }
                    NavigationLink { DownloadsView() } label: { LibraryRow(symbol: "arrow.down.circle.fill", tint: .blue, title: "Downloads", count: nil) }
                    NavigationLink { FilesView() } label: { LibraryRow(symbol: "externaldrive.fill", tint: .gray, title: "Files and Servers", count: nil) }
                }.listRowBackground(ColorTokens.surface)
                Section { NavigationLink { StatisticsView() } label: { LibraryRow(symbol: "chart.bar.fill", tint: .green, title: "Statistics", count: nil) } }.listRowBackground(ColorTokens.surface)
            }
            .navigationTitle("Library").themed("Library")
            .miniPlayerInset()
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
                    EmptyState(symbol: "heart", title: "No favourites yet", message: "Tap the heart on a channel, movie or series.")
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
        .navigationTitle("Favourites").themed("Favourites")
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
                        VStack(alignment: .leading, spacing: 4) {
                            Text(r.title).appFont(15, .semibold).lineLimit(2)
                            Text(r.progress.completed ? "Watched" : "\(Int(r.progress.fraction * 100))% watched").appFont(12).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }.buttonStyle(.press)
                .swipeActions { Button(role: .destructive) { try? container?.historyRepo.clearProgress(itemID: r.id); items.removeAll { $0.id == r.id }; state.catalogVersion += 1 } label: { Label("Remove", systemImage: "trash") } }
            }
        }
        .navigationTitle("Watch History").themed("Watch History")
        .safeAreaInset(edge: .top, spacing: 0) {
            if !items.isEmpty {
                Button(role: .destructive) { confirmClear = true } label: { Label("Clear Watch History", systemImage: "trash").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large).padding(.horizontal, 16).padding(.vertical, 8).background(ColorTokens.background)
            }
        }
        .confirmationDialog("Clear watch history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Watch History", role: .destructive) {
                try? container?.historyRepo.clearHistory(); try? container?.historyRepo.clearResumePoints(sourcePrefix: nil)
                items = []; state.catalogVersion += 1
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
                Picker("Mode", selection: $s.bufferingMode) { ForEach(BufferingMode.allCases) { Text($0.rawValue).tag($0) } }
                Text("A larger buffer gives a steadier picture on weak connections, with a little more delay on live channels.").font(.caption).foregroundStyle(.secondary)
            }.listRowBackground(ColorTokens.surface)
            Section("Resuming") {
                Toggle("Resume movies and episodes where I stopped", isOn: $s.resumeAutomatically)
                Toggle("Remember my position", isOn: $s.rememberPosition)
                Toggle("Play the next episode automatically", isOn: $s.autoPlayNextEpisode)
            }.listRowBackground(ColorTokens.surface)
            if AppEngineChoice.available {
                Section {
                    Picker("Player", selection: Binding(get: { settings.enginePreference },
                                                        set: { new in if new == .mpv, settings.enginePreference != .mpv { confirmMPV = true } else { settings.enginePreference = new } })) {
                        ForEach(PlaybackEnginePreference.allCases) { Text($0.rawValue).tag($0) }
                    }
                    ForEach(AppSettings.ViewingKind.allCases) { kind in
                        Picker("For \(kind.title)", selection: Binding(get: { settings.engineChoice(for: kind) }, set: { settings.setEngineChoice($0, for: kind) })) {
                            Text("Same as above").tag(PlaybackEnginePreference?.none)
                            ForEach(PlaybackEnginePreference.allCases) { Text($0.rawValue).tag(PlaybackEnginePreference?.some($0)) }
                        }
                    }
                } header: { Text("Player engine") } footer: {
                    Text("Automatic uses Apple's player for movies, episodes and HLS, and MPV for live TV and for formats Apple's player can't open (MKV, RTSP, AVI). MPV doesn't support Picture in Picture or AirPlay.")
                }.listRowBackground(ColorTokens.surface)
            }
            Section("Picture quality") {
                Picker("Streams with several qualities", selection: $s.videoQuality) { ForEach(VideoQualityPreference.allCases) { Text($0.rawValue).tag($0) } }
            }.listRowBackground(ColorTokens.surface)
            Section("Language") {
                TextField("Preferred audio language (e.g. en)", text: $s.preferredAudioLanguage).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Preferred subtitle language (e.g. en)", text: $s.preferredSubtitleLanguage).textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Show subtitles by default", isOn: $s.subtitlesByDefault)
                Toggle("Fetch subtitles automatically", isOn: $s.autoSubtitles)
            }.listRowBackground(ColorTokens.surface)
            Section {
                OpenSubtitlesFields()
            } header: { Text("Subtitles online") } footer: { Text("From OpenSubtitles, using your own free account and API key (opensubtitles.com). They stay in the Keychain on this device and are sent only to OpenSubtitles when you ask for subtitles in the player.") }
            .listRowBackground(ColorTokens.surface)
            Section {
                Toggle("Remember settings for each title", isOn: Binding(get: { ItemMemory().enabled }, set: { ItemMemory().enabled = $0 }))
            } footer: { Text("Audio language, subtitles, speed and timing come back the next time you play the same title or channel.") }
            .listRowBackground(ColorTokens.surface)
            Section("Subtitle style") {
                VStack(alignment: .leading) { Text("Size \(Int(s.subtitleSize))%").font(.subheadline); Slider(value: $s.subtitleSize, in: 60...200, step: 10) }
                VStack(alignment: .leading) { Text("Background \(Int(s.subtitleBackground * 100))%").font(.subheadline); Slider(value: $s.subtitleBackground, in: 0...1) }
                Picker("Colour", selection: $s.subtitleColor) { ForEach(SubtitleColor.allCases) { Text($0.rawValue).tag($0) } }
                Toggle("Outline", isOn: $s.subtitleOutline)
            }.listRowBackground(ColorTokens.surface)
        }
        .navigationTitle("Playback").themed("Playback")
        .alert("Switch to MPV?", isPresented: $confirmMPV) {
            Button("Use MPV") { settings.enginePreference = .mpv }
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
            }.listRowBackground(ColorTokens.surface)
            Section {
                Text("StreamSetu plays playlists and Xtream accounts you add yourself. It includes no channels or content, has no accounts, and keeps everything on this device.").font(.callout)
            }.listRowBackground(ColorTokens.surface)
            Section {
                NavigationLink { FeedbackView() } label: { Label("Send Feedback", systemImage: "envelope") }
                NavigationLink { CrashReportsView() } label: { Label("Crash Reports", systemImage: "ladybug") }
            }.listRowBackground(ColorTokens.surface)
            if let t = UserDefaults.standard.dictionary(forKey: "startup.timings") as? [String: Int], !t.isEmpty {
                Section("Last launch") {
                    ForEach(["library opened", "library read", "ready"], id: \.self) { k in if let ms = t[k] { LabeledContent(k.capitalized, value: String(format: "%.2f s", Double(ms) / 1000)) } }
                }.listRowBackground(ColorTokens.surface)
            }
            Section("Legal") {
                ForEach(LegalPage.allCases) { page in
                    NavigationLink { LegalView(page: page).navigationTitle(page.title).navigationBarTitleDisplayMode(.inline) } label: { Text(page.title) }
                }
            }.listRowBackground(ColorTokens.surface)
        }
        .navigationTitle("About").themed("About")
    }
}

/// Settings: how the app behaves and looks, and its maintenance.
struct SettingsView: View {
    var embedded = false
    var body: some View {
        OptionalStack(embedded: embedded) {
            List {
                Section("Viewing") {
                    NavigationLink { PlaybackSettingsView() } label: { Label("Playback", systemImage: "play.rectangle") }
                    NavigationLink { PlaybackHealthView() } label: { Label("Playback Health", systemImage: "waveform.path.ecg") }
                    NavigationLink { AppearanceView() } label: { Label("Appearance", systemImage: "paintpalette") }
                    NavigationLink { ParentalView() } label: { Label("Parental Controls", systemImage: "lock.shield") }
                }.listRowBackground(ColorTokens.surface)
                Section("Library") {
                    NavigationLink { LibrarySettingsView() } label: { Label("Library and Guide", systemImage: "books.vertical") }
                    NavigationLink { ArtworkSettingsView() } label: { Label("Artwork and Details", systemImage: "photo.on.rectangle.angled") }
                    NavigationLink { ChannelManagerView() } label: { Label("Channel Manager", systemImage: "slider.horizontal.3") }
                    NavigationLink { CloudSyncView() } label: { Label("iCloud Sync", systemImage: "icloud") }
                    NavigationLink { ProxyView() } label: { Label("Proxy", systemImage: "network") }
                    NavigationLink { VPNView() } label: { Label("VPN", systemImage: "lock.shield") }
                    NavigationLink { BackupView() } label: { Label("Backup and Restore", systemImage: "externaldrive") }
                    NavigationLink { StorageView() } label: { Label("Storage and Maintenance", systemImage: "internaldrive") }
                }.listRowBackground(ColorTokens.surface)
                Section { NavigationLink { AboutView() } label: { Label("About", systemImage: "info.circle") } }.listRowBackground(ColorTokens.surface)
            }
            .navigationTitle("Settings").themed("Settings")
            .miniPlayerInset()
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
struct PlaylistsView: View {
    var embedded = false
    @Environment(AppState.self) private var state
    @Environment(IOSRouter.self) private var router
    @Environment(\.container) private var container

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
                            else { Button("Use") { state.switchToAllPlaylists() }.buttonStyle(.bordered).controlSize(.small) }
                        }
                    }
                    ForEach(state.sources) { s in
                        NavigationLink { PlaylistDetailView(sourceID: s.id) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.name)
                                    Text(status(s)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if state.activeSourceID == s.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(ColorTokens.accentDefault).accessibilityLabel("Active") }
                                else if s.enabled { Button("Use") { state.switchPlaylist(s.id) }.buttonStyle(.bordered).controlSize(.small) }
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { delete(s) } label: { Label("Delete", systemImage: "trash") }
                            Button { state.sync(s.id, forceGuide: true) } label: { Label("Refresh", systemImage: "arrow.clockwise") }.tint(.blue)
                        }
                    }
                    Button { router.presentAdd = true } label: { Label("Add Playlist", systemImage: "plus") }
                    if !state.sources.isEmpty { Button { state.syncAll() } label: { Label(state.isSyncing ? "Refreshing…" : "Refresh All", systemImage: "arrow.clockwise") }.disabled(state.isSyncing) }
                }.listRowBackground(ColorTokens.surface)
            }
            .navigationTitle("Playlists").themed("Playlists")
            .miniPlayerInset()
        }
    }

    private func status(_ s: PlaylistSource) -> String {
        if let p = state.syncProgress[s.id], p.state.isBusy { return p.state.label }
        if case .failed(let m)? = state.syncProgress[s.id]?.state { return "Could not update: \(m)" }
        return s.lastSync.map { "Updated " + $0.formatted(.relative(presentation: .named)) } ?? "Not updated yet"
    }

    private func delete(_ s: PlaylistSource) {
        guard let c = container else { return }
        try? c.sources.remove(s.id); state.reload()
    }
}
