import Foundation

enum MusicAdditionKind: String, Codable, Sendable, CaseIterable {
    case song, album, artist, playlist, local
}

/// One row of the "Recently added" view: something the person added to their library, and when (nil when it was added before dates were kept).
struct MusicRecentItem: Identifiable, Equatable, Sendable {
    var kind: MusicAdditionKind
    var key: String                 // the uid (or id) of the song, album, artist, playlist or local file
    var title: String
    var subtitle: String
    var thumbnails: [MusicThumbnail]
    var addedAt: Date?
    /// Where it sat in its own list (0 = newest there); orders items that have no date.
    var order: Int
    var id: String { kind.rawValue + "|" + key }
}

enum MusicRecentlyAdded {
    /// The key a date is kept under.
    static func storageKey(_ kind: MusicAdditionKind, _ key: String) -> String { kind.rawValue + "|" + key }

    /// Newest first among the items with a date; the items with no date follow, in the order their own lists hold them (a like is stored newest first). Nothing is
    /// given an invented date.
    static func sorted(_ items: [MusicRecentItem]) -> [MusicRecentItem] {
        let dated = items.filter { $0.addedAt != nil }.sorted { (a: MusicRecentItem, b: MusicRecentItem) -> Bool in
            let da = a.addedAt ?? .distantPast, db = b.addedAt ?? .distantPast
            if da != db { return da > db }
            return a.order != b.order ? a.order < b.order : a.id < b.id
        }
        let undated = items.filter { $0.addedAt == nil }.sorted { (a: MusicRecentItem, b: MusicRecentItem) -> Bool in
            a.order != b.order ? a.order < b.order : a.id < b.id
        }
        return dated + undated
    }

    static func filter(_ items: [MusicRecentItem], kind: MusicAdditionKind?) -> [MusicRecentItem] { kind.map { k in items.filter { $0.kind == k } } ?? items }

    enum Age: Equatable, Sendable { case today, yesterday, days(Int), weeks(Int), months(Int), longAgo, earlier }

    /// How long ago, in words a row can show. No date is "earlier": it was added before dates were kept.
    static func age(of date: Date?, now: Date = Date(), calendar: Calendar = .current) -> Age {
        guard let date else { return .earlier }
        let start = calendar.startOfDay(for: date), today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        if days <= 0 { return .today }
        if days == 1 { return .yesterday }
        if days < 14 { return .days(days) }
        if days < 60 { return .weeks(days / 7) }
        if days < 365 { return .months(days / 30) }
        return .longAgo
    }
}
