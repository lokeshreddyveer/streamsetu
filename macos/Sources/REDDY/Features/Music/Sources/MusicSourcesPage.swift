import SwiftUI

/// The added-sources settings: addons the person added, how often they are asked, and the form to add one.
/// It uses the store of `hub.resolver.chain` when the hub has one, so the screen and the player always agree on the list.
struct MusicSourcesSettingsSection: View {
    let hub: MusicHub
    var body: some View { MusicSourcesPage(store: hub.resolver.chain?.store ?? AddonStore.shared).atlas("control.music.sources").atlasScreen("screen.music.sources") }
}

struct MusicSourcesPage: View {
    @Bindable var store: AddonStore
    @State private var address = ""
    @State private var token = ""
    @State private var name = ""
    @State private var ownServer = false
    @State private var report: AddonTestReport?
    @State private var message: String?
    @State private var messageIsError = false
    @State private var working = false
    @State private var removing: AddonConfig?

    var body: some View {
        VStack(alignment: .leading, spacing: MusicTokens.settingsGroupSpacing) {
            listGroup
            addGroup
        }
        .confirmationDialog("Remove this addon?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { a in
            Button(Localized.string("Remove %@", a.displayName), role: .destructive) { store.remove(a.id) }.atlas("control.music.sourcesRemove")
            Button("Cancel", role: .cancel) {}.atlas("control.music.sourcesCancel")
        } message: { _ in Text("Its address and access token are deleted from this Mac.") }
    }

    // MARK: list

