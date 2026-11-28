import Foundation
import Observation

// Listening statistics counted on this device from what the person plays. Nothing here touches the network.
//
// Storage is one JSON file under the Music directory. Every counted play is one row (`MusicListenRow`). Rows are kept up to `playCap`;
// past that the oldest rows are folded into hour-level rollups (per local day, hour and song) so totals, streaks, heatmaps and the
// previous-period comparison keep working for the whole history while the file stays bounded.

// MARK: - Rules

enum MusicStatsRules {
    /// Rows kept one by one. Older rows are folded into rollups, never dropped.
    static let playCap = 50_000
    /// How many rows are folded at once when the cap is passed, so folding does not happen on every play.
    static let foldBatch = 5_000
    static let longVideoLimit: TimeInterval = 15 * 60
    static let maxTickStep: TimeInterval = 2
    static let writeEverySeconds = 30
    static let topSongs = 10, topArtists = 8, topAlbums = 6
    static let onRepeatDays = 30, onRepeatLimit = 20, onRepeatSeedMinimum = 5

    /// Sources that serve video; a long item from one of them is a mix, a stream or a podcast, not a song.
    static let videoProviders: Set<String> = ["youtube-music", "youtube", "piped", "invidious"]
    static let localProviderID = "local"

    /// Position at which a play counts: half the track, at most 30 s; 30 s when the length is unknown.
    static func playThreshold(duration: TimeInterval) -> TimeInterval { duration > 1 ? min(duration / 2, 30) : 30 }

    /// Audio and local files are songs at any length. Videos count only up to 15 minutes (unknown length gets the benefit of the doubt).
    /// When the item carries its own video flag that decides; the provider list is the fallback for items saved before the flag existed.
    static func isSong(_ t: MusicTrack) -> Bool {
        if let v = t.isVideo { if !v { return true } } else if !videoProviders.contains(t.providerID) { return true }
        return t.durationMs <= 0 || t.duration <= longVideoLimit
    }

    static func isLocal(_ t: MusicTrack) -> Bool { t.providerID == localProviderID }

