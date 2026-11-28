import Foundation

// History shown in day buckets worked out on this device from the person's own calendar: Today, Yesterday, the weekday names for the rest of the
// last week, Last week, then one heading per month. Boundaries are local midnight, the same boundary the listening stats use for a day.

struct MusicHistoryItem: Hashable, Sendable, Identifiable {
    /// Position in the full, unfiltered history. Playing from here queues the whole history, never just the filtered view.
    var index: Int
    var record: PlayRecord
    var id: String { "\(index)" }
}

struct MusicHistoryBucket: Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var items: [MusicHistoryItem]
}

enum MusicHistoryBuckets {
    /// Rows revealed per step while scrolling, counted across buckets.
    static let revealStep = 80

    /// Groups newest-first records. Order of the input is kept; empty buckets never appear.
    static func buckets(_ records: [PlayRecord], now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> [MusicHistoryBucket] {
        let today = calendar.startOfDay(for: now)
        var out: [MusicHistoryBucket] = []
        var byID: [String: Int] = [:]
        let weekdayFormat = DateFormatter(); weekdayFormat.calendar = calendar; weekdayFormat.timeZone = calendar.timeZone; weekdayFormat.locale = locale
        weekdayFormat.setLocalizedDateFormatFromTemplate("EEEE")
        let monthFormat = DateFormatter(); monthFormat.calendar = calendar; monthFormat.timeZone = calendar.timeZone; monthFormat.locale = locale
        monthFormat.setLocalizedDateFormatFromTemplate("LLLL yyyy")
        for (i, r) in records.enumerated() {
            let day = calendar.startOfDay(for: r.at)
            let ago = calendar.dateComponents([.day], from: day, to: today).day ?? 0
            let id: String, title: String
            switch ago {
            case ...0: id = "today"; title = String(localized: "Today")
            case 1: id = "yesterday"; title = String(localized: "Yesterday")
            case 2...6: id = "day-\(Int(day.timeIntervalSince1970))"; title = weekdayFormat.string(from: day)
            case 7...13: id = "last-week"; title = String(localized: "Last week")
            default:
                let c = calendar.dateComponents([.year, .month], from: day)
                id = "month-\(c.year ?? 0)-\(c.month ?? 0)"; title = monthFormat.string(from: day)
            }
            let item = MusicHistoryItem(index: i, record: r)
            if let b = byID[id] { out[b].items.append(item) } else { byID[id] = out.count; out.append(MusicHistoryBucket(id: id, title: title, items: [item])) }
        }
        return out
    }

    /// Case-insensitive substring over title, artist and album. Buckets with no match are hidden.
    static func filtered(_ buckets: [MusicHistoryBucket], query: String) -> [MusicHistoryBucket] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return buckets }
        return buckets.compactMap { b in
            let items = b.items.filter { MusicLibraryOrdering.matches($0.record.track, query: q) }
            return items.isEmpty ? nil : MusicHistoryBucket(id: b.id, title: b.title, items: items)
        }
    }

    /// The first `count` rows counted across buckets, for incremental rendering.
    static func limited(_ buckets: [MusicHistoryBucket], rows count: Int) -> [MusicHistoryBucket] {
        var left = max(0, count)
        var out: [MusicHistoryBucket] = []
        for b in buckets where left > 0 {
            let take = Array(b.items.prefix(left))
            left -= take.count
            out.append(MusicHistoryBucket(id: b.id, title: b.title, items: take))
        }
        return out
    }
}
