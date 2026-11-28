import Foundation
import Observation

/// Knows every provider (built in and plugin), which are switched on, and which one answers each capability.
/// The first-run setup switches on the default sources (everything except Local files); after that the person decides. Choices persist in UserDefaults under `music.*`.
/// Why a source was switched on or off. The set of enabled sources changes only for these reasons.
enum MusicChangeReason: String, Codable, Sendable { case `switch`, setup, wipe, migration, plugin, unregister, newSource }

/// One change of the enabled set, kept so a source that is off when the person expected it on can be explained.
struct MusicRegistryChange: Codable, Hashable, Sendable {
    var at: Date; var id: String; var on: Bool; var reason: MusicChangeReason
}

/// The last 50 changes, newest last.
enum MusicRegistryChangeLog {
    static let limit = 50
    static let key = "music.enabledLog"
    static func appending(_ change: MusicRegistryChange, to list: [MusicRegistryChange]) -> [MusicRegistryChange] {
        Array((list + [change]).suffix(limit))
    }
    static func load(_ d: UserDefaults) -> [MusicRegistryChange] {
        guard let data = d.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([MusicRegistryChange].self, from: data)) ?? []
    }
    static func save(_ list: [MusicRegistryChange], to d: UserDefaults) {
        if let data = try? JSONEncoder().encode(list) { d.set(data, forKey: key) }
    }
}

