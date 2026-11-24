import Foundation
import Observation

/// An episode as the player and the lists keep it: enough to play it and show it without reading the feed again.
struct PodcastEpisodeRef: Codable, Equatable, Identifiable, Sendable {
    var id: String { itemID }
    var itemID: String
    var title: String
    var audioURL: URL
    var showTitle: String
    var feedURL: URL
    var artwork: URL?
    var duration: TimeInterval?
    var published: Date?
    var summary = ""
    var chaptersURL: URL?
    var transcriptURL: URL?

    init(_ e: PodcastEpisode, show: PodcastSubscription, showArtwork: URL? = nil) {
        itemID = e.itemID; title = e.title; audioURL = e.audioURL; showTitle = show.title; feedURL = show.feedURL
        artwork = e.artwork ?? showArtwork ?? show.artwork; duration = e.duration; published = e.published; summary = e.displaySummary
        chaptersURL = e.chaptersURL; transcriptURL = e.transcriptURL
    }
}

/// How far an episode got.
struct PodcastProgress: Codable, Equatable, Sendable {
    var position: TimeInterval
    var duration: TimeInterval?
    var played: Bool
    var updated: Date
    var fraction: Double { guard let d = duration, d > 0 else { return 0 }; return min(1, max(0, position / d)) }
}

/// Speed and skips for one show; nil means "as for every show".
struct PodcastShowSettings: Codable, Equatable, Sendable {
    var speed: Double?
    var skipBack: Int?
    var skipForward: Int?
    var skipIntro: Int?
    var isEmpty: Bool { speed == nil && skipBack == nil && skipForward == nil && skipIntro == nil }
}

struct PodcastPlaybackPrefs: Codable, Equatable, Sendable {
    var speed = 1.0
    var skipBack = 15
    var skipForward = 30
}

/// What the Podcasts screens remember on this Mac: played state and place of each episode, recently played, the Up Next queue, per-show settings and
/// which new episodes the person has seen. One JSON value in preferences. Library playback never touches it.
@MainActor @Observable
final class PodcastLibrary {
    private struct Stored: Codable {
        var progress: [String: PodcastProgress] = [:]
        var recents: [PodcastEpisodeRef] = []
        var queue: [PodcastEpisodeRef] = []
        var shows: [String: PodcastShowSettings] = [:]
        var prefs = PodcastPlaybackPrefs()
        var latest: [String: Date] = [:]
        var seen: [String: Date] = [:]
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key = "podcasts.library.v1"
    private var stored: Stored { didSet { save() } }
    static let recentLimit = 40
    static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        stored = defaults.data(forKey: "podcasts.library.v1").flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
    }

    private func save() { defaults.set(try? JSONEncoder().encode(stored), forKey: key) }

    // MARK: progress

    func progress(_ itemID: String) -> PodcastProgress? { stored.progress[itemID] }
    func isPlayed(_ itemID: String) -> Bool { stored.progress[itemID]?.played ?? false }

    func setPosition(_ ref: PodcastEpisodeRef, position: TimeInterval, duration: TimeInterval?) {
        var p = stored.progress[ref.itemID] ?? PodcastProgress(position: 0, duration: nil, played: false, updated: Date())
        p.position = position; p.duration = duration ?? p.duration ?? ref.duration; p.updated = Date()
        stored.progress[ref.itemID] = p
        remember(ref)
    }

    func markPlayed(_ ref: PodcastEpisodeRef, _ played: Bool) {
        var p = stored.progress[ref.itemID] ?? PodcastProgress(position: 0, duration: ref.duration, played: false, updated: Date())
        p.played = played; p.updated = Date()
        if played { p.position = 0 }
        stored.progress[ref.itemID] = p
        if played { stored.queue.removeAll { $0.itemID == ref.itemID } }
    }

    /// Where to start this episode: its saved place unless it is played or barely begun; else after the show's intro skip.
    func startPosition(_ ref: PodcastEpisodeRef) -> TimeInterval {
        if let p = stored.progress[ref.itemID], !p.played, p.position > 10 { return p.position }
        return TimeInterval(settings(for: ref.feedURL).skipIntro ?? 0)
    }

    // MARK: recents

    private func remember(_ ref: PodcastEpisodeRef) {
        stored.recents.removeAll { $0.itemID == ref.itemID }
        stored.recents.insert(ref, at: 0)
        if stored.recents.count > Self.recentLimit { stored.recents.removeLast(stored.recents.count - Self.recentLimit) }
    }
    func recents() -> [PodcastEpisodeRef] { stored.recents }
    /// Episodes begun and not finished, newest first.
    func continueListening(limit: Int = 12) -> [(ref: PodcastEpisodeRef, progress: PodcastProgress)] {
        stored.recents.compactMap { r in stored.progress[r.itemID].flatMap { $0.played || $0.position < 10 ? nil : (r, $0) } }.prefix(limit).map { $0 }
    }
    func clearRecents() { stored.recents = [] }

    // MARK: queue

    var queue: [PodcastEpisodeRef] { stored.queue }
    func addToQueue(_ ref: PodcastEpisodeRef) { stored.queue.removeAll { $0.itemID == ref.itemID }; stored.queue.append(ref) }
    func playNext(_ ref: PodcastEpisodeRef) { stored.queue.removeAll { $0.itemID == ref.itemID }; stored.queue.insert(ref, at: 0) }
    func removeFromQueue(_ itemID: String) { stored.queue.removeAll { $0.itemID == itemID } }
    func moveInQueue(from: IndexSet, to: Int) { stored.queue.move(fromOffsets: from, toOffset: to) }
    func clearQueue() { stored.queue = [] }
    /// Takes the next episode off the front of the queue.
    func popQueue() -> PodcastEpisodeRef? { stored.queue.isEmpty ? nil : stored.queue.removeFirst() }

    // MARK: settings

    var prefs: PodcastPlaybackPrefs { get { stored.prefs } set { stored.prefs = newValue } }
    func settings(for feed: URL) -> PodcastShowSettings { stored.shows[feed.absoluteString] ?? PodcastShowSettings() }
    func setSettings(_ s: PodcastShowSettings, for feed: URL) { stored.shows[feed.absoluteString] = s.isEmpty ? nil : s }
    func speed(for feed: URL) -> Double { settings(for: feed).speed ?? stored.prefs.speed }
    func skipBack(for feed: URL) -> Int { settings(for: feed).skipBack ?? stored.prefs.skipBack }
    func skipForward(for feed: URL) -> Int { settings(for: feed).skipForward ?? stored.prefs.skipForward }

    // MARK: new episodes

    /// The newest episode date of a followed show was read. The first time it is only noted (nothing is "new" yet).
    func noteLatest(_ date: Date?, for feed: URL) {
        guard let date else { return }
        let k = feed.absoluteString
        stored.latest[k] = date
        if stored.seen[k] == nil { stored.seen[k] = date }
    }
    func markSeen(_ feed: URL) { let k = feed.absoluteString; if let l = stored.latest[k] { stored.seen[k] = l } }
    func hasNewEpisode(_ feed: URL) -> Bool {
        let k = feed.absoluteString
        guard let l = stored.latest[k], let s = stored.seen[k] else { return false }
        return l > s
    }
}
