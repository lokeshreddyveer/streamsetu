import Foundation

/// Every duration Music shows or reads, in one place: "3:45" text out, and clock text in (a YouTube length, a lyrics timestamp).
enum MusicTime {
    /// "3:45", or "1:02:05" from an hour up. Negative and non-finite values read as "0:00".
    static func clock(_ s: TimeInterval) -> String {
        guard s.isFinite else { return "0:00" }
        let t = max(0, Int(s)); let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
    static func clock(ms: Int64) -> String { clock(TimeInterval(max(0, ms)) / 1000) }

    /// "-1:23" for the time left; never negative when the position runs past the duration.
    static func remaining(position: TimeInterval, duration: TimeInterval) -> String { "-" + clock(max(0, duration - position)) }
    /// 0...1 for the progress bar; 0 while the length is unknown.
    static func fraction(position: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0, position.isFinite else { return 0 }
        return min(1, max(0, position / duration))
    }
    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: max(0, n), countStyle: .file) }

    /// Clock text to milliseconds: `1.241s`, `500ms`, `3:45`, `1:02:03.5`, or bare seconds. Nil when it is not a time.
    static func parseMs(_ raw: String?) -> Int64? {
        guard var s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        func num(_ x: String) -> Double? { Double(x) }
        if s.hasSuffix("ms") { s.removeLast(2); return num(s).map { Int64($0.rounded()) } }
        if s.hasSuffix("s") { s.removeLast(); return num(s).map { Int64(($0 * 1000).rounded()) } }
        if s.hasSuffix("m") { s.removeLast(); return num(s).map { Int64(($0 * 60_000).rounded()) } }
        if s.hasSuffix("h") { s.removeLast(); return num(s).map { Int64(($0 * 3_600_000).rounded()) } }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1: return num(parts[0]).map { Int64(($0 * 1000).rounded()) }
        case 2:
            guard let m = num(parts[0]), let sec = num(parts[1]) else { return nil }
            return Int64((m * 60_000 + sec * 1000).rounded())
        case 3, 4:
            guard let h = num(parts[0]), let m = num(parts[1]), let sec = num(parts[2]) else { return nil }
            return Int64((h * 3_600_000 + m * 60_000 + sec * 1000).rounded())
        default: return nil
        }
    }
}
