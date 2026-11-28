import Foundation

/// When Music first saw an item in Recently Added. This is not a release date and not a date the service added it: it is only the moment this app first showed it to the person, kept on this
/// device, so the page can group "found today / this week / this month" without inventing dates. Items first seen before the log existed simply have no entry.
struct MusicFirstSeenLog: Sendable {
    private(set) var seen: [String: Date]
    static let limit = 3000

    init(seen: [String: Date] = [:]) { self.seen = seen }

    static func key(_ item: MusicBrowseItem) -> String {
        switch item {
        case .track(let t): "t:" + t.providerID + ":" + t.id
        case .album(let a): "a:" + a.providerID + ":" + a.id
        case .playlist(let p): "p:" + p.providerID + ":" + p.id
        case .artist(let r): "r:" + r.providerID + ":" + r.id
        }
    }

    /// Records every item not seen before at `now`; items already known keep their first date. Oldest entries go when the log is full.
    mutating func record(_ items: [MusicBrowseItem], now: Date) {
        // An entry dated in the future (the clock was moved) is repaired to now instead of staying out of every group.
        for i in items { let k = Self.key(i); if seen[k] == nil || seen[k]! > now.addingTimeInterval(3600) { seen[k] = now } }
        if seen.count > Self.limit {
            let drop = seen.sorted { $0.value < $1.value }.prefix(seen.count - Self.limit).map(\.key)
            for k in drop { seen[k] = nil }
        }
    }

    enum Bucket: Int, CaseIterable, Sendable { case today, thisWeek, thisMonth }

    /// The group an item belongs to by its first-seen date, nil when it is older than a month or unknown.
    func bucket(_ item: MusicBrowseItem, now: Date, calendar: Calendar = .current) -> Bucket? {
        guard let d = seen[Self.key(item)], d <= now.addingTimeInterval(3600) else { return nil }   // a date in the future (a clock change) says nothing
        if calendar.isDate(d, inSameDayAs: now) { return .today }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: d), to: calendar.startOfDay(for: now)).day ?? 99
        if days < 7 { return .thisWeek }
        if days < 31 { return .thisMonth }
        return nil
    }

    // MARK: storage (this device only)
    private static let storeKey = "music.firstSeen.v1"
    static func load(_ defaults: UserDefaults = .standard) -> MusicFirstSeenLog {
        guard let data = defaults.data(forKey: storeKey), let m = try? JSONDecoder().decode([String: Date].self, from: data) else { return MusicFirstSeenLog() }
        return MusicFirstSeenLog(seen: m)
    }
    /// Writes what a page has just shown to disk for the next visit. A page that grouped by an earlier read of the log keeps that read: this never changes it.
    static func recordShown(_ items: [MusicBrowseItem], now: Date, defaults: UserDefaults = .standard) {
        var log = load(defaults)
        log.record(items, now: now)
        log.save(defaults)
    }
    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(seen) { defaults.set(data, forKey: Self.storeKey) }
    }
}
