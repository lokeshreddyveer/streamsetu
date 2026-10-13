import Foundation

/// How long streams take to start, and how often they fail, for each playlist and player. It lives only on this device and holds numbers,
/// never titles or addresses. It feeds the Playback Health page and one suggestion: use the other player for this playlist.
final class StartStats: @unchecked Sendable {
    static let shared = StartStats()

    struct Record: Codable, Equatable {
        var plays = 0
        var totalSeconds = 0.0
        var slowest = 0.0
        var failures = 0
        var lastAt = Date.distantPast
        var average: Double { plays > 0 ? totalSeconds / Double(plays) : 0 }
    }

    struct Row: Identifiable, Equatable {
        let source: UUID
        let engine: String
        let live: Bool
        let record: Record
        var id: String { "\(source)|\(engine)|\(live)" }
    }

    private static let key = "startstats.v1"
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var table: [String: Record]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let t = try? JSONDecoder().decode([String: Record].self, from: data) { table = t } else { table = [:] }
    }

    private static func key(_ source: UUID, _ engine: PlaybackEngineKind, _ live: Bool) -> String { "\(source.uuidString)|\(engine.rawValue)|\(live ? "live" : "vod")" }

    /// A stream reached its first picture `seconds` after the tap (retries included, since that is what the person waited).
    func recordStart(source: UUID, engine: PlaybackEngineKind, live: Bool, seconds: Double, now: Date = Date()) {
        guard seconds >= 0, seconds < 600 else { return }
        update(Self.key(source, engine, live)) { r in
            r.plays += 1; r.totalSeconds += seconds; r.slowest = max(r.slowest, seconds); r.lastAt = now
        }
    }

    /// A stream gave up for good.
    func recordFailure(source: UUID, engine: PlaybackEngineKind, live: Bool, now: Date = Date()) {
        update(Self.key(source, engine, live)) { r in r.failures += 1; r.lastAt = now }
    }

    private func update(_ k: String, _ change: (inout Record) -> Void) {
        lock.withLock {
            var r = table[k] ?? Record()
            change(&r)
            table[k] = r
            if let data = try? JSONEncoder().encode(table) { defaults.set(data, forKey: Self.key) }
        }
    }

    func rows() -> [Row] {
        lock.withLock {
            table.compactMap { k, v in
                let p = k.split(separator: "|").map(String.init)
                guard p.count == 3, let id = UUID(uuidString: p[0]) else { return nil }
                return Row(source: id, engine: p[1], live: p[2] == "live", record: v)
            }.sorted { ($0.source.uuidString, $0.live ? 1 : 0, $0.engine) < ($1.source.uuidString, $1.live ? 1 : 0, $1.engine) }
        }
    }

    func reset() { lock.withLock { table = [:]; defaults.removeObject(forKey: Self.key) } }

    /// Suggests the player that starts movies and episodes clearly faster for a playlist, once both have been tried enough.
    /// Never for live TV (it already uses the faster player), and never when the difference is small.
    static func suggestion(rows: [Row], source: UUID) -> (engine: PlaybackEngineKind, fasterBy: Double, other: Double)? {
        let vod = rows.filter { $0.source == source && !$0.live && $0.record.plays >= 3 }
        guard let apple = vod.first(where: { $0.engine == PlaybackEngineKind.avPlayer.rawValue }),
              let mpv = vod.first(where: { $0.engine == PlaybackEngineKind.mpv.rawValue }) else { return nil }
        let a = apple.record.average, m = mpv.record.average
        if m + 4 <= a { return (.mpv, a - m, a) }
        if a + 4 <= m { return (.avPlayer, m - a, m) }
        return nil
    }
}
