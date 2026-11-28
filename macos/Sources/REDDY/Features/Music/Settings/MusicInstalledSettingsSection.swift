import SwiftUI
import UniformTypeIdentifiers

/// What the person must see before a plugin is installed.
struct MusicPluginPreview: Identifiable {
    let id = UUID()
    var name: String; var version: String; var author: String; var summary: String; var permissions: [String]; var provides: [String]
    var source: URL
}

/// Installing a plugin: from a file or folder on this Mac, or from an https address. The manifest and its permissions are shown first, and
/// the plugin is never switched on by installing it.
@MainActor @Observable
final class MusicPluginInstallFlow {
    private(set) var preview: MusicPluginPreview?
    private(set) var error: String?
    private(set) var busy = false
    @ObservationIgnored private let plugins: MusicPluginManager
    @ObservationIgnored private let describeError: @MainActor (Error) -> String
    @ObservationIgnored private var decision: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var local: URL?
    @ObservationIgnored private var scoped = false

    init(plugins: MusicPluginManager, describeError: @escaping @MainActor (Error) -> String) {
        self.plugins = plugins; self.describeError = describeError
    }

    func startLocal(_ url: URL) async {
        finishLocal(); error = nil
        scoped = url.startAccessingSecurityScopedResource()
        do { preview = try await MusicPluginBridge.preview(plugins, source: url); local = url }
        catch { self.error = describeError(error); finishLocal() }
    }

    func startRemote(_ url: URL) async {
        guard url.scheme?.lowercased() == "https" else { error = Localized.string("Enter an https address."); return }
        error = nil; busy = true
        do {
            _ = try await plugins.install(fromRemote: url) { [self] manifest in
                preview = MusicPluginBridge.preview(manifest, source: url)
                return await withCheckedContinuation { decision = $0 }
            }
            preview = nil
        } catch MusicError.cancelled { preview = nil } catch { preview = nil; self.error = describeError(error) }
        busy = false
    }

    func confirm() {
        if let d = decision { decision = nil; d.resume(returning: true); return }
        guard let local else { return }
        do { _ = try plugins.install(from: local); preview = nil } catch { self.error = describeError(error); preview = nil }
        finishLocal()
    }

    func cancel() {
        if let d = decision { decision = nil; d.resume(returning: false) }
        preview = nil; finishLocal()
    }

    private func finishLocal() {
        if scoped, let local { local.stopAccessingSecurityScopedResource() }
        scoped = false; local = nil
    }
}

/// One entry of the installed list. Built-in sources and plugins are described the same way.
private struct MusicInstalledItem: Identifiable {
    let id: String
    let name: String
    let version: String
    let isPlugin: Bool
    let tags: [String]
    let enabled: Bool
    let status: MusicSourceStatus
    let summary: String
    let privacy: String
    let permissions: [String]
    let error: String?
    let provider: (any MusicProvider)?
}

/// The installed sources: built-in providers and plugins in one list (name, version, kind, what it does, a switch, a one-word status, details),
/// the way to add a plugin, and the optional address of a plugin index.
struct MusicInstalledSettingsSection: View {
    let hub: MusicHub
    /// Opens the first-run setup again; the page closes itself when it is a sheet.
    var onRunSetup: () -> Void = {}

    @State private var flow: MusicPluginInstallFlow
    @State private var updates: MusicPluginUpdates
    @State private var signedIn: [String: Bool] = [:]
    @State private var fields: [String: String] = [:]
    @State private var status: [String: String] = [:]
    @State private var spotifyRedirect = ""
    @State private var showAdd = false
    @State private var showHow = false
    @State private var importing = false
    @State private var address = ""
    @State private var logFor: String?

    init(hub: MusicHub, onRunSetup: @escaping () -> Void = {}) {
        self.hub = hub
        self.onRunSetup = onRunSetup
        _flow = State(initialValue: MusicPluginInstallFlow(plugins: hub.plugins, describeError: { [hub] in hub.loadError($0) }))
        _updates = State(initialValue: MusicExtras.shared.updates(for: hub))
    }

