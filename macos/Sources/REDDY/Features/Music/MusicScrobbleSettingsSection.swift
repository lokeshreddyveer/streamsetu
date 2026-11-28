import SwiftUI

/// Scrobbling settings: the services, when a play counts, how a track is cleaned up before it is sent, and a live preview of exactly what goes out.
struct MusicScrobbleSettingsSection: View {
    let hub: MusicHub
    @State private var flow: LastFMAuthFlow
    @State private var connect = LastFMConnectModel(auth: LastFMAuth(store: ScrobbleKeychainStore()))
    @State private var apiKey = ""
    @State private var apiSecret = ""
    @State private var lfCustom = false
    @State private var lfEndpoint = ""
    @State private var lfError: String?
    @State private var lbToken = ""
    @State private var lbServer = ""
    @State private var lbCustom = false
    @State private var lbMessage: String?
    @State private var lbBusy = false
    @State private var lbCount: Int?
    @State private var lbUser: String?
    @State private var editing = false
    @State private var editArtist = ""
    @State private var editTitle = ""
    @State private var editAlbum = ""
    @State private var editSkip = false
    @Environment(\.openURL) private var openURL

    init(hub: MusicHub) {
        self.hub = hub
        _flow = State(initialValue: LastFMAuthFlow(client: hub.scrobbler.lastFM))
    }