    /// The lead name of a credit line: cut at the first ";" and at the earliest featuring marker. Nil for empty and "Unknown artist".
    static func leadName(_ line: String) -> String? {
        var s = line
        if let r = s.range(of: ";") { s = String(s[..<r.lowerBound]) }
        var cut = s.endIndex
        for m in [" feat.", " feat ", " ft.", " ft ", " featuring "] {
            if let r = s.range(of: m, options: .caseInsensitive), r.lowerBound < cut { cut = r.lowerBound }
        }
        let name = s[..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.caseInsensitiveCompare("Unknown artist") == .orderedSame { return nil }
        return name
    }

    struct Credit: Hashable, Sendable { var id: String?; var name: String; var thumbnails: [MusicThumbnail] }

    /// Who a song is credited to. A collaboration counts toward each linked artist; with no linked artists the lead name of the plain line is used.
    static func credits(for t: MusicTrack) -> [Credit] {
        if isLocal(t) {
            let line = t.artists.map(\.name).joined(separator: "; ")
            guard let n = LocalArtistName.primary(line) else { return [] }
            return [Credit(id: "LOCALARTIST:" + n, name: n, thumbnails: t.thumbnails)]
        }
        let linked = t.artists.filter { !$0.id.isEmpty && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        if !linked.isEmpty { return linked.map { Credit(id: $0.id, name: $0.name, thumbnails: $0.thumbnails) } }
        guard let n = leadName(t.artistLine) else { return [] }
        return [Credit(id: nil, name: n, thumbnails: [])]
    }
}

// MARK: - Local calendar maths

/// Day and hour numbers in the person's own calendar. Day 0 is 1970-01-01 local; the maths follows the zone's offset at that moment.
struct MusicDayMath: Sendable {
    var calendar: Calendar
    init(calendar: Calendar = .current) { self.calendar = calendar }

    private func local(_ d: Date) -> Double { d.timeIntervalSince1970 + Double(calendar.timeZone.secondsFromGMT(for: d)) }
    func day(_ d: Date) -> Int { Int((local(d) / 86_400).rounded(.down)) }
    func hour(_ d: Date) -> Int { let s = local(d); return Int(((s - (s / 86_400).rounded(.down) * 86_400) / 3_600).rounded(.down)) }
    /// A running hour number: day * 24 + hour.
    func hourIndex(_ d: Date) -> Int { day(d) * 24 + hour(d) }
    /// 0 = Sunday ... 6 = Saturday. Day 0 (1970-01-01) was a Thursday.
    static func weekday(ofDay day: Int) -> Int { (((day + 4) % 7) + 7) % 7 }
}

// MARK: - Data

struct MusicListenRow: Codable, Hashable, Sendable { var id: Int64; var uid: String; var at: Date; var secs: Int }
struct MusicRollupCell: Codable, Hashable, Sendable { var day: Int; var hour: Int; var uid: String; var plays: Int; var secs: Int }
struct MusicSongEntry: Codable, Hashable, Sendable { var track: MusicTrack; var firstAt: Date }

struct MusicStatsFile: Codable, Sendable, Equatable {
    var nextID: Int64 = 1
    var listens: [MusicListenRow] = []
    var rollups: [MusicRollupCell] = []
    var songs: [String: MusicSongEntry] = [:]
    var firstAt: Date?
    var migratedHistory = false

    init() {}
    private enum CodingKeys: String, CodingKey { case nextID, listens, rollups, songs, firstAt, migratedHistory }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nextID = try c.decodeIfPresent(Int64.self, forKey: .nextID) ?? 1
        listens = try c.decodeIfPresent([MusicListenRow].self, forKey: .listens) ?? []
        rollups = try c.decodeIfPresent([MusicRollupCell].self, forKey: .rollups) ?? []
        songs = try c.decodeIfPresent([String: MusicSongEntry].self, forKey: .songs) ?? [:]
        firstAt = try c.decodeIfPresent(Date.self, forKey: .firstAt)
        migratedHistory = try c.decodeIfPresent(Bool.self, forKey: .migratedHistory) ?? false
    }
    static func == (a: Self, b: Self) -> Bool { a.nextID == b.nextID && a.listens.count == b.listens.count && a.rollups.count == b.rollups.count && a.songs.count == b.songs.count }

    var isEmpty: Bool { listens.isEmpty && rollups.isEmpty }

    /// Folds the oldest rows into rollups once the cap is passed. Returns whether anything was folded.
    @discardableResult
    mutating func foldIfNeeded(cap: Int = MusicStatsRules.playCap, batch: Int = MusicStatsRules.foldBatch, math: MusicDayMath) -> Bool {
        guard listens.count > cap else { return false }
        let keep = max(0, cap - batch)
        let oldest = listens.sorted { $0.at < $1.at }
        let fold = oldest.prefix(oldest.count - keep)
        var index: [String: Int] = [:]
        for (i, c) in rollups.enumerated() { index["\(c.day)|\(c.hour)|\(c.uid)"] = i }
        for r in fold {
            let d = math.day(r.at), h = math.hour(r.at), k = "\(d)|\(h)|\(r.uid)"
            if let i = index[k] { rollups[i].plays += 1; rollups[i].secs += r.secs }
            else { index[k] = rollups.count; rollups.append(MusicRollupCell(day: d, hour: h, uid: r.uid, plays: 1, secs: r.secs)) }
        }
        listens = Array(oldest.suffix(keep))
        return true
    }
}

// MARK: - Play counting state machine

/// Decides when a play counts and how much time was heard. Pure: feed it the player's position a few times a second.
struct MusicPlayCounter: Sendable {
    enum Event: Equatable, Sendable {
        /// The play counted now; `secs` is the time heard so far.
        case counted(secs: Int)
        /// Rewrite the row's time (every 30 s more, on pause, when the track ends or restarts).
        case update(secs: Int)
    }

    private(set) var uid: String?
    private(set) var heard: TimeInterval = 0
    private(set) var latched = false
    private var lastPosition: TimeInterval?
    private var lastWritten = 0
    private var wasPlaying = false

    var heardSeconds: Int { Int(heard) }

    /// Starts a new track. The caller settles the previous play first with `finish()`.
    mutating func start(uid: String?) { self = MusicPlayCounter(); self.uid = uid }

