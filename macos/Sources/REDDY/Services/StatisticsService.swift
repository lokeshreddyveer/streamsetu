import Foundation

/// What the person has watched, worked out from the playback sessions on this Mac. They belong to the device, not to a profile: everyone who uses it is counted together.
/// With iCloud sync on, the sessions of the person's other devices arrive too, so the figures cover all of them.
struct ViewingStatistics: Equatable, Sendable {
    struct Day: Equatable, Sendable { let date: Date; let seconds: TimeInterval }
    struct Top: Equatable, Sendable, Identifiable { let id: String; let title: String; let seconds: TimeInterval; let plays: Int }

    var totalSeconds: TimeInterval = 0
    var sessions = 0
    var longestSession: TimeInterval = 0
    /// Last 14 days, oldest first, every day present (zero when nothing was watched).
    var days: [Day] = []
    /// Seconds watched in each hour of the day, 0…23.
    var hours: [TimeInterval] = Array(repeating: 0, count: 24)
    var liveSeconds: TimeInterval = 0
    var movieSeconds: TimeInterval = 0
    var seriesSeconds: TimeInterval = 0
    var topChannels: [Top] = []
    var topMovies: [Top] = []
    var topSeries: [Top] = []

    var averageSession: TimeInterval { sessions == 0 ? 0 : totalSeconds / Double(sessions) }
    var busiestHour: Int? { hours.enumerated().max { $0.element < $1.element }.flatMap { $0.element > 0 ? $0.offset : nil } }
    var isEmpty: Bool { sessions == 0 }
}

final class StatisticsService: Sendable {
    /// A single session counts for at most this long, so a stream left on overnight doesn't distort everything.
    static let maxSession: TimeInterval = 12 * 3600
    private let db: DatabaseManager
    private let catalog: CatalogRepository

    init(db: DatabaseManager, catalog: CatalogRepository) { self.db = db; self.catalog = catalog }

    struct Row: Sendable { let itemID: String; let start: Date; let end: Date }

    func compute(since: Date?, now: Date = Date(), calendar: Calendar = .current) throws -> ViewingStatistics {
        let rows: [Row] = try db.read { c in
            var sql = "SELECT item_id, started_at, ended_at FROM playback_sessions WHERE ended_at IS NOT NULL AND ended_at > started_at"
            var args: [(any SQLConvertible)?] = []
            if let since { sql += " AND started_at >= ?"; args.append(since) }
            return try c.query(sql, args) { Row(itemID: $0.string(0), start: $0.date(1), end: $0.date(2)) }
        }
        return Self.aggregate(rows, now: now, calendar: calendar, resolve: { [catalog] ids in Self.resolve(ids, catalog: catalog) })
    }

    /// Every finished session since `since`, oldest first.
    func sessions(since: Date) throws -> [Row] {
        try db.read { c in
            try c.query("SELECT item_id, started_at, ended_at FROM playback_sessions WHERE ended_at IS NOT NULL AND ended_at > started_at AND started_at >= ? ORDER BY started_at", [since]) { Row(itemID: $0.string(0), start: $0.date(1), end: $0.date(2)) }
        }
    }

    func clear() throws { try db.write { try $0.execute("DELETE FROM playback_sessions") } }

    // MARK: aggregation (pure apart from the resolver)

    enum Kind { case live, movie, series }

    /// `resolve` turns item ids into (kind, title); ids it can't resolve (removed from the library, or hidden by a PIN lock) count
    /// towards the totals but never appear in the top lists.
    static func aggregate(_ rows: [Row], now: Date, calendar: Calendar, resolve: ([String]) -> [String: (Kind, String)]) -> ViewingStatistics {
        var s = ViewingStatistics()
        var perItem: [String: (seconds: TimeInterval, plays: Int)] = [:]
        let today = calendar.startOfDay(for: now)
        var perDay: [Date: TimeInterval] = [:]
        for r in rows {
            let d = min(r.end.timeIntervalSince(r.start), maxSession)
            guard d > 1 else { continue }
            s.totalSeconds += d; s.sessions += 1; s.longestSession = max(s.longestSession, d)
            let base = r.itemID.components(separatedBy: "|catchup|").first ?? r.itemID           // catch-up counts for its channel
            perItem[base, default: (0, 0)].seconds += d; perItem[base, default: (0, 0)].plays += 1
            perDay[calendar.startOfDay(for: r.start), default: 0] += d
            // spread over the hours it covered
            var t = r.start, left = d
            while left > 0 {
                let hour = calendar.component(.hour, from: t)
                let nextHour = calendar.date(byAdding: .hour, value: 1, to: calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour], from: t))!)!
                let slice = min(left, nextHour.timeIntervalSince(t))
                s.hours[hour] += slice; left -= slice; t = t.addingTimeInterval(slice)
            }
        }
        s.days = (0..<14).reversed().compactMap { back in calendar.date(byAdding: .day, value: -back, to: today).map { ViewingStatistics.Day(date: $0, seconds: perDay[$0] ?? 0) } }
        let known = resolve(Array(perItem.keys))
        var live: [ViewingStatistics.Top] = [], movies: [ViewingStatistics.Top] = [], series: [String: (TimeInterval, Int)] = [:]
        for (id, v) in perItem {
            guard let (kind, title) = known[id] else { continue }
            switch kind {
            case .live: s.liveSeconds += v.seconds; live.append(.init(id: id, title: title, seconds: v.seconds, plays: v.plays))
            case .movie: s.movieSeconds += v.seconds; movies.append(.init(id: id, title: title, seconds: v.seconds, plays: v.plays))
            case .series: s.seriesSeconds += v.seconds; series[title, default: (0, 0)].0 += v.seconds; series[title, default: (0, 0)].1 += v.plays
            }
        }
        func top(_ l: [ViewingStatistics.Top]) -> [ViewingStatistics.Top] { Array(l.sorted { ($0.seconds, $1.title) > ($1.seconds, $0.title) }.prefix(8)) }
        s.topChannels = top(live); s.topMovies = top(movies)
        s.topSeries = top(series.map { .init(id: $0.key, title: $0.key, seconds: $0.value.0, plays: $0.value.1) })
        return s
    }

    private static func resolve(_ ids: [String], catalog: CatalogRepository) -> [String: (Kind, String)] {
        var out: [String: (Kind, String)] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 400).map({ Array(ids[$0..<min($0 + 400, ids.count)]) }) {
            for c in (try? catalog.channels({ var q = ChannelQuery(); q.collapseVariants = false; q.includeHidden = true; q.ids = chunk; return q }())) ?? [] { out[c.id] = (.live, c.name) }
            for m in (try? catalog.movies({ var q = VODQuery(); q.includeHidden = true; q.ids = chunk; return q }())) ?? [] { out[m.id] = (.movie, m.title) }
        }
        for id in ids where out[id] == nil {
            if let e = try? catalog.episode(id: id), let s = try? catalog.seriesItem(id: e.seriesID) { out[id] = (.series, s.title) }
        }
        return out
    }
}
