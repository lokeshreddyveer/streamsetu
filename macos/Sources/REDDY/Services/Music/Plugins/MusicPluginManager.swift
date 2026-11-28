import Foundation
import Observation

// Installs, lists, enables and removes plugins. Installing only copies two checked files to disk. A plugin runs, and shows up in the registry,
// only after the person enables it; enabled plugins are re-registered at launch because that was the person's own earlier choice.

@MainActor @Observable
final class MusicPluginManager {
    struct Entry: Identifiable, Hashable, Sendable {
        let manifest: MusicPluginManifest
        var enabled = false
        /// The latest problem the plugin reported (failed to load, timed out, threw). Cleared when it is enabled again.
        var errorMessage: String?
        var id: String { manifest.id }
    }

    private(set) var plugins: [Entry] = []
    /// Folders that could not be read at the last scan, as human messages.
    private(set) var problems: [String] = []

    let directory: URL
    /// False while the app is locked or a Kids profile is on: no update check and no install from an address goes out (same switch as `MusicSourceChain.isAllowed`).
    @ObservationIgnored var isAllowed = true
    /// Optional update hook: given an installed manifest, return the address of a newer package, or nil. Nothing calls it on its own.
    @ObservationIgnored var updateSource: (@MainActor (MusicPluginManifest) async -> URL?)?

    @ObservationIgnored private let registry: MusicRegistry
    @ObservationIgnored private let transport: MusicHTTPTransport?
    @ObservationIgnored private var hosts: [String: MusicPluginHost] = [:]
    @ObservationIgnored private var registered: [String: [String]] = [:]

    private var installedDir: URL { directory.appendingPathComponent("installed", isDirectory: true) }
    private var storageDir: URL { directory.appendingPathComponent("storage", isDirectory: true) }
    private var stateURL: URL { directory.appendingPathComponent("state.json") }

    /// `transport` replaces the real network for downloads and for plugin fetches (tests); nil uses the guarded default.
    init(registry: MusicRegistry, directory: URL, transport: MusicHTTPTransport? = nil) {
        self.registry = registry; self.directory = directory; self.transport = transport
        reload()
        for id in loadEnabledIDs() where plugins.contains(where: { $0.id == id }) { enable(id) }
    }

    // MARK: listing