    mutating func tick(position: TimeInterval, duration: TimeInterval, isPlaying: Bool) -> [Event] {
        guard uid != nil else { return [] }
        var out: [Event] = []
        // Repeat-one starts the same track over: settle the old play, the next crossing is a new one.
        if let last = lastPosition, latched, position < 1.5, last > 5 {
            out.append(.update(secs: heardSeconds))
            heard = 0; latched = false; lastWritten = 0
        }
        if isPlaying, let last = lastPosition {
            let step = position - last
            if step > 0 && step < MusicStatsRules.maxTickStep { heard += step }
        }
        lastPosition = position
        if !isPlaying, wasPlaying, latched, heardSeconds != lastWritten { out.append(.update(secs: heardSeconds)); lastWritten = heardSeconds }
        wasPlaying = isPlaying
        if !latched {
            if position >= MusicStatsRules.playThreshold(duration: duration) {
                latched = true; lastWritten = heardSeconds
                out.append(.counted(secs: heardSeconds))
            }
        } else if heardSeconds - lastWritten >= MusicStatsRules.writeEverySeconds {
            lastWritten = heardSeconds
            out.append(.update(secs: heardSeconds))
        }
        return out
    }

    /// Settles the play when the track ends, changes or the app quits.
    mutating func finish() -> Event? {
        defer { self = MusicPlayCounter() }
        guard uid != nil, latched, heardSeconds != lastWritten else { return nil }
        return .update(secs: heardSeconds)
    }
}

// MARK: - Report

enum MusicStatsRange: String, CaseIterable, Identifiable, Sendable {
    case week, month, year, all
    var id: String { rawValue }
    var title: String { switch self { case .week: "7 days"; case .month: "30 days"; case .year: "12 months"; case .all: "All time" } }

    /// Local midnight: 6 days back (7 counting today), 29 back (30), the 1st of the month 11 months back (12 calendar months), or nil for all.
    func start(now: Date, calendar: Calendar = .current) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .week: return calendar.date(byAdding: .day, value: -6, to: today)
        case .month: return calendar.date(byAdding: .day, value: -29, to: today)
        case .year:
            let first = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
            return calendar.date(byAdding: .month, value: -11, to: first)
        case .all: return nil
        }
    }
}

struct MusicTopSong: Hashable, Sendable, Identifiable { var track: MusicTrack; var plays: Int; var secs: Int; var id: String { track.uid } }
struct MusicTopArtist: Hashable, Sendable, Identifiable {
    var id: String; var name: String; var thumbnails: [MusicThumbnail]; var plays: Int; var secs: Int
    /// The artist's provider id when the credit was linked (nil for a plain-line credit or a local file).
    var linkedID: String?
    /// The source `linkedID` belongs to ("" without one). An id means nothing without its source.
    var providerID: String = ""
}
struct MusicTopAlbum: Hashable, Sendable, Identifiable { var id: String; var title: String; var artist: String; var thumbnails: [MusicThumbnail]; var plays: Int; var secs: Int; var album: MusicAlbumRef? }

struct MusicStatsReport: Sendable {
    var totalSecs = 0
    var plays = 0
    var songs = 0
    var newSongs = 0
    var artists = 0
    var currentStreak = 0
    var bestStreak = 0
    var prevSecs = 0
    var firstAt: Date?
    var allTime = true
    /// Seconds per local day (only days with plays), keyed by day number.
    var days: [Int: Int] = [:]
    /// [weekday 0 = Sunday][hour 0...23] seconds.
    var hours: [[Int]] = Array(repeating: Array(repeating: 0, count: 24), count: 7)
    var topSongs: [MusicTopSong] = []
    var topArtists: [MusicTopArtist] = []
    var topAlbums: [MusicTopAlbum] = []
    var windowStartDay: Int?
    var todayDay = 0