    private var registry: MusicRegistry { hub.registry }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicTokens.settingsGroupSpacing) {
            installedGroup
            setupGroup
        }
        .task(id: registry.enabled) {
            await refreshSignIn()
            if let s = registry.provider(id: "spotify") as? SpotifyProvider { spotifyRedirect = await s.redirectURI }
        }
        .sheet(isPresented: $showAdd) { addSheet }
        .sheet(item: Binding(get: { flow.preview }, set: { if $0 == nil { flow.cancel() } })) { confirmSheet($0) }
        .sheet(isPresented: Binding(get: { logFor != nil }, set: { if !$0 { logFor = nil } })) { logSheet }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item, .folder]) { r in
            if case .success(let url) = r { Task { await flow.startLocal(url) } }
        }
    }

    // MARK: the list

    private var items: [MusicInstalledItem] {
        let builtIn = registry.all.filter { $0.info.kind == .builtIn }.map { p in
            var tags = ["Built-in"]
            if !p.capabilities.isDisjoint(with: .metadata) { tags.append("Metadata") }
            if p.capabilities.contains(.audio) { tags.append("Audio") }
            if p.capabilities.contains(.lyrics) { tags.append("Lyrics") }
            if p.capabilities.contains(.scrobble) { tags.append("Scrobble") }
            let on = registry.isEnabled(p.id)
            let needs = (p.info.requiresSignIn || MusicCredentialBridge.hasFields(p.id)) && !(signedIn[p.id] ?? false)
            return MusicInstalledItem(id: p.id, name: p.info.name, version: p.info.version, isPlugin: false, tags: tags, enabled: on,
                                      status: !on ? .off : (needs ? .needsSignIn : .on), summary: p.info.summary, privacy: p.info.privacyNote,
                                      permissions: [], error: nil, provider: p)
        }
        let plugins = hub.plugins.plugins.map { e in
            let tags = ["Plugin"] + e.manifest.capabilities.map { $0 == .scrobble ? "Scrobble" : $0.rawValue.capitalized }
            return MusicInstalledItem(id: e.id, name: e.manifest.name, version: e.manifest.version, isPlugin: true, tags: tags, enabled: e.enabled,
                                      status: e.errorMessage != nil ? .attention : (e.enabled ? .on : .off), summary: e.manifest.summary, privacy: "",
                                      permissions: MusicPluginBridge.describe(e.manifest.permissions), error: e.errorMessage, provider: nil)
        }
        return builtIn + plugins
    }

    private var installedGroup: some View {
        let list = items
        return MusicSettingsGroup(title: "Installed", count: MusicSettingsCount.text(list.filter(\.enabled).count, of: list.count),
                                  footer: "Sources are on by default except Local files. Switch any of them off here. A new plugin stays off until you turn it on.") {
            if list.isEmpty { MusicNote(text: "No sources are installed.") }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                    MusicSourceRow(name: item.name, version: item.version, tags: item.tags, status: item.status,
                                   isOn: Binding(get: { item.enabled }, set: { toggle(item, $0) }), first: i == 0) { details(item) }
                }
            }
            MusicSettingsActions {
                Button("Add plugin…") { address = ""; showAdd = true }.musicButton(.primary).accessibilityLabel(Text("Add a plugin")).atlas("control.music.settingsPluginsSourcesAddAPlugin")
                Button("How plugins work") { showHow = true }.musicButton(.tertiary)
                    .popover(isPresented: $showHow, arrowEdge: .bottom) { howPlugins }.atlas("control.music.settingsPluginsSourcesHowPluginsWork")
            }
            MusicSettingsDisclosure(title: "Advanced") {
            }
            if let e = flow.error { MusicNote(text: e, tone: .bad) }
        }
    }

    private func toggle(_ item: MusicInstalledItem, _ on: Bool) {
        if item.isPlugin { MusicPluginBridge.setEnabled(hub.plugins, id: item.id, on) } else { registry.setEnabled(on, id: item.id) }
    }

    @ViewBuilder private func details(_ item: MusicInstalledItem) -> some View {
        if !item.summary.isEmpty { Text(verbatim: item.summary) }
        if !item.privacy.isEmpty { Text(verbatim: item.privacy) }
        if item.isPlugin {
            Text(verbatim: item.permissions.isEmpty ? Localized.string("Asks for nothing beyond playing and showing music.") : Localized.string("Can reach: %@", item.permissions.joined(separator: ", ")))
            if let e = item.error { Text(verbatim: e).foregroundStyle(ColorTokens.danger) }
            HStack(spacing: Spacing.sm) {
                Button("Update") { Task { await updateOne(item.id) } }.disabled(updates.isChecking)
                    .accessibilityLabel(Text(verbatim: Localized.string("Check %@ for an update", item.name))).atlas("control.music.settingsPluginsSourcesUpdate")
                Button("Logs") { logFor = item.id }.accessibilityLabel(Text(verbatim: Localized.string("Show the log of %@", item.name))).atlas("control.music.settingsPluginsSourcesLogs")
                Button("Remove", role: .destructive) { MusicPluginBridge.remove(hub.plugins, id: item.id) }.musicButton(.destructive, size: .compact)
                    .accessibilityLabel(Text(verbatim: Localized.string("Remove %@", item.name))).atlas("control.music.settingsPluginsSourcesRemove")
            }
            .musicButton(.secondary, size: .compact)
        } else if let p = item.provider, item.enabled, p.info.requiresSignIn || MusicCredentialBridge.hasFields(p.id) {
            signIn(p)
        }
    }

    private func updateOne(_ id: String) async {
        await updates.check()
        if let o = updates.offers.first(where: { $0.id == id }) { await updates.beginUpdate(o) }
    }

    private var setupGroup: some View {
        MusicSettingsGroup(title: "Setup") {
            MusicButtonRow(title: "Source setup", button: "Run again", action: onRunSetup)
        }
    }

    private var howPlugins: some View {
        MusicDetailsPopover(title: "How plugins work") {
            Text("A plugin adds a music source: search and browse, audio, lyrics or scrobbling.")
            Text("It is a small JavaScript file with a manifest. It runs in a sandbox and can only do what you approve.")
            Text("Permissions are network (listed addresses only), storage, cryptography and sign-in. You see them before it is installed.")
            Text("Installing never turns a plugin on. Plugins written for other apps cannot be loaded as they are.")
        }
    }

    // MARK: sign in

    @ViewBuilder private func signIn(_ p: any MusicProvider) -> some View {
        let id = p.id
        let signed = signedIn[id] ?? false
        if id == "spotify", !spotifyRedirect.isEmpty {
            Text(verbatim: Localized.string("Add this redirect URI to your Spotify app: %@", spotifyRedirect)).textSelection(.enabled)
        }
        ForEach(MusicCredentialBridge.fieldNames(id), id: \.self) { name in
            SecureField(name, text: Binding(get: { fields[id + name] ?? "" }, set: { fields[id + name] = $0 })).textFieldStyle(.roundedBorder)
                .accessibilityLabel(Text(verbatim: "\(p.info.name) \(name)"))
        }
        HStack(spacing: Spacing.sm) {
            if signed {
                Button("Sign out") { Task { await p.signOut(); await refreshSignIn() } }.accessibilityLabel(Text(verbatim: Localized.string("Sign out of %@", p.info.name))).atlas("control.music.settingsPluginsSourcesSignOut")
            } else {
                Button((MusicCredentialBridge.hasFields(id) ? "Save and sign in" : "Sign in").loc) { Task { await doSignIn(p) } }
                    .accessibilityLabel(Text(verbatim: Localized.string("Sign in to %@", p.info.name))).atlas("control.music.settingsPluginsSourcesSaveAndSignIn")
            }
        }
        .musicButton(.secondary, size: .compact)
        if let s = status[id] { Text(verbatim: s).foregroundStyle(ColorTokens.danger) }
    }

    private func refreshSignIn() async {
        var out: [String: Bool] = [:]
        for p in registry.all { out[p.id] = await p.isSignedIn }
        signedIn = out
    }

    private func doSignIn(_ p: any MusicProvider) async {
        status[p.id] = nil
        let values = MusicCredentialBridge.fieldNames(p.id).map { fields[p.id + $0] ?? "" }
        if !values.isEmpty {
            guard values.allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { status[p.id] = Localized.string("Fill in every field first."); return }
            do { try await MusicCredentialBridge.save(p, values: values.map { $0.trimmingCharacters(in: .whitespaces) }) }
            catch { status[p.id] = hub.loadError(error); return }
            for n in MusicCredentialBridge.fieldNames(p.id) { fields[p.id + n] = nil }   // the secret is not kept in memory longer than needed
        }
        do { try await p.signIn() } catch where !(error is CancellationError) { status[p.id] = hub.loadError(error) } catch {}
        await refreshSignIn()
    }

    // MARK: adding a plugin

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Add a plugin").font(Typography.title)
            Text("You see its manifest and permissions before anything is installed. It stays off until you turn it on.").font(Typography.body).foregroundStyle(ColorTokens.textSecondary)
            TextField("https://…", text: $address).textFieldStyle(.roundedBorder).accessibilityLabel(Text("Plugin address"))
            if let e = flow.error { MusicNote(text: e, tone: .bad) }
            HStack {
                Button("Choose file or folder…") { showAdd = false; importing = true }.musicButton().accessibilityLabel(Text("Install a plugin from a file")).atlas("control.music.settingsPluginsSourcesInstallAPluginFromAFile")
                Spacer()
                Button("Cancel") { showAdd = false }.musicButton().keyboardShortcut(.cancelAction).atlas("control.music.settingsPluginsSourcesCancel")
                Button("Review") {
                    guard let u = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
                    showAdd = false
                    Task { await flow.startRemote(u) }
                }
                .musicButton(.primary).keyboardShortcut(.defaultAction).disabled(address.isEmpty)
                .accessibilityLabel(Text("Review plugin from address")).atlas("control.music.settingsPluginsSourcesReviewPluginFromAddress")
            }
        }
        .padding(Spacing.xl).frame(width: MusicTokens.setupCardWidth)
    }

    private func confirmSheet(_ p: MusicPluginPreview) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Install this plugin?").font(Typography.title)
            Text(verbatim: "\(p.name) \(p.version)" + (p.author.isEmpty ? "" : " " + Localized.string("by %@", p.author))).font(Typography.bodyMedium)
            if !p.summary.isEmpty { Text(verbatim: p.summary).font(Typography.body).foregroundStyle(ColorTokens.textSecondary) }
            if !p.provides.isEmpty { MusicNote(text: Localized.string("Provides: %@", p.provides.joined(separator: ", "))) }
            Text("It asks for permission to").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
            if p.permissions.isEmpty { Text("Nothing beyond playing and showing music.").font(Typography.body) }
            ForEach(p.permissions, id: \.self) { Label($0, systemImage: "network").font(Typography.body) }
            Text(verbatim: Localized.string("Source: %@", p.source.isFileURL ? p.source.lastPathComponent : p.source.absoluteString)).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary).lineLimit(2)
            Text("It stays off after installing. You turn it on in the list.").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
            HStack {
                Spacer()
                Button("Cancel") { flow.cancel() }.musicButton().keyboardShortcut(.cancelAction).atlas("control.music.settingsPluginsSourcesCancel")
                Button("Install") { flow.confirm() }.musicButton(.primary).keyboardShortcut(.defaultAction).atlas("control.music.settingsPluginsSourcesInstall")
            }
        }
        .padding(Spacing.xl).frame(width: MusicTokens.setupCardWidth)
    }

    private var logSheet: some View {
        let lines = logFor.map { MusicPluginBridge.log(hub.plugins, id: $0) } ?? []
        return VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Plugin log").font(Typography.title)
            ScrollView { Text(verbatim: lines.isEmpty ? Localized.string("Nothing logged.") : lines.joined(separator: "\n")).font(Typography.mono).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: MusicTokens.previewArtwork * 3)
            HStack { Spacer(); Button("Close") { logFor = nil }.musicButton().keyboardShortcut(.cancelAction).atlas("control.music.settingsPluginsSourcesClose") }
        }
        .padding(Spacing.xl).frame(width: MusicTokens.setupCardWidth)
    }
}