    private var listGroup: some View {
        let ids = store.addons.map { $0.id.uuidString }
        let on = store.addons.filter(\.enabled).count
        return MusicSettingsGroup(title: "Added sources", count: store.addons.isEmpty ? nil : MusicSettingsCount.text(on, of: store.addons.count),
                                  footer: "Addons are web servers you add yourself. The first one at the top that has the song at the best quality is used.") {
            MusicPickerRow(title: "Use addons", info: "Addons can be slow, so choose when they are asked. The quality itself is set under Playback.",
                           selection: $store.qualityPolicy, options: AddonQualityPolicy.allCases.map { ($0, $0.title) })
            MusicToggleRow(title: "Check file length first", info: "Asks the addon how big the file is before playing it, to skip 30 second previews listed as full songs.", isOn: $store.checkFileLength)
            if store.addons.isEmpty { MusicNote(text: "No addons added.") }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(store.addons.enumerated()), id: \.element.id) { i, a in
                    MusicSourceRow(name: a.displayName, status: status(a), isOn: Binding(get: { a.enabled }, set: { store.setEnabled($0, id: a.id) }),
                                   reorder: MusicReorder(id: a.id.uuidString,
                                                         drop: { dragged in
                                                             guard let src = ids.firstIndex(of: dragged), let dst = ids.firstIndex(of: a.id.uuidString) else { return }
                                                             store.move(from: IndexSet(integer: src), to: dst > src ? dst + 1 : dst)
                                                         },
                                                         step: { shift(a, by: $0) }),
                                   first: i == 0) { details(a) }
                }
            }
        }
    }

    @ViewBuilder private func details(_ a: AddonConfig) -> some View {
        Text(verbatim: a.host + (a.ownServer ? " · " + Localized.string("your own server") : ""))
        if a.health.state != .unknown { Text(verbatim: healthLine(a.health)) }
        if !a.canStream { Text("This addon can search but does not offer streams, so it is not used.") }
        if a.qualityOptions.count >= 2 {
            Picker("Addon quality", selection: Binding(get: { a.activeQuality ?? "" }, set: { store.setPickedQuality($0, id: a.id) })) {
                ForEach(a.qualityOptions, id: \.value) { Text(verbatim: $0.label).tag($0.value) }
            }
            .controlSize(.small).accessibilityLabel(Text(verbatim: Localized.string("Quality offered by %@", a.displayName))).atlas("control.music.sourcesAddonQuality")
        }
        HStack(spacing: Spacing.sm) {
            Button("Test") { Task { await store.test(a.id) } }.disabled(store.busy.contains(a.id)).accessibilityLabel(Text(verbatim: Localized.string("Test %@", a.displayName))).atlas("control.music.sourcesTest")
            Button("Remove", role: .destructive) { removing = a }.accessibilityLabel(Text(verbatim: Localized.string("Remove %@", a.displayName))).atlas("control.music.sourcesRemove")
        }
        .musicButton(.secondary, size: .compact)
    }

    private func status(_ a: AddonConfig) -> MusicSourceStatus {
        if store.busy.contains(a.id) { return .note(Localized.string("Testing")) }
        if !a.enabled { return .off }
        switch a.health.state {
        case .unknown, .ok: return .on
        case .unreachable: return .unreachable
        case .rejected: return .attention
        }
    }

    private func shift(_ a: AddonConfig, by d: Int) {
        guard let i = store.addons.firstIndex(where: { $0.id == a.id }) else { return }
        let j = i + d
        guard store.addons.indices.contains(j) else { return }
        store.move(from: IndexSet(integer: i), to: d > 0 ? j + 1 : j)
    }

    private func healthLine(_ h: AddonHealth) -> String {
        var s = h.detail
        if h.state == .ok, let ms = h.latencyMs { s += " · \(ms) ms" }
        if h.state == .unreachable { s += " " + Localized.string("It stays on; it is tried again on the next song.") }
        if let d = h.checkedAt { s += " · " + Localized.string("checked") + " " + d.formatted(.relative(presentation: .named)) }
        return s
    }

    // MARK: add

    private var addGroup: some View {
        MusicSettingsGroup(title: "Add a source", footer: "Only add addons you trust. An addon sees the title and artist of each song it is asked about, and your internet address.") {
            MusicFieldRow(title: "Address", prompt: "https://my-addon.example.com", text: $address)
                .onChange(of: address) { _, _ in report = nil; message = nil }
            MusicFieldRow(title: "Name", prompt: "Optional", text: $name)
            MusicFieldRow(title: "Access token", prompt: "Optional", secret: true, text: $token)
            MusicToggleRow(title: "My own server", info: "Tick only for a server you run on this Mac or your home network. Other private addresses are blocked, and public addresses must use https.", isOn: $ownServer)
            MusicSettingsActions {
                Button("Test") { Task { await runTest() } }.disabled(address.isEmpty || working).accessibilityLabel(Text("Test this address without saving")).atlas("control.music.sourcesTestThisAddressWithoutSaving")
                Button("Add") { Task { await runAdd() } }.disabled(address.isEmpty || working).accessibilityLabel(Text("Add this addon")).atlas("control.music.sourcesAddThisAddon")
                if working { MusicLoadingIcon(size: MusicIconSize.small) }
            }
            if let m = message { MusicNote(text: m, tone: messageIsError ? .bad : .good) }
            if let r = report {
                ForEach(r.steps, id: \.self) { s in MusicNote(text: "\(s.ok ? Localized.string("OK") : Localized.string("Problem")) · \(s.name): \(s.detail)", tone: s.ok ? .normal : .warning) }
            }
        }
    }

    private func runTest() async {
        working = true; defer { working = false }
        let r = await store.test(address, ownServer: ownServer, token: token)
        report = r
        messageIsError = !r.ok
        message = r.ok ? Localized.string("Connected.") + " " + r.health.detail : (r.health.state == .unreachable ? Localized.string("Cannot reach it right now.") + " " : "") + r.health.detail
    }

    private func runAdd() async {
        working = true; defer { working = false }
        do {
            let a = try await store.add(address, label: name, token: token, ownServer: ownServer)
            message = Localized.string("Added %@.", a.displayName); messageIsError = false
            address = ""; token = ""; name = ""; ownServer = false; report = nil
        } catch {
            message = AddonProblem.classify(error).message; messageIsError = true
        }
    }
}