    // Derived figures the view shows.
    /// Morning 05-12, afternoon 12-17, evening 17-22, night 22-05.
    var dayparts: [Int] {
        var p = [0, 0, 0, 0]
        for wd in 0..<7 { for h in 0..<24 { p[Self.daypart(hour: h)] += hours[wd][h] } }
        return p
    }
    static func daypart(hour: Int) -> Int { hour >= 5 && hour < 12 ? 0 : hour >= 12 && hour < 17 ? 1 : hour >= 17 && hour < 22 ? 2 : 3 }
    /// Weekday and hour are summed independently so one long Friday night does not decide both. Ties go to the first index.
    var busiestWeekday: Int? { let s = hours.map { $0.reduce(0, +) }; return Self.argmax(s) }
    var busiestHour: Int? { Self.argmax((0..<24).map { h in (0..<7).reduce(0) { $0 + hours[$1][h] } }) }
    private static func argmax(_ v: [Int]) -> Int? {
        guard let m = v.max(), m > 0 else { return nil }
        return v.firstIndex(of: m)
    }
    /// Percent change against the window of equal length just before, nil when there is nothing to compare.
    var changePercent: Int? {
        guard !allTime, prevSecs > 0 else { return nil }
        return Int((Double(totalSecs - prevSecs) / Double(prevSecs) * 100).rounded())
    }
    /// 0 none ... 4 busiest: ceil(share of the busiest cell x 4).
    func heatLevel(weekday: Int, hour: Int) -> Int {
        let peak = hours.flatMap { $0 }.max() ?? 0
        let v = hours[weekday][hour]
        guard peak > 0, v > 0 else { return 0 }
        return min(4, Int((Double(v) / Double(peak) * 4).rounded(.up)))
    }
}

// MARK: - Engine

enum MusicStatsEngine {
    struct Cell { var idx: Int; var day: Int; var hour: Int; var uid: String; var plays: Int; var secs: Int }

    static func cells(_ f: MusicStatsFile, math: MusicDayMath) -> [Cell] {
        var out: [Cell] = []
        out.reserveCapacity(f.listens.count + f.rollups.count)
        for r in f.listens { let d = math.day(r.at), h = math.hour(r.at); out.append(Cell(idx: d * 24 + h, day: d, hour: h, uid: r.uid, plays: 1, secs: r.secs)) }
        for c in f.rollups { out.append(Cell(idx: c.day * 24 + c.hour, day: c.day, hour: c.hour, uid: c.uid, plays: c.plays, secs: c.secs)) }
        return out
    }

    /// Current run (ending today or yesterday) and the longest run ever, from the set of local day numbers that had a play.
    static func streaks(days: Set<Int>, today: Int) -> (current: Int, best: Int) {
        guard !days.isEmpty else { return (0, 0) }
        var best = 0, run = 0, prev: Int?
        for d in days.sorted() {
            run = (prev.map { d == $0 + 1 } ?? false) ? run + 1 : 1
            best = max(best, run); prev = d
        }
        var start = days.contains(today) ? today : (days.contains(today - 1) ? today - 1 : nil)
        var current = 0
        while let s = start, days.contains(s) { current += 1; start = s - 1 }
        return (current, best)
    }

    struct SongAgg { var track: MusicTrack; var plays: Int; var secs: Int; var firstAt: Date }