/// The only place that calls the providers' credential setters, so a signature change is a one-spot fix.
@MainActor enum MusicCredentialBridge {
    static func fieldNames(_ providerID: String) -> [String] {
        switch providerID {
        case "spotify": ["Client ID", "Client secret"]
        case "listenbrainz": ["User token"]
        case "lastfm": ["API key", "Shared secret", "Session key"]
        default: []
        }
    }
    static func hasFields(_ providerID: String) -> Bool { !fieldNames(providerID).isEmpty }

    static func save(_ p: any MusicProvider, values: [String]) async throws {
        switch p {
        case let s as SpotifyProvider:
            if values.count >= 2 { _ = await s.setAppKeys(clientID: values[0], secret: values[1]) }
            else if let v = values.first { await s.setClientID(v) }
        case let l as ListenBrainzProvider: if let v = values.first { try await l.setToken(v) }
        case let f as LastFMProvider: if values.count >= 3 { await f.setCredentials(apiKey: values[0], secret: values[1], sessionKey: values[2]) }
        default: break
        }
    }
}

/// The only place that talks to `MusicPluginManager`.
@MainActor enum MusicPluginBridge {
    static func describe(_ p: MusicPluginPermissions) -> [String] {
        var out: [String] = []
        if p.network { out.append(Localized.string("Network: %@", p.networkHosts.joined(separator: ", "))) }
        if p.storage { out.append(Localized.string("Private storage")) }
        if p.crypto { out.append(Localized.string("Cryptography")) }
        if p.signIn { out.append(Localized.string("Sign in")) }
        return out
    }
    static func preview(_ mf: MusicPluginManifest, source: URL) -> MusicPluginPreview {
        MusicPluginPreview(name: mf.name, version: mf.version, author: mf.author, summary: mf.summary, permissions: describe(mf.permissions),
                           provides: mf.capabilities.map { Localized.string($0.rawValue.capitalized) }, source: source)
    }
    static func preview(_ m: MusicPluginManager, source: URL) async throws -> MusicPluginPreview {
        preview(try MusicPluginBundle.load(from: source).manifest, source: source)
    }
    static func setEnabled(_ m: MusicPluginManager, id: String, _ on: Bool) { m.setEnabled(on, id: id) }
    static func remove(_ m: MusicPluginManager, id: String) { m.remove(id: id) }
    static func log(_ m: MusicPluginManager, id: String) -> [String] { m.logs(for: id).map { "[\($0.level)] \($0.message)" } }
}
