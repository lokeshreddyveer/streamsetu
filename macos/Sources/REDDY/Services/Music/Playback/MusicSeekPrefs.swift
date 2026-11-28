import Foundation

/// How far the skip keys jump and when a long recording remembers where the person stopped. Plain UserDefaults values with safe defaults (10 seconds, 10 minutes).
enum MusicSeekPrefs {
    static let backKey = "music.seek.backSeconds"
    static let forwardKey = "music.seek.forwardSeconds"
    static let resumeKey = "music.resume.minMinutes"
    static let intervalChoices = [5, 10, 15, 30, 60]
    /// Recordings at least this many minutes long remember their place. 0 turns it off.
    static let resumeChoices = [0, 5, 10, 20, 30]
    static let defaultInterval = 10
    static let defaultResumeMinutes = 10

    private static func interval(_ key: String, _ d: UserDefaults) -> Int {
        let v = d.integer(forKey: key)
        return intervalChoices.contains(v) ? v : defaultInterval
    }
    static func backSeconds(_ d: UserDefaults = .standard) -> Double { Double(interval(backKey, d)) }
    static func forwardSeconds(_ d: UserDefaults = .standard) -> Double { Double(interval(forwardKey, d)) }
    static func resumeMinutes(_ d: UserDefaults = .standard) -> Int {
        guard d.object(forKey: resumeKey) != nil else { return defaultResumeMinutes }
        let v = d.integer(forKey: resumeKey)
        return resumeChoices.contains(v) ? v : defaultResumeMinutes
    }
}

/// A place a long recording was left.
struct MusicResumePoint: Codable, Equatable, Sendable {
    var position: Double
    var duration: Double
    var savedAt: Date
}

/// When a recording remembers its place and when that place is used. Pure.
enum MusicResumeRules {
    /// Nearer the start than this is not worth resuming, and nearer the end than `tail` counts as finished.
    static let minPosition = 15.0
    static let tail = 20.0
    static let maxPoints = 500
    static let maxAge: TimeInterval = 180 * 86_400

    static func shouldRemember(position: Double, duration: Double, minMinutes: Int) -> Bool {
        guard minMinutes > 0, duration.isFinite, position.isFinite, duration >= Double(minMinutes) * 60 else { return false }
        return position >= minPosition && position <= duration - tail
    }

    /// The saved place to start from, or nil when it is too early, too near the end, or the recording is no longer one that remembers.
    static func resumeAt(_ p: MusicResumePoint?, duration: Double, minMinutes: Int) -> Double? {
        guard let p, shouldRemember(position: p.position, duration: max(duration, p.duration), minMinutes: minMinutes) else { return nil }
        return p.position
    }

    /// Drops points older than `maxAge`, then the oldest beyond `maxPoints`.
    static func pruned(_ points: [String: MusicResumePoint], now: Date = Date()) -> [String: MusicResumePoint] {
        var out = points.filter { now.timeIntervalSince($0.value.savedAt) < maxAge }
        if out.count > maxPoints {
            let keep = out.sorted { $0.value.savedAt > $1.value.savedAt }.prefix(maxPoints)
            out = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        return out
    }
}