    private var scrobbler: MusicScrobbler { hub.scrobbler }
    private var store: MusicScrobbleConfigStore { hub.scrobbler.configStore }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicTokens.settingsGroupSpacing) {
            generalGroup
            lastFMGroup
            listenBrainzGroup
            MusicSettingsDisclosure(title: "Cleanup") { cleanup }
            MusicSettingsDisclosure(title: "Preview") { preview }
        }
        .onAppear {
            flow.openURL = { openURL($0) }
            if case .connected = connect.state { flow.refresh() }
            let c = hub.scrobbler.listenBrainz
            lbUser = c.username
            lfCustom = hub.scrobbler.lastFM.usesCustomEndpoint
            if lfCustom { lfEndpoint = hub.scrobbler.lastFM.endpoint.absoluteString }
            lbCustom = c.isConnected && c.root.absoluteString != ListenBrainzClient.defaultRoot
            if lbCustom { lbServer = c.root.absoluteString }
        }
        .onChange(of: connect.state) { _, new in if case .connected = new { flow.refresh() } }
        .task(id: lbUser) { if let u = lbUser { lbCount = await hub.scrobbler.listenBrainz.listenCount(user: u) } }
    }

    private func cfg<T>(_ kp: WritableKeyPath<MusicScrobbleConfig, T>) -> Binding<T> {
        Binding(get: { store.config[keyPath: kp] }, set: { store.config[keyPath: kp] = $0 })
    }

    // MARK: services

    private var generalGroup: some View {
        let others = scrobbler.serviceStates().filter { $0.id != "lastfm" && $0.id != "listenbrainz" }
        return MusicSettingsGroup(title: "Scrobbling") {
            MusicToggleRow(title: "Scrobble plays", info: "Turn off to stop scrobbling for a while without disconnecting your account.",
                           isOn: Binding(get: { hub.library.settings.scrobbleEnabled }, set: { hub.library.settings.scrobbleEnabled = $0 }))
            MusicToggleRow(title: "Show what's playing", info: "Tells the services which song is playing now.", isOn: cfg(\.nowPlaying))
            MusicSliderRow(title: "Count a play after", info: "Counted in play time, not playhead position. The 50% / 3 minute rule is also applied when it is stricter.",
                           value: Binding(get: { Double(store.config.percent) }, set: { store.config.percent = Int($0) }), range: 10...100, step: 5,
                           valueText: "\(store.config.clampedPercent)%")
            MusicSliderRow(title: "Or after", info: "Whichever comes first. Last.fm's rule is four minutes. Songs shorter than 30 seconds, and the first 30 seconds of any song, never count.",
                           value: Binding(get: { Double(store.config.minutes) }, set: { store.config.minutes = Int($0) }), range: 0...10, step: 1,
                           valueText: store.config.clampedMinutes == 0 ? Localized.string("Off") : Localized.string("%d min", store.config.clampedMinutes))
            ForEach(others) { s in
                MusicToggleRow(title: s.name, isOn: Binding(get: { store.config.isServiceEnabled(s.id) }, set: { store.config.serviceEnabled[s.id] = $0 }))
            }
            if let f = scrobbler.failures.last { MusicNote(text: Localized.string("Last problem: %1$@ - %2$@", f.provider, f.message), tone: .bad) }
        }
    }

    private var lastFMGroup: some View {
        MusicSettingsGroup(title: "Last.fm", footer: lastFMConnected ? nil : BuiltInLastFM.isAvailable ? "Connect opens Last.fm in your browser to approve StreamSetu. Only the session is kept, in this device's Keychain." : "Uses your own Last.fm API account (last.fm/api/account/create). Your key and secret stay in this device's Keychain.") {
            switch flow.state {
            case .connected(let user):
                MusicValueRow(title: "Signed in as", value: user)
                MusicToggleRow(title: "Send to Last.fm", isOn: Binding(get: { store.config.isServiceEnabled("lastfm") }, set: { store.config.serviceEnabled["lastfm"] = $0 }))
                MusicSettingsActions {
                    if let u = URL(string: "https://www.last.fm/user/\(user)") { Button("Open profile") { openURL(u) }.atlas("control.music.settingsScrobblingOpenProfile") }
                    Button("Disconnect") { connect.reset(); flow.disconnect() }.accessibilityLabel(Text("Disconnect Last.fm")).atlas("control.music.settingsScrobblingDisconnectLastFm")
                }
            default:
                if BuiltInLastFM.isAvailable {
                    oneClickConnect
                    MusicSettingsDisclosure(title: "Use my own Last.fm key") { ownKeyFields }
                } else {
                    ownKeyFields
                }
            }
        }
    }

    @ViewBuilder private var oneClickConnect: some View {
        switch connect.state {
        case .waiting:
            MusicSettingsActions {
                MusicLoadingIcon(size: MusicIconSize.small)
                Text("Waiting for you to approve in the browser...").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                Button("Cancel") { connect.cancel() }.accessibilityLabel(Text("Cancel Last.fm sign-in")).atlas("control.music.settingsScrobblingCancelLastFmSignIn")
            }
        case .connected(let user):
            MusicNote(text: Localized.string("Connected as %1$@", user))
        case .idle, .failed:
            MusicSettingsActions {
                Button("Connect Last.fm") {
                    scrobbler.lastFM.setEndpoint("")
                    connect.start()
                }.musicButton(.primary).accessibilityLabel(Text("Connect Last.fm")).atlas("control.music.settingsScrobblingConnectLastFm")
            }
            if case .failed(let m) = connect.state { MusicNote(text: m, tone: .bad) }
        }
    }

    @ViewBuilder private var ownKeyFields: some View {
                MusicFieldRow(title: "API key", prompt: flow.hasAppKeys ? "Saved" : "", text: $apiKey)
                MusicFieldRow(title: "Shared secret", prompt: flow.hasAppKeys ? "Saved" : "", secret: true, text: $apiSecret)
                MusicToggleRow(title: "Compatible server", info: "Use a Last.fm-compatible server such as Libre.fm. Leave off to use Last.fm.", isOn: $lfCustom)
                if lfCustom { MusicFieldRow(title: "Server address", prompt: "https://libre.fm/2.0/", text: $lfEndpoint) }
                if let e = lfError { MusicNote(text: e, tone: .bad) }
                MusicSettingsActions {
                    if flow.state == .connecting {
                        MusicLoadingIcon(size: MusicIconSize.small)
                        Text("Approve StreamSetu in your browser.").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                        Button("Cancel") { flow.cancel() }.accessibilityLabel(Text("Cancel Last.fm sign-in")).atlas("control.music.settingsScrobblingCancelLastFmSignIn")
                    } else {
                        Button("Connect") {
                            guard scrobbler.lastFM.setEndpoint(lfCustom ? lfEndpoint : "") else {
                                lfError = "Server address must be http(s)://host[/path], without ? or #"; return
                            }
                            lfError = nil
                            if !apiKey.isEmpty || !apiSecret.isEmpty { scrobbler.lastFM.setAppKeys(key: apiKey, secret: apiSecret); apiKey = ""; apiSecret = "" }
                            Task { await flow.connect() }
                        }.accessibilityLabel(Text("Connect Last.fm")).atlas("control.music.settingsScrobblingConnectLastFm")
                    }
                }
                if case .failed(let m) = flow.state { MusicNote(text: m, tone: .bad) }
    }

    private var lastFMConnected: Bool { if case .connected = flow.state { true } else { false } }

    private var listenBrainzGroup: some View {
        MusicSettingsGroup(title: "ListenBrainz", footer: lbUser == nil ? "Paste the user token from listenbrainz.org/settings. It is checked before it is kept, and stored in this device's Keychain." : nil) {
            if let user = lbUser {
                MusicValueRow(title: "Signed in as", value: user + (lbCount.map { " · " + Localized.string("%d listens", $0) } ?? ""))
                MusicToggleRow(title: "Send to ListenBrainz", isOn: Binding(get: { store.config.isServiceEnabled("listenbrainz") }, set: { store.config.serviceEnabled["listenbrainz"] = $0 }))
                if let p = scrobbler.listenBrainzProblem { MusicNote(text: p.message, tone: .bad) }
                MusicSettingsActions {
                    if let u = scrobbler.listenBrainz.profileURL(user: user) { Button("Open profile") { openURL(u) }.atlas("control.music.settingsScrobblingOpenProfile") }
                    if scrobbler.listenBrainzProblem == .email, let u = URL(string: "https://metabrainz.org/profile") {
                        Button("Verify email") { openURL(u) }.accessibilityLabel(Text("Verify your MetaBrainz email")).atlas("control.music.settingsScrobblingVerifyYourMetabrainzEmail")
                    }
                    Button("Disconnect") {
                        scrobbler.listenBrainz.disconnect(); scrobbler.resetListenBrainzProblem(); lbUser = nil; lbCount = nil; lbToken = ""
                    }.accessibilityLabel(Text("Disconnect ListenBrainz")).atlas("control.music.settingsScrobblingDisconnectListenbrainz")
                }
            } else {
                MusicFieldRow(title: "User token", secret: true, text: $lbToken).onSubmit(connectListenBrainz)
                MusicToggleRow(title: "Custom instance", isOn: $lbCustom)
                if lbCustom { MusicFieldRow(title: "Instance address", prompt: "https://listenbrainz.example.com", text: $lbServer) }
                MusicSettingsActions {
                    Button((lbBusy ? "Checking..." : "Connect").loc, action: connectListenBrainz).disabled(lbBusy || lbToken.isEmpty).accessibilityLabel(Text("Connect ListenBrainz")).atlas("control.music.settingsScrobblingConnectListenbrainz")
                    if let u = URL(string: "https://listenbrainz.org/settings/") { Button("Open ListenBrainz settings") { openURL(u) }.atlas("control.music.settingsScrobblingOpenListenbrainzSettings") }
                }
                if let m = lbMessage { MusicNote(text: m, tone: .bad) }
            }
        }
    }

    private func connectListenBrainz() {
        guard !lbBusy, !lbToken.isEmpty else { return }
        lbBusy = true; lbMessage = nil
        let client = scrobbler.listenBrainz, token = lbToken, server = lbCustom ? lbServer : ""
        Task {
            do {
                let user = try await client.connect(token: token, server: server)
                lbUser = user; lbToken = ""; scrobbler.resetListenBrainzProblem()
            } catch { lbMessage = (error as? ScrobbleSendError)?.message ?? error.localizedDescription }
            lbBusy = false
        }
    }

    // MARK: cleanup

    private var cleanup: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            MusicToggleRow(title: "Read the artist from video titles", info: "For video uploads only: \"Artist - Song\" becomes artist and song.",
                           isOn: Binding(get: { store.config.clean.splitVideoTitles }, set: { store.config.clean.splitVideoTitles = $0 }))
            MusicToggleRow(title: "Scrobble the primary artist only", info: "\"Future, Metro Boomin\" is sent as \"Future\".",
                           isOn: Binding(get: { store.config.clean.primaryArtist }, set: { store.config.clean.primaryArtist = $0 }))
            if store.config.clean.primaryArtist {
                MusicToggleRow(title: "Drop artists joined with '&' too", info: "\"Future & Metro Boomin\" is sent as \"Future\".",
                               isOn: Binding(get: { store.config.clean.primaryStrict }, set: { store.config.clean.primaryStrict = $0 }))
            }
            let errors = scrobbler.preview(for: hub.player.current).cleaned.ruleErrors
            ForEach(Array(store.config.clean.rules.enumerated()), id: \.element.id) { i, rule in
                ruleRow(i, rule, error: errors.first { $0.index == i }?.message)
            }
            MusicSettingsRow(title: "Rules") {
                Menu("Add rule") {
                    ForEach(MusicTrackCleaner.presets) { p in Button(p.name) { store.config.clean.rules.append(p.rule) }.atlas("control.music.settingsScrobblingMusicscrobblesettingssectioncleanupButton") }
                    Divider()
                    Button("Empty rule") { store.config.clean.rules.append(ScrobbleRule()) }.atlas("control.music.settingsScrobblingEmptyRule")
                }
                .menuStyle(.button).fixedSize().accessibilityLabel(Text("Add a cleanup rule")).atlas("control.music.settingsScrobblingAddACleanupRule")
            }
            ForEach(store.config.clean.edits) { e in
                MusicSettingsRow(title: "Track edit", detail: editLabel(e)) {
                    Button("Remove") { store.config.clean.edits.removeAll { $0.id == e.id } }.musicButton().accessibilityLabel(Text("Remove edit")).atlas("control.music.settingsScrobblingRemoveEdit")
                }
            }
        }
    }

    private func editLabel(_ e: ScrobbleEdit) -> String {
        if e.skip { return Localized.string("Never scrobble: %@", e.key.isEmpty ? e.fromTitle : e.key) }
        return [e.artist, e.title, e.album].filter { !$0.isEmpty }.joined(separator: " - ")
    }

    private func ruleRow(_ i: Int, _ rule: ScrobbleRule, error: String?) -> some View {
        func bind<T>(_ kp: WritableKeyPath<ScrobbleRule, T>) -> Binding<T> {
            Binding(get: { store.config.clean.rules.indices.contains(i) ? store.config.clean.rules[i][keyPath: kp] : rule[keyPath: kp] },
                    set: { if store.config.clean.rules.indices.contains(i) { store.config.clean.rules[i][keyPath: kp] = $0 } })
        }
        return VStack(alignment: .leading, spacing: Spacing.sm) {
            MusicSettingsRow(title: Localized.string("Rule %d", i + 1)) {
                HStack(spacing: Spacing.sm) {
                    Picker("Field", selection: bind(\.field)) { ForEach(ScrobbleField.allCases, id: \.self) { Text(verbatim: $0.rawValue.capitalized).tag($0) } }
                        .labelsHidden().frame(width: MusicTokens.settingsControlWidth / 2).accessibilityLabel(Text(verbatim: Localized.string("Rule %d field", i + 1))).atlas("control.music.settingsScrobblingField")
                    Toggle("On", isOn: bind(\.enabled)).toggleStyle(.switch).labelsHidden().accessibilityLabel(Text(verbatim: Localized.string("Rule %d on", i + 1))).atlas("control.music.settingsScrobblingOn")
                    Button { if store.config.clean.rules.indices.contains(i) { store.config.clean.rules.remove(at: i) } } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(ColorTokens.textTertiary).accessibilityLabel(Text(verbatim: Localized.string("Remove rule %d", i + 1))).atlas("control.music.settingsScrobblingMusicscrobblesettingssectionrulerowButton")
                }
            }
            MusicFieldRow(title: "Find", prompt: "Regular expression", text: bind(\.find))
            MusicFieldRow(title: "Replace with", text: bind(\.replace))
            if let error { MusicNote(text: error, tone: .bad) }
        }
    }

    // MARK: preview

    private var preview: some View {
        let current = hub.player.current
        let p = scrobbler.preview(for: current)
        return VStack(alignment: .leading, spacing: Spacing.md) {
            MusicValueRow(title: current == nil ? "Sample track" : "Now playing",
                             value: "\(p.original.title) - \(p.original.artistLine)" + (p.original.album.isEmpty ? "" : " (\(p.original.album))"))
            if p.cleaned.skip != nil {
                MusicValueRow(title: "Sent as", value: Localized.string("Not scrobbled"))
            } else {
                MusicValueRow(title: "Sent as", value: p.cleaned.title + " - " + p.cleaned.artist + (p.cleaned.album.isEmpty ? "" : " - " + p.cleaned.album))
            }
            if !p.chips.isEmpty { MusicNote(text: p.chips.joined(separator: " · ")) }
            MusicNote(text: p.statusLine)
            ForEach(p.services) { s in MusicNote(text: Localized.string("%1$@ receives: %2$@", s.name, s.title.map { "\(s.artist ?? "") - \($0)" } ?? Localized.string("nothing"))) }
            if let track = current {
                if editing { editor(track: track) } else {
                    MusicSettingsActions {
                        Button("Edit this track") {
                            editArtist = p.cleaned.artist; editTitle = p.cleaned.title; editAlbum = p.cleaned.album; editSkip = false; editing = true
                        }.accessibilityLabel(Text("Edit what this track scrobbles as")).atlas("control.music.settingsScrobblingEditWhatThisTrackScrobblesAs")
                        if let i = p.cleaned.editIndex { Button("Remove edit") { store.config.clean.edits.remove(at: i) }.accessibilityLabel(Text("Remove the edit for this track")).atlas("control.music.settingsScrobblingRemoveTheEditForThisTrack") }
                    }
                }
            }
        }
    }

    private func editor(track: MusicTrack) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            MusicFieldRow(title: "Artist", text: $editArtist)
            MusicFieldRow(title: "Title", text: $editTitle)
            MusicFieldRow(title: "Album", text: $editAlbum)
            MusicToggleRow(title: "Don't scrobble this track", info: "Used every time this track plays. Leave a field empty to keep the source's.", isOn: $editSkip)
            MusicSettingsActions {
                Button("Cancel") { editing = false }.atlas("control.music.settingsScrobblingCancel")
                Button("Save") {
                    var edits = store.config.clean.edits.filter { $0.key != track.uid }
                    edits.insert(ScrobbleEdit(key: track.uid, artist: editArtist, title: editTitle, album: editAlbum, skip: editSkip), at: 0)
                    store.config.clean.edits = edits
                    editing = false
                }.atlas("control.music.settingsScrobblingSave")
            }
        }
    }
}
