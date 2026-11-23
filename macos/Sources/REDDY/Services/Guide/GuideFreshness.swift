import Foundation

/// How fresh a guide source is, and the warning to show. Pure; `epg/fixtures/freshness-cases.json` pins it for both platforms.
/// Each message is a key into a shared plain-language table (`GuideMessages`), so Swift and Kotlin say the same thing.
enum GuideFreshnessLevel: String, Sendable, Equatable, Comparable {
    case fresh, info, warning, error
    private var rank: Int { switch self { case .fresh: 0; case .info: 1; case .warning: 2; case .error: 3 } }
    static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

struct GuideFreshnessInput: Sendable, Equatable {
    var now: Date
    var enabled = true
    /// End of the last programme the source holds.
    var windowEnd: Date?
    var lastSuccess: Date?
    var lastAttemptFailed = false
    var refreshInterval: TimeInterval = 6 * 3600
    var programmes = 0
}

struct GuideFreshness: Sendable, Equatable {
    var level: GuideFreshnessLevel
    var key: String
    /// Whole hours or days for the message ("Guide ends in 6 h").
    var amount: Int?
    var endingSoon: Bool { key == "guide.endsUnder3h" || key == "guide.endsIn" }
    var stale: Bool { key == "guide.updatedLongAgo" }

    static func evaluate(_ i: GuideFreshnessInput) -> GuideFreshness {
        guard i.enabled else { return GuideFreshness(level: .fresh, key: "guide.off", amount: nil) }
        guard let success = i.lastSuccess else { return GuideFreshness(level: i.lastAttemptFailed ? .error : .warning, key: "guide.neverUpdated", amount: nil) }
        if i.programmes == 0 { return GuideFreshness(level: .error, key: "guide.empty", amount: nil) }
        guard let end = i.windowEnd else { return GuideFreshness(level: .error, key: "guide.empty", amount: nil) }
        let left = end.timeIntervalSince(i.now)
        if left < 0 { return GuideFreshness(level: .error, key: "guide.noUpcoming", amount: nil) }
        let age = i.now.timeIntervalSince(success)
        let staleAfter = max(3 * i.refreshInterval, 24 * 3600)
        let overdue = age > i.refreshInterval * 1.5 || i.lastAttemptFailed
        if left < 3 * 3600 { return GuideFreshness(level: .warning, key: "guide.endsUnder3h", amount: nil) }
        if age > staleAfter { return GuideFreshness(level: .warning, key: "guide.updatedLongAgo", amount: Int(age / 86400)) }
        if left < 12 * 3600, overdue { return GuideFreshness(level: .info, key: "guide.endsIn", amount: Int(left / 3600)) }
        return GuideFreshness(level: .fresh, key: "guide.fresh", amount: Int(left / 3600))
    }
}

/// The plain-language strings, shared key for key with the Android table.
enum GuideMessages {
    static let text: [String: String] = [
        "guide.off": "This guide is switched off.",
        "guide.fresh": "Guide is up to date.",
        "guide.neverUpdated": "This guide has not been downloaded yet.",
        "guide.empty": "The guide holds no programmes.",
        "guide.noUpcoming": "The guide has no upcoming programmes.",
        "guide.endsUnder3h": "The guide ends in under 3 hours.",
        "guide.endsIn": "The guide ends in %d hours and a refresh is overdue.",
        "guide.updatedLongAgo": "The guide was last updated %d days ago.",
        "diag.neverFetched": "Nothing has been downloaded for this guide yet.",
        "diag.fetchFailed": "The last download failed: %@",
        "diag.emptyFile": "The guide file lists channels but contains no programmes. Your provider's guide is empty.",
        "diag.noChannels": "The guide file contains no channels or programmes.",
        "diag.allPast": "Every programme in the guide file has already ended (the newest ended %d days ago). The provider's guide file is out of date; refreshing will not help.",
        "diag.allFuture": "Every programme in the guide file is further ahead than the days kept. Increase the guide days or check the time zone.",
        "diag.invalidTimes": "None of the programmes in the guide file has readable times.",
        "diag.partlyOutside": "Most programmes in the guide file are outside the days kept (%d of %d).",
        "diag.noMapping": "The guide has programmes, but none of your channels is matched to it. Match channels in Channel Manager.",
        "diag.fewMapped": "Only %d of the guide's %d channels are matched to your channels.",
        "diag.truncated": "The guide download ended early; the part that arrived is used.",
        "diag.notModified": "The provider says the guide has not changed since the last download.",
        "diag.ok": "The guide looks healthy.",
    ]
}
