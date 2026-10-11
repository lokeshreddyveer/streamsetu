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
                    NavigationLink { FavouritesView() } label: { Label("Favourites", systemImage: "heart") }
                    NavigationLink { CollectionsView() } label: { Label("Collections", systemImage: "square.stack") }
                    NavigationLink { HistoryView() } label: { Label("Watch History", systemImage: "clock.arrow.circlepath") }
                }.listRowBackground(ColorTokens.surface)
                Section { NavigationLink { StatisticsView() } label: { Label("Statistics", systemImage: "chart.bar") } }.listRowBackground(ColorTokens.surface)
            }
            .navigationTitle("Library").themed("Library")
            .miniPlayerInset()
        }
    }
}

struct FavouritesView: View {
    @Environment(AppState.self) private var state
    @Environment(\.container) private var container
    @State private var channels: [Channel] = []
    @State private var titles: [LibraryItem] = []

    var body: some View {
        List {
            if channels.isEmpty, titles.isEmpty {
                EmptyState(symbol: "heart", title: "No favourites yet", message: "Tap the heart on a channel, movie or series.").listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            if !channels.isEmpty {
                Section("Channels") {
                    ForEach(channels) { c in
                        Button { if let container { Play.channel(c, queue: channels, container) } } label: { ChannelRow(channel: c, isFavorite: true) }.buttonStyle(.press)
                    }
                }.listRowBackground(ColorTokens.surface)
            }
            if !titles.isEmpty {
                Section("Movies and Series") {
                    ForEach(titles) { t in
                        NavigationLink(value: t) { HStack(spacing: 12) {
                            ArtworkImage(url: t.posterURL, kind: .poster, contentMode: .fill, symbol: "film").frame(width: 44, height: 62).clipShape(RoundedRectangle(cornerRadius: 6))
                            Text(t.title).lineLimit(2)
                        } }
                    }
                }.listRowBackground(ColorTokens.surface)
            }
        }
        .navigationTitle("Favourites").themed("Favourites")
        .navigationDestination(for: LibraryItem.self) { DetailView(item: $0) }
        .task(id: state.catalogVersion) { await load() }
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
        channels = ch; titles = ti
    }
}

struct HistoryView: View {
    @Environment(AppState.self) private var state
    @Environment(\.container) private var container
    @State private var items: [ContinueItem] = []

    var body: some View {
        List {
            if items.isEmpty { EmptyState(symbol: "clock", title: "Nothing watched yet", message: "Movies and episodes you start appear here with their place saved.").listRowBackground(Color.clear).listRowSeparator(.hidden) }
            ForEach(items) { r in
                Button {
                    guard let c = container else { return }
                    switch r.content { case .movie(let m): Play.movie(m, c); case .episode(let e, let s): Play.episode(e, s, c) }
                } label: {
                    HStack(spacing: 12) {
                        ArtworkImage(url: r.artworkURL, kind: .backdrop, contentMode: .fill, symbol: "play.rectangle").frame(width: 100, height: 56).clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(r.title).appFont(14, .medium).lineLimit(2)
                            ProgressView(value: r.progress.fraction).tint(ColorTokens.accentDefault)
                        }
                    }
                }.buttonStyle(.press)
            }
        }
        .navigationTitle("Watch History").themed("Watch History")
        .task(id: state.catalogVersion) {
            guard let c = container else { return }
            let source = state.activeSourceID
            items = await Task.detached { (try? c.history.continueWatching(limit: 60, sourceID: source)) ?? [] }.value
        }
    }
}

struct PlaybackSettingsView: View {
    @Environment(AppSettings.self) private var settings

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
                    Picker("Player", selection: $s.enginePreference) { ForEach(PlaybackEnginePreference.allCases) { Text($0.rawValue).tag($0) } }
                } header: { Text("Player engine") } footer: {
                    Text("Automatic uses Apple's player and switches to MPV for formats it can't open (MKV, RTSP, AVI). MPV doesn't support Picture in Picture.")
                }.listRowBackground(ColorTokens.surface)
            }
            Section("Picture quality") {
                Picker("Streams with several qualities", selection: $s.videoQuality) { ForEach(VideoQualityPreference.allCases) { Text($0.rawValue).tag($0) } }
            }.listRowBackground(ColorTokens.surface)
            Section("Language") {
                TextField("Preferred audio language (e.g. en)", text: $s.preferredAudioLanguage).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Preferred subtitle language (e.g. en)", text: $s.preferredSubtitleLanguage).textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Show subtitles by default", isOn: $s.subtitlesByDefault)
            }.listRowBackground(ColorTokens.surface)
            Section("Subtitle style") {
                VStack(alignment: .leading) { Text("Size \(Int(s.subtitleSize))%").font(.subheadline); Slider(value: $s.subtitleSize, in: 60...200, step: 10) }
                VStack(alignment: .leading) { Text("Background \(Int(s.subtitleBackground * 100))%").font(.subheadline); Slider(value: $s.subtitleBackground, in: 0...1) }
                Picker("Colour", selection: $s.subtitleColor) { ForEach(SubtitleColor.allCases) { Text($0.rawValue).tag($0) } }
                Toggle("Outline", isOn: $s.subtitleOutline)
            }.listRowBackground(ColorTokens.surface)
        }
        .navigationTitle("Playback").themed("Playback")
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
