import Foundation

/// What REDDY remembers about how one channel should play: how much louder or quieter than the main volume, and which player
/// engine suits it. Only channels the person has changed are stored.
struct ChannelPlaybackPref: Codable, Equatable, Sendable {
    /// Added to the main volume (−0.5…+0.5). Negative for a channel that is louder than the rest.
    var volumeTrim: Double = 0
    var engine: String?
    var updatedAt: Date = Date()

    var engineChoice: PlaybackEnginePreference? { engine.flatMap(PlaybackEnginePreference.init(rawValue:)) }
    var isDefault: Bool { abs(volumeTrim) < 0.001 && engine == nil }

    static let trimRange: ClosedRange<Double> = -0.5...0.5
}

enum ChannelVolume {
    /// The volume the engine is given: the main volume moved by the channel's trim, kept between silent and full.
    static func effective(master: Double, trim: Double) -> Double { min(1, max(0, master + trim)) }
}

/// Stored in preferences as one small dictionary. When it grows past `limit` the least recently changed channels are dropped.
final class ChannelPlaybackPrefs: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "playback.channelPrefs.v1"
    private let lock = NSLock()
    private var cache: [String: ChannelPlaybackPref]?
    let limit: Int

    init(defaults: UserDefaults = .standard, limit: Int = 1500) { self.defaults = defaults; self.limit = limit }

    private func load() -> [String: ChannelPlaybackPref] {
        if let cache { return cache }
        let items = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: ChannelPlaybackPref].self, from: $0) } ?? [:]
        cache = items
        return items
    }

    private func store(_ items: [String: ChannelPlaybackPref]) {
        var items = items
        if items.count > limit { for id in items.sorted(by: { $0.value.updatedAt < $1.value.updatedAt }).prefix(items.count - limit).map(\.key) { items[id] = nil } }
        cache = items
        if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: key) }
    }

    func pref(for channelID: String) -> ChannelPlaybackPref { lock.lock(); defer { lock.unlock() }; return load()[channelID] ?? ChannelPlaybackPref() }
    func all() -> [String: ChannelPlaybackPref] { lock.lock(); defer { lock.unlock() }; return load() }

    /// Adds settings from a backup for channels that have none here.
    func merge(_ items: [String: ChannelPlaybackPref]) {
        lock.lock(); defer { lock.unlock() }
        var current = load()
        for (id, p) in items where current[id] == nil && !p.isDefault { current[id] = p }
        store(current)
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return load().count }

    func update(_ channelID: String, _ change: (inout ChannelPlaybackPref) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var items = load()
        var p = items[channelID] ?? ChannelPlaybackPref()
        change(&p)
        p.volumeTrim = min(ChannelPlaybackPref.trimRange.upperBound, max(ChannelPlaybackPref.trimRange.lowerBound, p.volumeTrim))
        p.updatedAt = Date()
        items[channelID] = p.isDefault ? nil : p
        store(items)
    }

    func clearAll() { lock.lock(); defer { lock.unlock() }; store([:]) }
}
