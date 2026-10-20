import Foundation

/// How much a kids profile may watch: a number of minutes a day, and hours of the night when nothing plays.
/// Kept on this device. Time is counted while something plays in that profile; a parent can add more time for the day with the profile's PIN.
struct ViewingLimit: Codable, Equatable, Sendable {
    /// Minutes allowed per day; 0 means no daily cap.
    var dailyMinutes = 0
    var bedtimeOn = false
    /// Minutes after midnight. The window may cross midnight (21:00 to 07:00).
    var bedtimeStart = 21 * 60
    var bedtimeEnd = 7 * 60

    var isOff: Bool { dailyMinutes == 0 && !bedtimeOn }

    /// True when `date` falls inside the bedtime window.
    func inBedtime(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard bedtimeOn, bedtimeStart != bedtimeEnd else { return false }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return bedtimeStart < bedtimeEnd ? (m >= bedtimeStart && m < bedtimeEnd) : (m >= bedtimeStart || m < bedtimeEnd)
    }

    /// When the bedtime window that contains `date` ends.
    func bedtimeEnds(after date: Date, calendar: Calendar = .current) -> Date {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        var day = calendar.startOfDay(for: date)
        if bedtimeStart > bedtimeEnd, m >= bedtimeStart { day = calendar.date(byAdding: .day, value: 1, to: day) ?? day }
        return calendar.date(byAdding: .minute, value: bedtimeEnd, to: day) ?? date
    }
}

/// Why nothing plays right now.
enum ViewingBlock: Equatable, Sendable {
    case dailyLimit
    case bedtime(until: Date)
}

/// Reads and writes each profile's limit and counts the time watched today.
struct ViewingLimits: @unchecked Sendable {
    /// Minutes a parent adds with the PIN when the day's time is used up.
    static let extraMinutes = 30
    private let defaults: UserDefaults
    private let calendar: Calendar

    init(defaults: UserDefaults = .standard, calendar: Calendar = .current) { self.defaults = defaults; self.calendar = calendar }

    private func limitKey(_ id: String) -> String { "viewingLimit.\(id)" }
    private func usageKey(_ id: String) -> String { "viewingUsed.\(id)" }
    private func dayString(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    func limit(for id: String) -> ViewingLimit {
        guard let data = defaults.data(forKey: limitKey(id)), let l = try? JSONDecoder().decode(ViewingLimit.self, from: data) else { return ViewingLimit() }
        return l
    }

    func set(_ limit: ViewingLimit, for id: String) {
        if limit.isOff { defaults.removeObject(forKey: limitKey(id)); return }
        if let data = try? JSONEncoder().encode(limit) { defaults.set(data, forKey: limitKey(id)) }
    }

    /// Seconds watched and extra seconds granted today. Yesterday's numbers are ignored.
    private func today(_ id: String, now: Date) -> (used: Double, extra: Double) {
        guard let d = defaults.dictionary(forKey: usageKey(id)), d["day"] as? String == dayString(now) else { return (0, 0) }
        return (d["used"] as? Double ?? 0, d["extra"] as? Double ?? 0)
    }

    private func store(_ id: String, used: Double, extra: Double, now: Date) {
        defaults.set(["day": dayString(now), "used": used, "extra": extra] as [String: Any], forKey: usageKey(id))
    }

    func secondsUsed(for id: String, now: Date = Date()) -> Double { today(id, now: now).used }

    func addUsage(_ seconds: Double, for id: String, now: Date = Date()) {
        guard seconds > 0 else { return }
        let t = today(id, now: now)
        store(id, used: t.used + seconds, extra: t.extra, now: now)
    }

    /// A parent adds time for today.
    func grantExtra(for id: String, minutes: Int = ViewingLimits.extraMinutes, now: Date = Date()) {
        let t = today(id, now: now)
        store(id, used: t.used, extra: t.extra + Double(minutes) * 60, now: now)
    }

    /// Seconds left today, or nil when there is no daily cap.
    func remaining(for id: String, now: Date = Date()) -> Double? {
        let l = limit(for: id)
        guard l.dailyMinutes > 0 else { return nil }
        let t = today(id, now: now)
        return max(0, Double(l.dailyMinutes) * 60 + t.extra - t.used)
    }

    /// What stops playback for this profile right now, if anything. Bedtime comes first because it can be waited out; the day's time can be extended.
    func block(for id: String, now: Date = Date()) -> ViewingBlock? {
        let l = limit(for: id)
        if l.inBedtime(now, calendar: calendar) { return .bedtime(until: l.bedtimeEnds(after: now, calendar: calendar)) }
        if let r = remaining(for: id, now: now), r <= 0 { return .dailyLimit }
        return nil
    }

    /// A short description for a settings row.
    static func summary(_ l: ViewingLimit) -> String {
        var parts: [String] = []
        if l.dailyMinutes > 0 { parts.append(l.dailyMinutes % 60 == 0 ? "\(l.dailyMinutes / 60) h a day" : "\(l.dailyMinutes) min a day") }
        if l.bedtimeOn { parts.append("none \(clock(l.bedtimeStart)) to \(clock(l.bedtimeEnd))") }
        return parts.isEmpty ? "No limits" : parts.joined(separator: ", ")
    }

    static func clock(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
}