    static func report(_ f: MusicStatsFile, since: Date?, now: Date, calendar: Calendar = .current) -> MusicStatsReport {
        let math = MusicDayMath(calendar: calendar)
        var r = MusicStatsReport()
        r.todayDay = math.day(now)
        r.firstAt = f.firstAt
        let all = cells(f, math: math)
        let nowEnd = math.hourIndex(now) + 1
        let sinceIdx = since.map { math.hourIndex($0) } ?? Int.min
        r.allTime = since == nil || f.firstAt == nil || (since.map { $0 <= (f.firstAt ?? .distantFuture) } ?? true)
        if let s = since { r.windowStartDay = math.day(s) }
        // All time has no start, and subtracting Int.min would overflow.
        let span = since == nil ? 0 : nowEnd - sinceIdx
        var songAgg: [String: (plays: Int, secs: Int)] = [:]
        var daySet = Set<Int>()
        for c in all {
            daySet.insert(c.day)
            if c.idx >= sinceIdx && c.idx < nowEnd {
                r.totalSecs += c.secs; r.plays += c.plays
                r.days[c.day, default: 0] += c.secs
                r.hours[MusicDayMath.weekday(ofDay: c.day)][c.hour] += c.secs
                let e = songAgg[c.uid] ?? (0, 0)
                songAgg[c.uid] = (e.plays + c.plays, e.secs + c.secs)
            } else if !r.allTime, span > 0, c.idx >= sinceIdx - span, c.idx < sinceIdx {
                r.prevSecs += c.secs
            }
        }
        let st = streaks(days: daySet, today: r.todayDay)
        r.currentStreak = st.current; r.bestStreak = st.best

        var songs: [SongAgg] = []
        for (uid, a) in songAgg {
            guard let e = f.songs[uid], MusicStatsRules.isSong(e.track) else { continue }
            songs.append(SongAgg(track: e.track, plays: a.plays, secs: a.secs, firstAt: e.firstAt))
        }
        r.songs = songs.count
        if let s = since { r.newSongs = songs.filter { $0.firstAt >= s }.count }
        // Pictures come from the most heard song, so order by time then plays before crediting.
        let ordered = songs.sorted { $0.secs != $1.secs ? $0.secs > $1.secs : ($0.plays != $1.plays ? $0.plays > $1.plays : $0.track.uid < $1.track.uid) }
        r.topSongs = songs.sorted { $0.plays != $1.plays ? $0.plays > $1.plays : ($0.secs != $1.secs ? $0.secs > $1.secs : $0.track.uid < $1.track.uid) }
            .prefix(MusicStatsRules.topSongs).map { MusicTopSong(track: $0.track, plays: $0.plays, secs: $0.secs) }
        let artists = aggregateArtists(ordered)
        r.artists = artists.count
        r.topArtists = artists.sorted { $0.secs != $1.secs ? $0.secs > $1.secs : $0.plays > $1.plays }.prefix(MusicStatsRules.topArtists).map { $0 }
        r.topAlbums = aggregateAlbums(ordered).prefix(MusicStatsRules.topAlbums).map { $0 }
        return r
    }

    /// One row per lower-cased name and per id within its source (a renamed or localized channel is one row; two sources' artists that happen to share an id
    /// stay two). The picture is the first (most heard) song's.
    static func aggregateArtists(_ ordered: [SongAgg]) -> [MusicTopArtist] {
        var rows: [MusicTopArtist] = []
        var byName: [String: Int] = [:], byID: [String: Int] = [:]
        for s in ordered {
            var seen = Set<Int>()
            let local = MusicStatsRules.isLocal(s.track)
            for c in MusicStatsRules.credits(for: s.track) {
                let key = c.name.lowercased()
                let scoped = c.id.map { s.track.providerID + ":" + $0 }
                // A local file's artist is a name, never a page at a source: it counts, and links nowhere.
                let linked = local ? nil : c.id
                let i = scoped.flatMap { byID[$0] } ?? byName[key]
                let idx: Int
                if let i { idx = i } else {
                    idx = rows.count
                    rows.append(MusicTopArtist(id: scoped ?? "name:" + key, name: c.name, thumbnails: c.thumbnails.isEmpty ? s.track.thumbnails : c.thumbnails, plays: 0, secs: 0))
                }
                if rows[idx].linkedID == nil, let linked { rows[idx].linkedID = linked; rows[idx].providerID = s.track.providerID }
                byName[key] = idx
                if let scoped { byID[scoped] = idx }
                guard seen.insert(idx).inserted else { continue }
                rows[idx].plays += s.plays; rows[idx].secs += s.secs
            }
        }
        return rows
    }

    /// Albums need a linked album id and title; local files are left out. Artist is the first credited name.
    static func aggregateAlbums(_ ordered: [SongAgg]) -> [MusicTopAlbum] {
        var rows: [MusicTopAlbum] = [], index: [String: Int] = [:]
        for s in ordered where !MusicStatsRules.isLocal(s.track) {
            guard let a = s.track.album, !a.id.isEmpty, !a.title.isEmpty else { continue }
            let key = s.track.providerID + ":" + a.id
            if let i = index[key] { rows[i].plays += s.plays; rows[i].secs += s.secs; continue }
            index[key] = rows.count
            let artist = MusicStatsRules.credits(for: s.track).first?.name ?? a.artists.first?.name ?? ""
            rows.append(MusicTopAlbum(id: key, title: a.title, artist: artist, thumbnails: a.thumbnails.isEmpty ? s.track.thumbnails : a.thumbnails, plays: s.plays, secs: s.secs, album: a))
        }
        return rows.sorted { $0.secs != $1.secs ? $0.secs > $1.secs : $0.plays > $1.plays }
    }

