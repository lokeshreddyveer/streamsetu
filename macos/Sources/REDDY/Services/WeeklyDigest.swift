import Foundation
import UserNotifications

/// "Your week": what was watched in the last seven days, what is new, and what needs attention. Worked out on this device from the playback log,
/// the new-episode flags and the subscription dates. Nothing is sent anywhere.
struct WeeklyDigest: Equatable, Sendable {
    var thisWeek: TimeInterval = 0
    var lastWeek: TimeInterval = 0
    var sessions = 0
    var topTitle: String?
    var busiestHour: Int?
    var seriesWithNewEpisodes = 0
    /// One line per playlist that ends within a week or has ended.
    var subscriptionNotes: [String] = []

    var isEmpty: Bool { thisWeek == 0 && seriesWithNewEpisodes == 0 && subscriptionNotes.isEmpty }

    static func make(thisWeek: ViewingStatistics, last7Days previous: TimeInterval, seriesWithNewEpisodes: Int, subscriptionNotes: [String]) -> WeeklyDigest {
        let top = [thisWeek.topSeries.first, thisWeek.topMovies.first, thisWeek.topChannels.first].compactMap { $0 }.max { $0.seconds < $1.seconds }
        return WeeklyDigest(thisWeek: thisWeek.totalSeconds, lastWeek: previous, sessions: thisWeek.sessions, topTitle: top?.title, busiestHour: thisWeek.busiestHour,
                            seriesWithNewEpisodes: seriesWithNewEpisodes, subscriptionNotes: subscriptionNotes)
    }

    /// "5 h 20 min", "45 min", "0 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let m = Int((seconds / 60).rounded())
        return m >= 60 ? (m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min") : "\(m) min"
    }

    static func hour(_ h: Int) -> String { String(format: "%02d:00", h) }

    var headline: String {
        thisWeek == 0 ? "A quiet week" : "You watched \(Self.duration(thisWeek)) this week"
    }

    /// How this week compares with the one before, or nil when there is nothing to compare with.
    var comparison: String? {
        guard thisWeek > 0, lastWeek > 0 else { return nil }
        let diff = Int(((thisWeek - lastWeek) / lastWeek * 100).rounded())
        if abs(diff) < 5 { return "About the same as the week before" }
        return diff > 0 ? "\(diff)% more than the week before" : "\(-diff)% less than the week before"
    }

    /// The lines under the headline.
    var lines: [String] {
        var out: [String] = []
        if let c = comparison { out.append(c) }
        if let t = topTitle { out.append("Most watched: \(t)") }
        if let h = busiestHour, thisWeek > 0 { out.append("You mostly watch around \(Self.hour(h))") }
        if seriesWithNewEpisodes > 0 { out.append(seriesWithNewEpisodes == 1 ? "New episodes are waiting in 1 series" : "New episodes are waiting in \(seriesWithNewEpisodes) series") }
        out.append(contentsOf: subscriptionNotes)
        return out
    }

    /// The text of the Sunday notification.
    var notificationBody: String {
        let parts = lines.prefix(3)
        return parts.isEmpty ? headline : parts.joined(separator: ". ")
    }
}

/// Schedules the Sunday evening notification. It is a local notification, written with the numbers as they were when the app was last open
/// and replaced each time the app starts, so it is only as fresh as the last time the app was used that week.
enum WeeklyDigestSchedule {
    static let enabledKey = "weeklyDigest.on"
    static let identifier = "streamsetu.weeklydigest"

    /// The next Sunday at 18:00 after `date`.
    static func nextFire(after date: Date, calendar: Calendar = .current) -> Date {
        var c = DateComponents(); c.weekday = 1; c.hour = 18; c.minute = 0
        return calendar.nextDate(after: date, matching: c, matchingPolicy: .nextTime) ?? date.addingTimeInterval(7 * 86400)
    }

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: enabledKey) }

    private static var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") ? UNUserNotificationCenter.current() : nil
    }

    /// Replaces the pending digest notification with one for the next Sunday, or removes it when the digest is off.
    static func reschedule(digest: WeeklyDigest, enabled: Bool, now: Date = Date()) async {
        guard let center else { return }
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        guard enabled else { return }
        let fire = nextFire(after: now)
        let content = UNMutableNotificationContent()
        content.title = digest.headline
        content.body = digest.notificationBody
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(60, fire.timeIntervalSince(now)), repeats: false)
        try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }
}
