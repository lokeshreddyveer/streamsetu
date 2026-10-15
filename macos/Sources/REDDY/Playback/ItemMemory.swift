import Foundation

/// What was chosen the last time a title or channel played: audio language, subtitles, speed and timing. It comes back the next time the same one plays.
/// Kept on this device only, newest 400 titles.
struct ItemMemory: @unchecked Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var audioLanguage: String?
        /// A language code, "off" for subtitles turned off, nil when nothing was chosen.
        var subtitleLanguage: String?
        var rate: Double = 1
        var audioDelay: Double = 0
        var subtitleDelay: Double = 0
        var savedAt = Date()
    }

    private let defaults: UserDefaults
    private static let key = "itemMemory.v1"
    private static let enabledKey = "rememberPerTitle"
    private static let limit = 400

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var enabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    private func load() -> [String: Entry] {
        guard let data = defaults.data(forKey: Self.key), let all = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return all
    }

    func entry(for id: String) -> Entry? { enabled ? load()[id] : nil }

    func save(_ entry: Entry, for id: String) {
        guard enabled else { return }
        var all = load()
        all[id] = entry
        if all.count > Self.limit { for (k, _) in all.sorted(by: { $0.value.savedAt < $1.value.savedAt }).prefix(all.count - Self.limit) { all[k] = nil } }
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Self.key) }
    }
}

/// Where the opening of a series ends, learned from the person's own skip (a long jump forward early in an episode) and used for the rest of the series.
struct IntroSkip: @unchecked Sendable {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static let window: TimeInterval = 360        // the opening is looked for in the first six minutes
    static let minimumJump: TimeInterval = 30
    static let defaultEnd: TimeInterval = 90

    private func key(_ seriesID: String) -> String { "introEnd." + seriesID }

    /// Where to jump to from [position], or nil when there is no opening to skip any more.
    func target(seriesID: String, position: TimeInterval) -> TimeInterval? {
        let learned = defaults.double(forKey: key(seriesID))
        let end = learned > 0 ? learned : Self.defaultEnd
        return position < Self.window && position < end - 3 ? end : nil
    }

    func isOpeningSkip(from: TimeInterval, to: TimeInterval) -> Bool { from < Self.window && to <= Self.window && to - from >= Self.minimumJump }

    func learn(seriesID: String, end: TimeInterval) { defaults.set(end, forKey: key(seriesID)) }
}