    /// Most played songs in the trailing 30 days, then most recent, top 20, never local files. The latest stored record of the song wins.
    static func onRepeat(_ f: MusicStatsFile, now: Date, calendar: Calendar = .current) -> [MusicTrack] {
        guard let from = calendar.date(byAdding: .day, value: -MusicStatsRules.onRepeatDays, to: now) else { return [] }
        var agg: [String: (n: Int, last: Date)] = [:]
        for r in f.listens where r.at >= from && r.at <= now {
            let e = agg[r.uid] ?? (0, .distantPast)
            agg[r.uid] = (e.n + 1, max(e.last, r.at))
        }
        let ranked = agg.compactMap { uid, a -> (MusicTrack, Int, Date)? in
            guard let e = f.songs[uid], !MusicStatsRules.isLocal(e.track) else { return nil }
            return (e.track, a.n, a.last)
        }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : ($0.2 != $1.2 ? $0.2 > $1.2 : $0.0.uid < $1.0.uid) }
        return ranked.prefix(MusicStatsRules.onRepeatLimit).map(\.0)
    }

    /// Top artists over the whole history ranked by plays then time (Familiar artists on Home).
    static func familiarArtists(_ f: MusicStatsFile, limit: Int, calendar: Calendar = .current) -> [MusicTopArtist] {
        let math = MusicDayMath(calendar: calendar)
        var agg: [String: (Int, Int)] = [:]
        for c in cells(f, math: math) { let e = agg[c.uid] ?? (0, 0); agg[c.uid] = (e.0 + c.plays, e.1 + c.secs) }
        let songs = agg.compactMap { uid, a -> SongAgg? in
            guard let e = f.songs[uid], MusicStatsRules.isSong(e.track) else { return nil }
            return SongAgg(track: e.track, plays: a.0, secs: a.1, firstAt: e.firstAt)
        }.sorted { $0.secs != $1.secs ? $0.secs > $1.secs : $0.plays > $1.plays }
        let rows = aggregateArtists(songs).sorted { $0.plays != $1.plays ? $0.plays > $1.plays : $0.secs > $1.secs }
        return Array(rows.prefix(limit))
    }
}

// MARK: - Store

@MainActor @Observable
final class MusicStats {
    static let shared = MusicStats(directory: MusicStorage.root)

    /// Bumps whenever the data changes so a visible page can reload.
    private(set) var revision = 0
    private(set) var file: MusicStatsFile
    @ObservationIgnored private let store: MusicJSONStore<MusicStatsFile>
    @ObservationIgnored private let math: MusicDayMath
    @ObservationIgnored private var counter = MusicPlayCounter()
    @ObservationIgnored private var currentRowID: Int64?
    @ObservationIgnored private var currentTrack: MusicTrack?
    @ObservationIgnored private var poll: Task<Void, Never>?