@MainActor @Observable
final class MusicRegistry {
    private(set) var all: [any MusicProvider] = []
    /// Provider ids the person switched on.
    private(set) var enabled: Set<String>
    /// The metadata provider the Home, Search and Library screens use.
    private(set) var activeMetadataID: String?
    /// Audio providers in priority order; the matcher tries them top to bottom.
    private(set) var audioOrder: [String]
    private(set) var lyricsOrder: [String]
    /// Every change of `enabled`, last 50.
    private(set) var changeLog: [MusicRegistryChange]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = Set(defaults.stringArray(forKey: "music.enabled") ?? [])
        activeMetadataID = defaults.string(forKey: "music.activeMetadata")
        audioOrder = defaults.stringArray(forKey: "music.audioOrder") ?? []
        lyricsOrder = defaults.stringArray(forKey: "music.lyricsOrder") ?? []
        changeLog = MusicRegistryChangeLog.load(defaults)
    }

    // MARK: registration
    func register(_ p: any MusicProvider) {
        all.removeAll { $0.id == p.id }
        all.append(p)
        if !audioOrder.contains(p.id), p.capabilities.contains(.audio) { audioOrder.append(p.id) }
        if !lyricsOrder.contains(p.id), p.capabilities.contains(.lyrics) { lyricsOrder.append(p.id) }
        if activeMetadataID == nil, enabled.contains(p.id), !Self.isDiscovery(p.id), p is any MusicMetadataProvider { activeMetadataID = p.id }
        persist()
    }
    func unregister(id: String) {
        record(id, on: false, reason: .unregister)
        all.removeAll { $0.id == id }; enabled.remove(id)
        audioOrder.removeAll { $0 == id }; lyricsOrder.removeAll { $0 == id }
        if activeMetadataID == id { activeMetadataID = metadata.first?.id }
        persist()
    }

    // MARK: switches
    func isEnabled(_ id: String) -> Bool { enabled.contains(id) }
    /// The enabled set changes only by a tap on a source's switch, by Continue in setup (`.setup`), by a plugin the person enabled, or by the privacy wipe.
    func setEnabled(_ on: Bool, id: String, reason: MusicChangeReason = .switch) {
        record(id, on: on, reason: reason)
        if on { enabled.insert(id) } else { enabled.remove(id) }
        if on, activeMetadataID == nil, !Self.isDiscovery(id), all.first(where: { $0.id == id }) is any MusicMetadataProvider { activeMetadataID = id }
        if !on, activeMetadataID == id { activeMetadataID = metadata.first?.id }
        persist()
    }
    func setActiveMetadata(_ id: String) { guard metadata.contains(where: { $0.id == id }) else { return }; activeMetadataID = id; persist() }
    func setAudioOrder(_ ids: [String]) { audioOrder = ids; persist() }
    func setLyricsOrder(_ ids: [String]) { lyricsOrder = ids; persist() }

    // MARK: sources added by a later version
    static let knownBuiltInsKey = "music.knownBuiltIns"

    /// The built-in source ids this install has already been offered (switched on by setup, or decided by the person since).
    var knownBuiltIns: Set<String> { Set(defaults.stringArray(forKey: Self.knownBuiltInsKey) ?? []) }

    /// Remembers every built-in source registered now as offered, so a later version's new ones can be told apart.
    func recordKnownBuiltIns() {
        let ids = all.filter { $0.info.kind == .builtIn }.map(\.id)
        defaults.set(Array(knownBuiltIns.union(ids)).sorted(), forKey: Self.knownBuiltInsKey)
    }

    /// A built-in source that did not exist when this install was set up starts on, like the others did: unless it is Local files or needs an
    /// account. A source already in the known set is never touched again, so a source the person switched off stays off. Plugins are never
    /// touched. Does nothing before the first-run setup is done (the setup screen decides then). Returns the ids switched on.
    @discardableResult
    func adoptNewBuiltIns(setupDone: Bool) -> [String] {
        guard setupDone else { return [] }
        let hadRecord = defaults.object(forKey: Self.knownBuiltInsKey) != nil
        let known = knownBuiltIns
        var lastChange: [String: MusicRegistryChange] = [:]
        for c in changeLog { lastChange[c.id] = c }
        var turnedOn: [String] = []
        for id in MusicSetupPresets.defaultSet(providers: all).sorted() where !known.contains(id) && !enabled.contains(id) {
            // Before the known set existed, a source the person switched off by hand is told apart by the change log.
            if !hadRecord, let c = lastChange[id], !c.on, c.reason == .switch { continue }
            setEnabled(true, id: id, reason: .newSource)
            turnedOn.append(id)
        }
        recordKnownBuiltIns()
        return turnedOn
    }

    // MARK: lookups (enabled providers only)
    /// Read-only discovery providers (id prefix `discover-`) feed Home shelves only; they are never the browsing source and never search.
    static func isDiscovery(_ id: String) -> Bool { id.hasPrefix("discover-") }
    var metadata: [any MusicMetadataProvider] { all.filter { enabled.contains($0.id) && !Self.isDiscovery($0.id) }.compactMap { $0 as? any MusicMetadataProvider } }
    var discovery: [any MusicMetadataProvider] { all.filter { enabled.contains($0.id) && Self.isDiscovery($0.id) }.compactMap { $0 as? any MusicMetadataProvider } }
    var activeMetadata: (any MusicMetadataProvider)? { metadata.first { $0.id == activeMetadataID } ?? metadata.first }
    var audio: [any MusicAudioProvider] { audioOrder.compactMap { id in all.first { $0.id == id && enabled.contains(id) } as? any MusicAudioProvider } }
    var lyrics: [any MusicLyricsProvider] { lyricsOrder.compactMap { id in all.first { $0.id == id && enabled.contains(id) } as? any MusicLyricsProvider } }
    var scrobblers: [any MusicScrobbleProvider] { all.filter { enabled.contains($0.id) }.compactMap { $0 as? any MusicScrobbleProvider } }
    func provider(id: String) -> (any MusicProvider)? { all.first { $0.id == id } }
    /// A metadata source the person has switched ON. A switched-off source is never asked (nil), so callers show "switched off in Settings" or skip it.
    func metadataProvider(id: String) -> (any MusicMetadataProvider)? { enabled.contains(id) ? provider(id: id) as? any MusicMetadataProvider : nil }

    private func record(_ id: String, on: Bool, reason: MusicChangeReason) {
        guard enabled.contains(id) != on else { return }
        changeLog = MusicRegistryChangeLog.appending(MusicRegistryChange(at: Date(), id: id, on: on, reason: reason), to: changeLog)
        MusicRegistryChangeLog.save(changeLog, to: defaults)
    }

    private func persist() {
        defaults.set(Array(enabled).sorted(), forKey: "music.enabled")
        defaults.set(activeMetadataID, forKey: "music.activeMetadata")
        defaults.set(audioOrder, forKey: "music.audioOrder")
        defaults.set(lyricsOrder, forKey: "music.lyricsOrder")
    }
}
