import SwiftUI
import UniformTypeIdentifiers

/// Everything about one playlist: name, login, guide, per-playlist playback behaviour, headers, and a channel health check.
struct PlaylistDetailView: View {
    let sourceID: UUID
    @Environment(AppState.self) private var state
    @Environment(AppSettings.self) private var settings
    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var guideURL = ""
    @State private var pickGuide = false
    @State private var userAgent = ""
    @State private var extraHeaders = ""
    @State private var headerProblems: [String] = []
    @State private var shift = 0
    @State private var clock = 0
    @State private var buffering: BufferingMode?
    @State private var engine: PlaybackEnginePreference?
    @State private var message: String?
    @State private var confirmDelete = false
    @State private var showLogin = false

    private var source: PlaylistSource? { state.sources.first { $0.id == sourceID } }

    var body: some View {
        Form {
            if let s = source {
                Section {
                    TextField("Name", text: $name).onSubmit { rename() }
                    LabeledContent("Type", value: s.type.title)
                    LabeledContent("Address", value: s.baseURL).lineLimit(1).truncationMode(.middle)
                    Toggle("Enabled", isOn: Binding(get: { s.enabled }, set: { on in try? container?.sources.setEnabled(sourceID, on); state.reload() }))
                    if state.activeSourceID != sourceID, s.enabled { Button("Make This the Active Playlist") { state.switchPlaylist(sourceID) } }
                    if s.type != .m3uLocal { Button("Change Login or Address…") { showLogin = true } }
                }.listRowBackground(ColorTokens.surface)
                Section("Status") {
                    LabeledContent("Last update", value: s.lastSync.map { $0.formatted(.relative(presentation: .named)) } ?? "Never")
                    if let p = state.syncProgress[sourceID], p.state.isBusy { Label(p.state.label, systemImage: "arrow.triangle.2.circlepath") }
                    else if case .failed(let m)? = state.syncProgress[sourceID]?.state { Label(m, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout) }
                    Button("Refresh Now") { state.sync(sourceID, forceGuide: true) }
                }.listRowBackground(ColorTokens.surface)
                Section {
                    TextField("Guide (XMLTV) address", text: $guideURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().onSubmit { saveGuide() }
                    Button { pickGuide = true } label: { Label("Use a Guide File…", systemImage: "doc") }
                    Stepper(value: $shift, in: -720...720, step: 15) { Text("Guide time shift: \(shiftLabel(shift))") }
                        .onChange(of: shift) { _, v in settings.setGuideShiftMinutes(v, for: sourceID) }
                } header: { Text("Guide") } footer: {
                    Text("If programmes appear an hour early or late, shift the guide. It applies from the next guide download.")
                }.listRowBackground(ColorTokens.surface)
                Section {
                    Stepper(value: $clock, in: -720...720, step: 15) { Text("Catch-up clock: \(shiftLabel(clock))") }
                        .onChange(of: clock) { _, v in settings.setCatchupOffsetMinutes(v, for: sourceID) }
                    if AppEngineChoice.available {
                        Picker("Player", selection: $engine) {
                            Text("Use the app setting").tag(PlaybackEnginePreference?.none)
                            ForEach(PlaybackEnginePreference.allCases) { Text($0.rawValue).tag(PlaybackEnginePreference?.some($0)) }
                        }
                        .onChange(of: engine) { _, v in settings.setEngineOverride(v, for: sourceID) }
                    }
                    Picker("Buffering", selection: $buffering) {
                        Text("Use the app setting").tag(BufferingMode?.none)
                        ForEach(BufferingMode.allCases) { Text($0.rawValue).tag(BufferingMode?.some($0)) }
                    }
                    .onChange(of: buffering) { _, v in settings.setBufferingOverride(v, for: sourceID) }
                } header: { Text("Playback for this playlist") } footer: {
                    Text("Catch-up clock: if archive programmes start at the wrong point, correct the difference between the provider's clock and yours.")
                }.listRowBackground(ColorTokens.surface)
                Section {
                    TextField("User-Agent", text: $userAgent).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Menu("Use a Common One") { ForEach(SourceHeaders.presets, id: \.name) { p in Button(p.name) { userAgent = p.value } } }
                    TextEditor(text: $extraHeaders).font(.system(.footnote, design: .monospaced)).frame(minHeight: 70).textInputAutocapitalization(.never).autocorrectionDisabled()
                    ForEach(headerProblems, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                    Button("Save Headers") { saveHeaders() }
                } header: { Text("Connection headers") } footer: {
                    Text("Only needed when a provider answers certain players. One header per line (Name: value). Logins and cookies can't be set here.")
                }.listRowBackground(ColorTokens.surface)
                Section { NavigationLink("Check Channels") { PlaylistHealthView(sourceID: sourceID) } }.listRowBackground(ColorTokens.surface)
                Section { Button("Delete Playlist…", role: .destructive) { confirmDelete = true } }.listRowBackground(ColorTokens.surface)
                if let message { Section { Text(message).font(.callout).foregroundStyle(.secondary) }.listRowBackground(ColorTokens.surface) }
            } else { Text("This playlist no longer exists.") }
        }
        .fileImporter(isPresented: $pickGuide, allowedContentTypes: [.xml, .gzip, .data]) { result in
            if case .success(let url) = result { importGuide(url) }
        }
        .navigationTitle(source?.name ?? "Playlist").themed(source?.name ?? "Playlist").navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .confirmationDialog("Delete this playlist?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) { try? container?.sources.remove(sourceID); state.reload(); dismiss() }
        } message: { Text("Its channels, movies and series are removed from this device, along with the saved login. Favourites of its items go too.") }
        .sheet(isPresented: $showLogin) { if let s = source { EditLoginSheet(source: s) } }
    }

    private func shiftLabel(_ m: Int) -> String { m == 0 ? "none" : String(format: "%@%d h %02d min", m < 0 ? "−" : "+", abs(m) / 60, abs(m) % 60) }

    private func load() {
        guard let s = source else { return }
        name = s.name; guideURL = s.epgURL ?? ""
        shift = settings.guideShiftMinutes(for: sourceID); clock = settings.catchupOffsetMinutes(for: sourceID)
        buffering = settings.bufferingOverride(for: sourceID)
        engine = settings.engineOverride(for: sourceID)
        if let h = container?.sources.headers(for: sourceID) {
            userAgent = h.userAgent ?? ""
            extraHeaders = h.extra.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        }
    }

    private func rename() { try? container?.sources.rename(sourceID, to: name); state.reload() }

    private func importGuide(_ url: URL) {
        do { try container?.sources.setGuideFile(sourceID, fileURL: url); state.reload(); load(); state.sync(sourceID, forceGuide: true); message = "Guide file imported." }
        catch { message = (error as? LocalizedError)?.errorDescription ?? "That file can't be used." }
    }

    private func saveGuide() {
        do { try container?.sources.setGuideURL(sourceID, url: guideURL.trimmingCharacters(in: .whitespaces).isEmpty ? nil : guideURL); state.reload(); message = "Guide address saved. Refresh to download it." }
        catch { message = (error as? LocalizedError)?.errorDescription ?? "That address can't be used." }
    }

    private func saveHeaders() {
        headerProblems = SourceHeaders.parse(extraHeaders).problems
        let ua = userAgent.trimmingCharacters(in: .whitespaces)
        container?.sources.setHeaders(userAgent: ua.isEmpty ? nil : ua, extraText: extraHeaders, for: sourceID)
        message = headerProblems.isEmpty ? "Headers saved. They are used the next time this playlist connects." : "Saved, but some lines were skipped."
    }
}

private struct EditLoginSheet: View {
    let source: PlaylistSource
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var address = ""
    @State private var error: String?
    @State private var authKind: HTTPAuthKind = .none
    @State private var authUser = ""
    @State private var authSecret = ""

    var body: some View {
        NavigationStack {
            Form {
                if source.type.hasLogin {
                    Section {
                        if source.type != .plex { TextField(source.type == .stalker ? "MAC address" : "Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled() }
                        SecureField(source.type == .plex ? "Access token" : "Password", text: $password)
                    }.listRowBackground(ColorTokens.surface)
                } else {
                    Section { TextField("Playlist address", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled() }.listRowBackground(ColorTokens.surface)
                    Section {
                        Picker("Sign-in", selection: $authKind) { ForEach(HTTPAuthKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        if authKind == .basic { TextField("Username", text: $authUser).textInputAutocapitalization(.never).autocorrectionDisabled() }
                        if authKind != .none { SecureField(authKind == .basic ? "Password" : "Token", text: $authSecret) }
                    } header: { Text("Link sign-in") } footer: { Text("Sent with every request to this link, and kept encrypted with its address. Leave the password or token blank to keep the saved one.") }.listRowBackground(ColorTokens.surface)
                }
                if let error { Section { Text(error).foregroundStyle(.orange).font(.callout) }.listRowBackground(ColorTokens.surface) }
            }
            .navigationTitle("Change Login").themed("Change Login").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(source.type.hasLogin ? password.isEmpty && !(source.type == .stalker && !username.isEmpty) : address.isEmpty) }
            }
        }
        .onAppear { if source.type == .m3uRemote, let m = container?.sources { let a = m.httpAuth(for: source.id); authKind = a.kind; authUser = a.username } }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        guard let m = container?.sources else { return }
        do {
            if source.type.hasLogin { try m.updateXtreamLogin(source.id, username: username, password: password) }
            else {
                try m.updateM3UAddress(source.id, url: address)
                let current = m.httpAuth(for: source.id)
                if authKind == .none || !authSecret.isEmpty || authKind != current.kind { try m.setHTTPAuth(source.id, kind: authKind, username: authUser, secret: authSecret) }
            }
            state.reload(); state.sync(source.id); dismiss()
        } catch { self.error = CredentialRedactor.redact((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
    }
}

/// Finds channels that don't answer, so they can be hidden. Checks a sample so it finishes quickly.
struct PlaylistHealthView: View {
    let sourceID: UUID
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @State private var results: [ChannelHealthResult] = []
    @State private var running = false
    @State private var done = 0
    @State private var total = 0
    @State private var hidden = 0
    private let sample = 60

    var body: some View {
        List {
            Section {
                Button { run() } label: { HStack { if running { ProgressView() }; Text(running ? "Checking \(done) of \(total)…" : "Check \(sample) Channels") } }.disabled(running)
            } footer: { Text("Asks each channel for its first few kilobytes. A channel that stays silent isn't necessarily dead: some providers start slowly or allow one stream at a time.") }.listRowBackground(ColorTokens.surface)
            if !results.isEmpty {
                let dead = results.filter { $0.health.isDead }
                Section("Summary") {
                    LabeledContent("Working", value: "\(results.filter { if case .ok = $0.health { true } else { false } }.count)")
                    LabeledContent("Slow", value: "\(results.filter { if case .slow = $0.health { true } else { false } }.count)")
                    LabeledContent("No answer", value: "\(results.filter { $0.health == .silent }.count)")
                    LabeledContent("Dead", value: "\(dead.count)")
                    if !dead.isEmpty { Button("Hide \(dead.count) Dead Channel\(dead.count == 1 ? "" : "s")", role: .destructive) { hide(dead) } }
                    if hidden > 0 { Label("Hid \(hidden) channels.", systemImage: "checkmark.circle").foregroundStyle(.green) }
                }.listRowBackground(ColorTokens.surface)
                Section("Dead channels") {
                    ForEach(dead) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.name)
                            if case .dead(let why) = r.health { Text(why).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }.listRowBackground(ColorTokens.surface)
            }
        }
        .navigationTitle("Check Channels").themed("Check Channels")
    }

    private func run() {
        guard let c = container else { return }
        running = true; results = []; hidden = 0; done = 0
        Task {
            let list = await Task.detached { Array(((try? c.catalog.channels({ var q = ChannelQuery(); q.sourceID = sourceID; q.collapseVariants = false; q.limit = 60; return q }())) ?? []).prefix(60)) }.value
            total = list.count
            results = await c.channelHealth.check(list) { d, t in Task { @MainActor in done = d; total = t } }
            running = false
        }
    }

    private func hide(_ dead: [ChannelHealthResult]) {
        for r in dead { try? container?.favoritesRepo.hide(r.channelID, kind: "channel") }
        hidden = dead.count; state.catalogVersion += 1
        results.removeAll { $0.health.isDead }
    }
}
