import Foundation

/// What a provider says about the subscription behind a playlist.
struct AccountStatus: Codable, Equatable, Sendable {
    var status: String
    /// When it ends; nil when the provider gives no end date (an unlimited account).
    var expires: Date?
    var maxConnections: Int?
    var activeConnections: Int?

    /// Whole days left (0 on the last day, negative once it has ended); nil without an end date.
    func daysLeft(now: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard let expires else { return nil }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: expires)).day
    }

    var isActive: Bool { status.lowercased() == "active" }

    enum Level: Equatable { case fine, soon, ended }

    /// Warn from a week out; "ended" when the provider says it is not active or the date has passed.
    func level(now: Date = Date()) -> Level {
        if !isActive { return .ended }
        guard let d = daysLeft(now: now) else { return .fine }
        return d < 0 ? .ended : (d <= 7 ? .soon : .fine)
    }

    /// "Ends 12 Dec 2026 (54 days left)", "Ends today", "Ended 3 days ago", "No end date".
    func summary(now: Date = Date()) -> String {
        if !isActive { return "Not active (\(status))" }
        guard let expires, let d = daysLeft(now: now) else { return "No end date" }
        let date = expires.formatted(date: .abbreviated, time: .omitted)
        switch d {
        case ..<(-1): return "Ended \(-d) days ago (\(date))"
        case -1: return "Ended yesterday (\(date))"
        case 0: return "Ends today (\(date))"
        case 1: return "Ends tomorrow (\(date))"
        default: return "Ends \(date) (\(d) days left)"
        }
    }
}