    init(directory: URL, debounce: Duration = .seconds(5), calendar: Calendar = .current) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = MusicJSONStore<MusicStatsFile>(url: directory.appendingPathComponent("stats.json"), debounce: debounce)
        self.store = store
        self.math = MusicDayMath(calendar: calendar)
        self.file = store.load() ?? MusicStatsFile()
    }

    var hasAnyPlays: Bool { !file.isEmpty }

    // MARK: recording

    /// Writes one counted play. `secs` is the time heard so far.
    @discardableResult
    func recordCounted(_ track: MusicTrack, secs: Int, at: Date = Date()) -> Int64 {
        let id = file.nextID
        file.nextID += 1
        file.listens.append(MusicListenRow(id: id, uid: track.uid, at: at, secs: max(0, secs)))
        let first = file.songs[track.uid]?.firstAt ?? at
        var shown = track
        // The catalogue's spelling of the title and artist names (ids stay as they are).
        if let c = MusicCatalogNames.canonical(for: track), !c.title.isEmpty {
            shown.title = c.title
            if c.artists.count == shown.artists.count { for i in shown.artists.indices where !c.artists[i].isEmpty { shown.artists[i].name = c.artists[i] } }
        }
        file.songs[track.uid] = MusicSongEntry(track: shown, firstAt: min(first, at))
        if file.firstAt == nil || at < (file.firstAt ?? at) { file.firstAt = at }
        file.foldIfNeeded(math: math)
        changed()
        return id
    }

    func updateSecs(rowID: Int64, secs: Int) {
        guard let i = file.listens.lastIndex(where: { $0.id == rowID }) else { return }
        file.listens[i].secs = max(0, secs)
        changed()
    }

    private func changed() { revision += 1; store.save(file) }

    /// Brings in the old play history once (secs = playedMs / 1000), so nothing counted before this feature is lost.
    func importHistory(_ records: [PlayRecord]) {
        guard !file.migratedHistory else { return }
        file.migratedHistory = true
        let have = Set(file.listens.map { "\($0.uid)|\(Int($0.at.timeIntervalSince1970))" })
        var seen = have
        for r in records.sorted(by: { $0.at < $1.at }) {
            guard seen.insert("\(r.track.uid)|\(Int(r.at.timeIntervalSince1970))").inserted else { continue }
            file.listens.append(MusicListenRow(id: file.nextID, uid: r.track.uid, at: r.at, secs: Int(r.playedMs / 1000)))
            file.nextID += 1
            let first = file.songs[r.track.uid]?.firstAt ?? r.at
            file.songs[r.track.uid] = MusicSongEntry(track: r.track, firstAt: min(first, r.at))
            if file.firstAt == nil || r.at < (file.firstAt ?? r.at) { file.firstAt = r.at }
        }
        file.foldIfNeeded(math: math)
        changed()
    }

    // MARK: following the player

    /// Starts following the player. Safe to call again. The loop sleeps a full second while nothing plays.
    func attach(to player: MusicPlayer) {
        guard poll == nil else { return }
        poll = Task { [weak self, weak player] in
            while !Task.isCancelled {
                guard let self, let player else { return }
                self.follow(player)
                try? await Task.sleep(for: player.isPlaying ? .milliseconds(250) : .seconds(3))
            }
        }
    }

    func detach() { settle(); poll?.cancel(); poll = nil }

    private func follow(_ player: MusicPlayer) {
        let uid = player.current?.uid
        if uid != counter.uid {
            settle()
            counter.start(uid: uid)
            currentTrack = player.current
            currentRowID = nil
            if let t = player.current { apply(counter.tick(position: player.position, duration: player.duration, isPlaying: false), track: t) }
            return
        }
        guard let track = currentTrack else { return }
        apply(counter.tick(position: player.position, duration: player.duration, isPlaying: player.isPlaying), track: track)
    }

    /// Writes the time heard for the play in progress (called on quit, on track change and when detaching).
    func settle() {
        if let e = counter.finish(), let id = currentRowID { apply([e], track: nil, rowID: id) }
        currentRowID = nil
    }

    private func apply(_ events: [MusicPlayCounter.Event], track: MusicTrack?, rowID: Int64? = nil) {
        for e in events {
            switch e {
            case .counted(let secs):
                if let track, !MusicPrivateListening.shared.isOn { currentRowID = recordCounted(track, secs: secs) }
            case .update(let secs):
                if let id = rowID ?? currentRowID { updateSecs(rowID: id, secs: secs) }
            }
        }
    }

    // MARK: queries

    func report(range: MusicStatsRange, now: Date = Date()) -> MusicStatsReport {
        MusicStatsEngine.report(file, since: range.start(now: now, calendar: math.calendar), now: now, calendar: math.calendar)
    }
    func onRepeat(now: Date = Date()) -> [MusicTrack] { MusicStatsEngine.onRepeat(file, now: now, calendar: math.calendar) }
    func familiarArtists(limit: Int = 30) -> [MusicTopArtist] { MusicStatsEngine.familiarArtists(file, limit: limit, calendar: math.calendar) }
    /// True when On Repeat is worth offering as a shortcut tile.
    var onRepeatQualifies: Bool { onRepeat().count >= MusicStatsRules.onRepeatSeedMinimum }
    var calendar: Calendar { math.calendar }

    // MARK: control

    func flush() { settle(); store.flush() }

    /// Deletes every counted play and song record (and so empties On Repeat).
    func clear() {
        counter = MusicPlayCounter(); currentRowID = nil; currentTrack = nil
        let migrated = file.migratedHistory
        file = MusicStatsFile()
        file.migratedHistory = migrated
        store.delete()
        revision += 1
    }
}
