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

/// The recap at the start of an episode and the credits at its end: found from chapter titles when the file has them, and for credits also learned
/// from the person's own jump near the end, which is used for the rest of the series.
struct EpisodeMarks: @unchecked Sendable {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static let recapWindow: TimeInterval = 480          // a recap is looked for in the first eight minutes
    static let creditsWindow: TimeInterval = 720        // a jump in the last twelve minutes can teach where the credits start
    static let shortest: TimeInterval = 600             // episodes shorter than ten minutes have no credits worth skipping

    private func key(_ seriesID: String) -> String { "creditsLead." + seriesID }
    private static let recapWords = ["recap", "previously", "previous", "last time", "story so far"]
    private static let creditsWords = ["credit", "outro", "ending", "end card"]

    private func named(_ chapters: [PlaybackChapter], _ words: [String]) -> Int? {
        chapters.firstIndex { c in let t = c.title.lowercased(); return words.contains { t.contains($0) } }
    }

    /// Where the recap ends, while [position] is inside it; nil otherwise.
    func recapEnd(chapters: [PlaybackChapter], position: TimeInterval, duration: TimeInterval?) -> TimeInterval? {
        guard let i = named(chapters, Self.recapWords), chapters[i].time < Self.recapWindow else { return nil }
        let end = i + 1 < chapters.count ? chapters[i + 1].time : min(chapters[i].time + 90, duration ?? .infinity)
        return position >= chapters[i].time - 1 && position < end - 3 ? end : nil
    }

    /// Where the credits start for this episode: a chapter called credits, else what the person's own skip taught the app for this series.
    func creditsStart(seriesID: String, chapters: [PlaybackChapter], duration: TimeInterval?) -> TimeInterval? {
        guard let d = duration, d >= Self.shortest else { return nil }
        if let i = named(chapters, Self.creditsWords), chapters[i].time > d / 2 { return chapters[i].time }
        let lead = defaults.double(forKey: key(seriesID))
        return lead > 0 ? d - lead : nil
    }

    /// A jump (or a press of Next Episode) from the last twelve minutes to the last twenty seconds is the person skipping the credits.
    func isCreditsSkip(from: TimeInterval, to: TimeInterval, duration: TimeInterval) -> Bool {
        duration >= Self.shortest && duration - from <= Self.creditsWindow && duration - from >= 20 && duration - to <= 20
    }

    func learn(seriesID: String, from: TimeInterval, duration: TimeInterval) { defaults.set(duration - from, forKey: key(seriesID)) }
}
