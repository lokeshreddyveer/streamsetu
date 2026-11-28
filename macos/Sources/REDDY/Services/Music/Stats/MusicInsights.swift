import Foundation
import Observation

// Insights worked out from the counted plays on this device: what share of listening each genre and language has, the monthly and yearly recap, and the
// person's own taste controls (private listening, reset, preferred languages, genres and artists). The numbers are plain functions of the stats file, so
// they are tested without a screen. Nothing here is sent anywhere.

struct MusicInsightShare: Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var secs: Int
    var plays: Int
    /// Share of the listening that has this label (0...1), out of the songs that carry one.
    var fraction: Double
}

enum MusicRecapPeriod: String, CaseIterable, Identifiable, Sendable {
    case month, year
    var id: String { rawValue }
    var component: Calendar.Component { self == .month ? .month : .year }
}

struct MusicRecap: Sendable {
    var period: MusicRecapPeriod
    var start: Date
    var end: Date
    var totalSecs = 0
    var plays = 0
    var songs = 0
    var artists = 0
    var newSongs = 0
    var newArtists = 0
    var listeningDays = 0
    var longestStreak = 0
    var busiestDay: Date?
    var busiestDaySecs = 0
    var previousSecs = 0
    var topSongs: [MusicTopSong] = []
    var topArtists: [MusicTopArtist] = []
    var topAlbums: [MusicTopAlbum] = []
    var genres: [MusicInsightShare] = []
    var languages: [MusicInsightShare] = []
    /// 0 morning, 1 afternoon, 2 evening, 3 night; nil with no plays.
    var favouriteDaypart: Int?

    var isEmpty: Bool { plays == 0 }
    /// Change against the period before, as a whole percent; nil when there was nothing before.
    var changePercent: Int? { previousSecs > 0 ? Int((Double(totalSecs - previousSecs) / Double(previousSecs) * 100).rounded()) : nil }
}

