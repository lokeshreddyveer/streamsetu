import Foundation
import Observation

// Plugin updates, only on the person's say-so. A check happens when they press the button (or, if they turned the weekly switch on, at most once a week
// when Music opens). An update is never installed by itself: the new manifest is compared with the installed one, new permissions are called out,
// and nothing is written until the person confirms.

/// What changed between an installed manifest and the one offered.
struct MusicManifestDiff: Equatable, Sendable {
    var oldVersion: String
    var newVersion: String
    var addedHosts: [String]
    var removedHosts: [String]
    var addedPermissions: [String]
    var removedPermissions: [String]
    var addedCapabilities: [String]
    var removedCapabilities: [String]

    /// Anything that gives the plugin more reach than before.
    var widensAccess: Bool { !addedHosts.isEmpty || !addedPermissions.isEmpty || !addedCapabilities.isEmpty }

    static func compute(old: MusicPluginManifest, new: MusicPluginManifest) -> MusicManifestDiff {
        func flags(_ p: MusicPluginPermissions) -> Set<String> {
            var s: Set<String> = []
            if p.storage { s.insert("Private storage") }
            if p.crypto { s.insert("Cryptography") }
            if p.signIn { s.insert("Sign in") }
            return s
        }
        let oh = Set(old.permissions.networkHosts), nh = Set(new.permissions.networkHosts)
        let of = flags(old.permissions), nf = flags(new.permissions)
        let oc = Set(old.capabilities.map(\.rawValue)), nc = Set(new.capabilities.map(\.rawValue))
        return MusicManifestDiff(oldVersion: old.version, newVersion: new.version,
                                 addedHosts: nh.subtracting(oh).sorted(), removedHosts: oh.subtracting(nh).sorted(),
                                 addedPermissions: nf.subtracting(of).sorted(), removedPermissions: of.subtracting(nf).sorted(),
                                 addedCapabilities: nc.subtracting(oc).sorted(), removedCapabilities: oc.subtracting(nc).sorted())
    }
}

enum MusicVersion {
    /// Dotted numbers compared part by part ("1.10.0" is newer than "1.9.2"). Non-numeric parts count as 0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

struct MusicPluginUpdateOffer: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var package: URL
}

/// What the person is asked to approve.
struct MusicPluginUpdateReview: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var diff: MusicManifestDiff
}

@MainActor @Observable
final class MusicPluginUpdates {
    static let weeklyKey = "music.pluginUpdates.weekly"
    static let lastCheckKey = "music.pluginUpdates.lastCheck"

    private(set) var offers: [MusicPluginUpdateOffer] = []
    private(set) var review: MusicPluginUpdateReview?
    private(set) var isChecking = false
    private(set) var status: String?
    private(set) var lastCheck: Date?

    /// Off by default. When on, `checkIfDue` may run a check about once a week; it still never installs anything.
    var weeklyCheck: Bool {
        didSet { defaults.set(weeklyCheck, forKey: Self.weeklyKey) }
    }

    @ObservationIgnored private let plugins: MusicPluginManager
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let transport: MusicHTTPTransport
    @ObservationIgnored private var decision: CheckedContinuation<Bool, Never>?

    /// `transport` is used for the default update source only: it reads `<homepage>/update.json` of a plugin that has an https homepage.
    init(plugins: MusicPluginManager, defaults: UserDefaults = .standard, transport: MusicHTTPTransport = URLSessionTransport()) {
        self.plugins = plugins; self.defaults = defaults; self.transport = transport
        weeklyCheck = defaults.bool(forKey: Self.weeklyKey)
        lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date
    }

    /// Gives the plugin manager a way to ask about updates, unless the app already set its own.
    func installDefaultSource() {
        guard plugins.updateSource == nil else { return }
        let transport = self.transport
        plugins.updateSource = { manifest in await Self.fetchOffer(for: manifest, transport: transport) }
    }

    /// The default feed: `update.json` next to the plugin's https homepage, shaped {"version": "1.2.0", "package": "https://…"}.
    nonisolated static func fetchOffer(for manifest: MusicPluginManifest, transport: MusicHTTPTransport) async -> URL? {
        guard let home = manifest.homepage, let base = URL(string: home), base.scheme?.lowercased() == "https", base.host?.isEmpty == false else { return nil }
        var req = URLRequest(url: base.appendingPathComponent("update.json")); req.timeoutInterval = 20
        guard let (data, resp) = try? await transport.data(for: req), resp.statusCode == 200, data.count < 16_384 else { return nil }
        return offerURL(from: data, installedVersion: manifest.version)
    }

    /// Pure: the package address when the feed names a newer version and an https package.
    nonisolated static func offerURL(from data: Data, installedVersion: String) -> URL? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let v = o["version"] as? String, let p = o["package"] as? String,
              MusicVersion.isNewer(v, than: installedVersion), let u = URL(string: p), u.scheme?.lowercased() == "https", u.host?.isEmpty == false else { return nil }
        return u
    }

    // MARK: checking (button or weekly switch only)

    func check() async {
        guard !isChecking, plugins.isAllowed else { return }
        isChecking = true; status = nil
        installDefaultSource()
        let found = await plugins.checkForUpdates()
        offers = found.compactMap { id, url in plugins.entry(id).map { MusicPluginUpdateOffer(id: id, name: $0.manifest.name, package: url) } }.sorted { $0.name < $1.name }
        lastCheck = Date(); defaults.set(lastCheck, forKey: Self.lastCheckKey)
        status = offers.isEmpty ? "All plugins are up to date." : "\(offers.count) update\(offers.count == 1 ? "" : "s") available."
        isChecking = false
    }

    nonisolated static func isDue(last: Date?, now: Date, enabled: Bool) -> Bool {
        guard enabled else { return false }
        guard let last else { return true }
        return now.timeIntervalSince(last) >= 7 * 24 * 3600
    }

    /// Call when Music opens. Does nothing unless the person turned the weekly switch on and a week has passed.
    func checkIfDue(now: Date = Date()) async {
        guard Self.isDue(last: lastCheck, now: now, enabled: weeklyCheck) else { return }
        await check()
    }

    // MARK: reviewing and installing (always explicit)

    /// Downloads the offered package into memory, shows its diff, and installs only after `confirm()`. `decline()` or never answering leaves everything as it was.
    func beginUpdate(_ offer: MusicPluginUpdateOffer) async {
        guard review == nil, plugins.isAllowed, let installed = plugins.entry(offer.id) else { return }
        let wasEnabled = installed.enabled
        let old = installed.manifest
        status = nil
        do {
            _ = try await plugins.install(fromRemote: offer.package) { [self] new in
                guard new.id == old.id else { return false }
                review = MusicPluginUpdateReview(id: old.id, name: new.name, diff: .compute(old: old, new: new))
                return await withCheckedContinuation { decision = $0 }
            }
            review = nil
            if wasEnabled { plugins.setEnabled(false, id: offer.id); plugins.setEnabled(true, id: offer.id) }
            offers.removeAll { $0.id == offer.id }
            status = "\(offer.name) was updated."
        } catch MusicError.cancelled {
            review = nil; status = "Update cancelled. Nothing changed."
        } catch {
            review = nil; status = "Could not update \(offer.name)."
        }
    }

    func confirm() { resolve(true) }
    func decline() { resolve(false) }
    private func resolve(_ yes: Bool) { let d = decision; decision = nil; d?.resume(returning: yes) }
}