    func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: installedDir, withIntermediateDirectories: true)
        var found: [Entry] = []; var bad: [String] = []
        let folders = ((try? fm.contentsOfDirectory(at: installedDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
        for f in folders where (try? f.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            do {
                let b = try MusicPluginBundle.load(folder: f)
                guard b.manifest.id == f.lastPathComponent else { throw MusicError.plugin("folder name does not match the plugin id") }
                var e = Entry(manifest: b.manifest)
                e.enabled = hosts[b.manifest.id] != nil
                e.errorMessage = plugins.first { $0.id == e.id }?.errorMessage
                found.append(e)
            } catch { bad.append("\(f.lastPathComponent): \((error as? MusicError)?.errorDescription ?? "unreadable")") }
        }
        plugins = found; problems = bad
    }

    func entry(_ id: String) -> Entry? { plugins.first { $0.id == id } }

    /// The plugin's recent console output, newest last. Empty unless it is enabled.
    func logs(for id: String) -> [PluginLogRing.Entry] { hosts[id]?.logs.entries ?? [] }

    // MARK: install

    /// From a folder, `.sbplugin` zip or JSON bundle on this device. The plugin is NOT enabled.
    @discardableResult
    func install(from url: URL) throws -> MusicPluginManifest {
        let bundle = try MusicPluginBundle.load(from: url)
        try commit(bundle)
        return bundle.manifest
    }

    /// From an https address. The package is downloaded to memory and checked, then `confirm` is shown the manifest (name, permissions, hosts).
    /// Nothing touches the disk unless it returns true. The plugin is NOT enabled.
    @discardableResult
    func install(fromRemote url: URL, confirm: @MainActor (MusicPluginManifest) async -> Bool) async throws -> MusicPluginManifest {
        guard isAllowed else { throw MusicError.plugin("plugins cannot be installed right now") }
        guard url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { throw MusicError.plugin("plugin downloads must use an https address") }
        var req = URLRequest(url: url); req.timeoutInterval = 30
        req.setValue(MusicHTTP().userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await (transport ?? URLSessionTransport()).data(for: req)
        guard resp.statusCode == 200 else { throw MusicError.network("HTTP \(resp.statusCode)") }
        if let final = resp.url, final.scheme?.lowercased() != "https" { throw MusicError.plugin("the download was redirected to an insecure address") }
        let bundle = try MusicPluginBundle.load(archive: data)
        guard await confirm(bundle.manifest) else { throw MusicError.cancelled }
        try commit(bundle)
        return bundle.manifest
    }

    private func commit(_ bundle: MusicPluginBundle) throws {
        let m = bundle.manifest
        for aid in m.adapterIDs where Self.reservedIDs.contains(aid) || registry.provider(id: aid)?.info.kind == .builtIn {
            throw MusicError.plugin("the id \"\(m.id)\" is used by a built-in source")
        }
        if hosts[m.id] != nil { disable(m.id) }
        let fm = FileManager.default
        try fm.createDirectory(at: installedDir, withIntermediateDirectories: true)
        let staging = installedDir.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        let target = installedDir.appendingPathComponent(m.id, isDirectory: true)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            try bundle.manifestData.write(to: staging.appendingPathComponent(MusicPluginLimits.manifestFileName), options: .atomic)
            try Data(bundle.script.utf8).write(to: staging.appendingPathComponent(m.entry), options: .atomic)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: staging, to: target)
        } catch {
            try? fm.removeItem(at: staging)
            throw MusicError.plugin("the plugin could not be saved")
        }
        reload()
        setEnabledState(id: m.id, on: false)
    }

    static let reservedIDs: Set<String> = ["audius", "jiosaavn", "itunes", "lrclib", "listenbrainz", "lastfm", "spotify", "piped", "invidious", "youtube-music"]

    // MARK: enable / disable / remove

    /// Registers the plugin's adapters and switches them on. This is the person's act; install never does it.
    func setEnabled(_ on: Bool, id: String) { on ? enable(id) : disable(id) }

    private func enable(_ id: String) {
        guard hosts[id] == nil, let i = plugins.firstIndex(where: { $0.id == id }) else { return }
        let folder = installedDir.appendingPathComponent(id, isDirectory: true)
        do {
            let bundle = try MusicPluginBundle.load(folder: folder)
            for aid in bundle.manifest.adapterIDs where Self.reservedIDs.contains(aid) || registry.provider(id: aid)?.info.kind == .builtIn {
                throw MusicError.plugin("the id is used by a built-in source")
            }
            let sink: @Sendable (String) -> Void = { [weak self] msg in Task { @MainActor in self?.setError(msg, id: id) } }
            var http: MusicHTTP? = nil
            if let transport { var h = MusicHTTP(); h.transport = transport; http = h }
            try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
            let host = MusicPluginHost(manifest: bundle.manifest, script: bundle.script, storageURL: storageDir.appendingPathComponent("\(id).json"), http: http, errorSink: sink)
            hosts[id] = host
            let adapters = MusicPluginAdapters.make(manifest: bundle.manifest, host: host)
            for a in adapters { registry.register(a); registry.setEnabled(true, id: a.id, reason: .plugin) }
            registered[id] = adapters.map(\.id)
            plugins[i].enabled = true; plugins[i].errorMessage = nil
            setEnabledState(id: id, on: true)
            Task { [weak self] in
                do { try await host.preload() } catch { self?.setError((error as? MusicError)?.errorDescription ?? "the plugin failed to load", id: id) }
            }
        } catch {
            plugins[i].errorMessage = (error as? MusicError)?.errorDescription ?? "the plugin could not be enabled"
        }
    }

    private func disable(_ id: String) {
        for aid in registered[id] ?? [] { registry.unregister(id: aid) }
        registered[id] = nil
        hosts[id]?.shutdown(); hosts[id] = nil
        if let i = plugins.firstIndex(where: { $0.id == id }) { plugins[i].enabled = false }
        setEnabledState(id: id, on: false)
    }

    /// Deletes the plugin, its storage file and its Keychain secrets.
    func remove(id: String) {
        guard Self.isSafeFolderName(id) else { return }
        disable(id)
        let fm = FileManager.default
        try? fm.removeItem(at: installedDir.appendingPathComponent(id, isDirectory: true))
        try? fm.removeItem(at: storageDir.appendingPathComponent("\(id).json"))
        PluginKeychain.removeAll(plugin: id)
        plugins.removeAll { $0.id == id }
    }

    private static func isSafeFolderName(_ id: String) -> Bool { MusicPluginManifest.isValidID(id) }

    /// Lets the settings screen hand a token or key to a plugin that declared `signIn`; its `login()` reads it with `host.storage.getSecret`.
    @discardableResult
    func setSecret(_ value: String?, key: String, forPlugin id: String) -> Bool {
        guard let e = entry(id), e.manifest.permissions.signIn || e.manifest.permissions.storage else { return false }
        if let value { return PluginKeychain.set(plugin: id, key: key, value: value) }
        PluginKeychain.remove(plugin: id, key: key); return true
    }

    // MARK: updates

    /// Asks the update hook about every installed plugin. Returns id -> package address for the ones with a newer package. Does nothing without a hook.
    func checkForUpdates() async -> [String: URL] {
        guard isAllowed, let hook = updateSource else { return [:] }
        var out: [String: URL] = [:]
        for e in plugins { if let u = await hook(e.manifest) { out[e.id] = u } }
        return out
    }

    // MARK: state

    private func setError(_ message: String, id: String) {
        guard let i = plugins.firstIndex(where: { $0.id == id }) else { return }
        plugins[i].errorMessage = message
    }

    private func loadEnabledIDs() -> [String] {
        guard let d = try? Data(contentsOf: stateURL), let ids = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return ids
    }
    private func setEnabledState(id: String, on: Bool) {
        var ids = Set(loadEnabledIDs())
        if on { ids.insert(id) } else { ids.remove(id) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(ids.sorted()) { try? d.write(to: stateURL, options: .atomic) }
    }
}