enum MusicInsightsEngine {
    /// Genre labels a track carries ("Pop / Rock" counts toward both), folded for grouping and shown as sent.
    static func genreLabels(_ t: MusicTrack) -> [String] {
        guard let g = t.creditBundle?.hints?.genre else { return [] }
        return g.split(whereSeparator: { "/,;&".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func genres(_ songs: [MusicStatsEngine.SongAgg], limit: Int = 6) -> [MusicInsightShare] {
        var by: [String: (name: String, secs: Int, plays: Int)] = [:]
        for s in songs {
            let labels = genreLabels(s.track)
            for l in labels {
                let k = MusicText.normalize(l)
                guard !k.isEmpty else { continue }
                let e = by[k] ?? (l, 0, 0)
                by[k] = (e.name, e.secs + s.secs / labels.count, e.plays + s.plays)
            }
        }
        return shares(by, limit: limit)
    }

    static func languages(_ songs: [MusicStatsEngine.SongAgg], limit: Int = 6) -> [MusicInsightShare] {
        var by: [String: (name: String, secs: Int, plays: Int)] = [:]
        for s in songs {
            guard let l = MusicLanguageDetector.language(of: s.track) else { continue }
            let e = by[l.rawValue] ?? (l.englishName, 0, 0)
            by[l.rawValue] = (e.name, e.secs + s.secs, e.plays + s.plays)
        }
        return shares(by, limit: limit)
    }

    private static func shares(_ by: [String: (name: String, secs: Int, plays: Int)], limit: Int) -> [MusicInsightShare] {
        let total = by.values.reduce(0) { $0 + max($1.secs, $1.plays) }
        guard total > 0 else { return [] }
        return by.map { MusicInsightShare(id: $0.key, name: $0.value.name, secs: $0.value.secs, plays: $0.value.plays, fraction: Double(max($0.value.secs, $0.value.plays)) / Double(total)) }
            .sorted { $0.fraction != $1.fraction ? $0.fraction > $1.fraction : $0.id < $1.id }
            .prefix(limit).map { $0 }
    }

    /// The songs heard between `start` (inclusive) and `end` (exclusive).
    static func songs(_ f: MusicStatsFile, start: Date, end: Date, calendar: Calendar = .current) -> (songs: [MusicStatsEngine.SongAgg], days: [Int: Int], hours: [Int], secs: Int, plays: Int) {
        let math = MusicDayMath(calendar: calendar)
        let lo = math.hourIndex(start), hi = math.hourIndex(end.addingTimeInterval(-1)) + 1
        var agg: [String: (plays: Int, secs: Int)] = [:]
        var days: [Int: Int] = [:]
        var parts = [0, 0, 0, 0]
        var secs = 0, plays = 0
        for c in MusicStatsEngine.cells(f, math: math) where c.idx >= lo && c.idx < hi {
            secs += c.secs; plays += c.plays
            days[c.day, default: 0] += c.secs
            parts[MusicStatsReport.daypart(hour: c.hour)] += c.secs
            let e = agg[c.uid] ?? (0, 0)
            agg[c.uid] = (e.plays + c.plays, e.secs + c.secs)
        }
        var out: [MusicStatsEngine.SongAgg] = []
        for (uid, a) in agg {
            guard let e = f.songs[uid], MusicStatsRules.isSong(e.track) else { continue }
            out.append(MusicStatsEngine.SongAgg(track: e.track, plays: a.plays, secs: a.secs, firstAt: e.firstAt))
        }
        return (out, days, parts, secs, plays)
    }

    /// The recap of the month or year that contains `anchor`.
    static func recap(_ f: MusicStatsFile, period: MusicRecapPeriod, anchor: Date, calendar: Calendar = .current) -> MusicRecap {
        let interval = calendar.dateInterval(of: period.component, for: anchor) ?? DateInterval(start: anchor, duration: 86_400)
        var r = MusicRecap(period: period, start: interval.start, end: interval.end)
        let now = songs(f, start: interval.start, end: interval.end, calendar: calendar)
        let before = calendar.date(byAdding: period.component, value: -1, to: interval.start) ?? interval.start
        r.previousSecs = songs(f, start: before, end: interval.start, calendar: calendar).secs
        r.totalSecs = now.secs; r.plays = now.plays; r.songs = now.songs.count
        guard now.plays > 0 else { return r }
        r.newSongs = now.songs.filter { $0.firstAt >= interval.start }.count
        let ordered = now.songs.sorted { $0.secs != $1.secs ? $0.secs > $1.secs : ($0.plays != $1.plays ? $0.plays > $1.plays : $0.track.uid < $1.track.uid) }
        r.topSongs = now.songs.sorted { $0.plays != $1.plays ? $0.plays > $1.plays : ($0.secs != $1.secs ? $0.secs > $1.secs : $0.track.uid < $1.track.uid) }
            .prefix(5).map { MusicTopSong(track: $0.track, plays: $0.plays, secs: $0.secs) }
        let artists = MusicStatsEngine.aggregateArtists(ordered)
        r.artists = artists.count
        r.topArtists = artists.sorted { $0.secs != $1.secs ? $0.secs > $1.secs : $0.plays > $1.plays }.prefix(5).map { $0 }
        r.topAlbums = MusicStatsEngine.aggregateAlbums(ordered).prefix(3).map { $0 }
        r.genres = genres(now.songs, limit: 4)
        r.languages = languages(now.songs, limit: 4)
        r.listeningDays = now.days.count
        r.longestStreak = MusicStatsEngine.streaks(days: Set(now.days.keys), today: Int.max / 2).best
        if let top = now.days.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) {
            let math = MusicDayMath(calendar: calendar)
            r.busiestDaySecs = top.value
            let startDay = math.day(interval.start)
            r.busiestDay = calendar.date(byAdding: .day, value: top.key - startDay, to: interval.start)
        }
        if let i = now.hours.indices.max(by: { now.hours[$0] != now.hours[$1] ? now.hours[$0] < now.hours[$1] : $0 > $1 }), now.hours[i] > 0 { r.favouriteDaypart = i }
        // Artists whose very first listen ever fell in this period.
        var firstByArtist: [String: Date] = [:]
        for e in f.songs.values {
            for c in MusicStatsRules.credits(for: e.track) {
                let k = c.id ?? MusicText.normalize(c.name)
                firstByArtist[k] = min(firstByArtist[k] ?? e.firstAt, e.firstAt)
            }
        }
        let periodArtists = Set(now.songs.flatMap { MusicStatsRules.credits(for: $0.track).map { $0.id ?? MusicText.normalize($0.name) } })
        r.newArtists = periodArtists.filter { (firstByArtist[$0] ?? .distantPast) >= interval.start }.count
        return r
    }
}

// MARK: - the person's own controls

/// Private listening: while it is on, nothing played is counted, kept in history, scrobbled or used to shape recommendations. It lasts for the session and is
/// off again after the app restarts, so it is never left on by accident.
@MainActor @Observable
final class MusicPrivateListening {
    static let shared = MusicPrivateListening()
    var isOn = false
    func toggle() { isOn.toggle() }
}

/// Reset recommendations: a date before which plays no longer shape what is suggested. History, stats and likes are not touched.
enum MusicTasteReset {
    private static let key = "music.taste.resetAt"
    static var cutoff: Date? { UserDefaults.standard.object(forKey: key) as? Date }
    static func mark(_ date: Date = Date()) { UserDefaults.standard.set(date, forKey: key) }
    static func undo() { UserDefaults.standard.removeObject(forKey: key) }

    static func visible(_ history: [PlayRecord], cutoff: Date? = MusicTasteReset.cutoff) -> [PlayRecord] {
        guard let cutoff else { return history }
        return history.filter { $0.at >= cutoff }
    }
}

/// What the person said they like. Languages, genres and artists shape Recently Added, Radio and autoplay; songs in a genre marked "not for me" are left out of them.
struct MusicTastePrefs: Codable, Equatable, Sendable {
    var languages: Set<String> = []
    var genres: Set<String> = []
    var artists: [MusicArtist] = []
    /// Genres marked "love" (a stronger lean than "like") and "not for me" (kept out of the lean). Added after the first release, so an older saved copy still reads.
    var lovedGenres: Set<String> = []
    var dislikedGenres: Set<String> = []

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        languages = try c.decodeIfPresent(Set<String>.self, forKey: .languages) ?? []
        genres = try c.decodeIfPresent(Set<String>.self, forKey: .genres) ?? []
        artists = try c.decodeIfPresent([MusicArtist].self, forKey: .artists) ?? []
        lovedGenres = try c.decodeIfPresent(Set<String>.self, forKey: .lovedGenres) ?? []
        dislikedGenres = try c.decodeIfPresent(Set<String>.self, forKey: .dislikedGenres) ?? []
    }

    var isEmpty: Bool { languages.isEmpty && genres.isEmpty && artists.isEmpty && lovedGenres.isEmpty && dislikedGenres.isEmpty }
    func dislikesGenre(_ t: MusicTrack) -> Bool { genreMatch(t, in: dislikedGenres) }
    private func genreMatch(_ t: MusicTrack, in set: Set<String>) -> Bool {
        guard !set.isEmpty else { return false }
        let wanted = Set(set.map { MusicText.normalize($0) })
        return MusicInsightsEngine.genreLabels(t).contains { wanted.contains(MusicText.normalize($0)) }
    }
    var languageSet: Set<MusicLanguage> { Set(languages.compactMap(MusicLanguage.init(rawValue:))) }

    // What Radio uses to lift songs the person said they like within their source (Listen Now does not use these).
    func lovesGenre(_ t: MusicTrack) -> Bool { genreMatch(t, in: lovedGenres) }
    var artistKeys: Set<String> { Set(artists.map { MusicHiddenSet.artistKey(MusicArtistRef(id: $0.id, name: $0.name)) }) }
    func likesArtist(_ t: MusicTrack) -> Bool { t.artists.contains { artistKeys.contains(MusicHiddenSet.artistKey($0)) } }
    func likesGenre(_ t: MusicTrack) -> Bool { genreMatch(t, in: genres) }
    func likesLanguage(_ t: MusicTrack) -> Bool {
        guard let l = MusicLanguageDetector.language(of: t) else { return false }
        return languageSet.contains(l)
    }
    /// How well a song fits what was chosen: one point each for artist, genre, language and loved genre, minus three for a genre marked not for me.
    func matches(_ t: MusicTrack) -> Int { (likesArtist(t) ? 1 : 0) + (likesGenre(t) ? 1 : 0) + (likesLanguage(t) ? 1 : 0) + (lovesGenre(t) ? 1 : 0) - (dislikesGenre(t) ? 3 : 0) }
}

@MainActor @Observable
final class MusicTastePreferences {
    static let shared = MusicTastePreferences()
    private static let key = "music.taste.prefs"
    private(set) var prefs: MusicTastePrefs
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let d = defaults.data(forKey: Self.key), let p = try? JSONDecoder().decode(MusicTastePrefs.self, from: d) { prefs = p } else { prefs = MusicTastePrefs() }
    }

    func update(_ change: (inout MusicTastePrefs) -> Void) {
        change(&prefs)
        if prefs.isEmpty { defaults.removeObject(forKey: Self.key) } else if let d = try? JSONEncoder().encode(prefs) { defaults.set(d, forKey: Self.key) }
    }
}
