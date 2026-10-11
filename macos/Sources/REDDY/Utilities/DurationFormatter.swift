import Foundation

enum DurationFormatter {
    /// 7800 -> "2h 10m", 2700 -> "45m", 59 -> "1m"
    static func short(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(max(1, m))m"
    }

    /// 3725 -> "1:02:05", 125 -> "2:05"
    static func clock(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.rounded()))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

enum TimeFormatter {
    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
    static func dayAndTime(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }
}
