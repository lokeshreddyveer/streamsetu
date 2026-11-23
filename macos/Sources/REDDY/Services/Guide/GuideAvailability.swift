import Foundation

/// The small indicator on a channel row or tile.
enum GuideAvailability: String, Sendable, Equatable {
    case none            // not matched: shown as nothing on long lists
    case mappedEmpty     // matched, but no programme in the next 3 hours
    case nowNext         // current and next programme known
    case stale           // matched, but the guide is out of date
    var showsDot: Bool { self == .nowNext || self == .stale }
    var accessibilityLabel: String { switch self { case .none: "No guide"; case .mappedEmpty: "Guide has no upcoming programmes"; case .nowNext: "Guide available"; case .stale: "Guide may be out of date" } }

    static func evaluate(mapped: Bool, programmesNext3h: Int, freshness: GuideFreshness?) -> GuideAvailability {
        guard mapped else { return .none }
        if programmesNext3h == 0 { return .mappedEmpty }
        if let f = freshness, f.level >= .warning { return .stale }
        return .nowNext
    }
}

/// Time correction applied when programmes are read (stored times stay as parsed). Precedence: channel offset > source offset.
enum GuideTimeShift {
    static func seconds(sourceMinutes: Int, channelMinutes: Int?) -> TimeInterval { TimeInterval((channelMinutes ?? sourceMinutes) * 60) }
    static func apply(_ start: Date, _ stop: Date, shift: TimeInterval) -> (Date, Date) { (start.addingTimeInterval(shift), stop.addingTimeInterval(shift)) }
    /// A hint, never applied automatically: the whole-hour offset that best explains a schedule whose "now" slot is empty but whose neighbours at +/- n hours are not.
    static func suggestedHourShift(median offsetSeconds: TimeInterval) -> Int? {
        let h = (offsetSeconds / 3600).rounded()
        return abs(offsetSeconds - h * 3600) < 600 && h != 0 && abs(h) <= 14 ? Int(h) : nil
    }
}

/// Logos from the public channel database for channels that have none of their own, found by channel name (the logo view is given a name, not an id). Memory only; rebuilt from `channel_enrichment`.
/// The playlist's own logo always wins, and the address is only ever loaded through the image cache.
enum GuideLogoOverlay {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var byName: [String: String] = [:]

    static func logo(forName name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return byName.isEmpty ? nil : byName[ChannelNormalizer.name(name).key]
    }
    static func reload(db: DatabaseManager) {
        let rows = (try? db.read { c in try c.query("SELECT c.name, e.logo_url FROM channel_enrichment e JOIN channels c ON c.id = e.channel_id WHERE e.logo_url IS NOT NULL AND (c.logo_url IS NULL OR c.logo_url = '')") { ($0.string(0), $0.string(1)) } }) ?? []
        var m: [String: String] = [:]
        for (n, u) in rows { m[ChannelNormalizer.name(n).key] = u }
        lock.lock(); byName = m; lock.unlock()
    }
}
