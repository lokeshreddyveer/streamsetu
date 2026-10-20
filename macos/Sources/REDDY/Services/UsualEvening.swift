import Foundation
import UserNotifications

/// The time of day the person usually starts watching, and what they usually put on then. Learned from their own sessions on this device.
struct UsualPick: Equatable, Sendable {
    let itemID: String
    /// The hour the viewing usually starts, 0 to 23.
    let hour: Int
    /// On how many of the last days something was started around then.
    let days: Int
}

enum UsualEvening {
    /// Days looked back over, and the fewest different days that make a habit.
    static let lookBack: TimeInterval = 28 * 86400
    static let minimumDays = 4

    /// The hour with the most different days of viewing (within an hour either side), and the thing started most often in that window.
    static func pick(sessions: [(itemID: String, start: Date)], now: Date, calendar: Calendar = .current) -> UsualPick? {
        let recent = sessions.filter { now.timeIntervalSince($0.start) <= lookBack && $0.start <= now }
        guard recent.count >= minimumDays else { return nil }
        func window(_ h: Int) -> [(itemID: String, start: Date)] {
            recent.filter { let sh = calendar.component(.hour, from: $0.start); return min((sh - h + 24) % 24, (h - sh + 24) % 24) <= 1 }
        }
        var best: (hour: Int, days: Int)?
        for h in 0..<24 {
            let days = Set(window(h).map { calendar.startOfDay(for: $0.start) }).count
            if days >= minimumDays, days >= (best?.days ?? 0) { best = (h, days) }          // later hours win a tie: the evening
        }
        guard let best else { return nil }
        var counts: [String: (n: Int, last: Date)] = [:]
        for s in window(best.hour) {
            let base = s.itemID.components(separatedBy: "|catchup|").first ?? s.itemID
            let old = counts[base]
            counts[base] = ((old?.n ?? 0) + 1, max(old?.last ?? .distantPast, s.start))
        }
        guard let top = counts.max(by: { ($0.value.n, $0.value.last) < ($1.value.n, $1.value.last) }) else { return nil }
        return UsualPick(itemID: top.key, hour: best.hour, days: best.days)
    }

    static let enabledKey = "usualEvening.on"
    static let identifier = "streamsetu.usualevening"

    /// The next time ten minutes before `hour`, after `date`.
    static func nextFire(hour: Int, after date: Date, calendar: Calendar = .current) -> Date {
        var c = DateComponents(); c.hour = (hour + 23) % 24; c.minute = 50
        if hour == 0 { c.hour = 23 }
        return calendar.nextDate(after: date, matching: c, matchingPolicy: .nextTime) ?? date.addingTimeInterval(86400)
    }

    static func hourText(_ h: Int) -> String { String(format: "%02d:00", h) }

    private static var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") ? UNUserNotificationCenter.current() : nil
    }

    /// Replaces the pending reminder with one for the next usual time (or removes it).
    static func reschedule(pick: UsualPick?, title: String?, enabled: Bool, now: Date = Date()) async {
        guard let center else { return }
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        guard enabled, let pick else { return }
        let content = UNMutableNotificationContent()
        content.title = "Your usual time to watch is near"
        content.body = title.map { "Last time around \(hourText(pick.hour)): \($0)" } ?? "Around \(hourText(pick.hour)) is when you usually watch."
        content.sound = .default
        let fire = nextFire(hour: pick.hour, after: now)
        try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(60, fire.timeIntervalSince(now)), repeats: false)))
    }
}
