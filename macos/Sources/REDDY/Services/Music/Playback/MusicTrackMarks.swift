import Foundation
import Observation

// Per-song navigation marks: an A-B loop, named bookmarks, a custom start and end, and seconds to skip at the start (an intro) and the end (an outro).
// Kept by song id on this device only. The rules are pure; the player asks them four times a second and does what they say.

struct MusicTrackMark: Codable, Equatable, Sendable {
    struct Bookmark: Codable, Equatable, Identifiable, Sendable {
        var id = UUID()
        var name: String
        var at: Double
    }
    var loopA: Double?
    var loopB: Double?
    var loopOn = false
    /// Play from here instead of the start / stop here instead of the end.
    var start: Double?
    var end: Double?
    var skipIntro: Double?
    var skipOutro: Double?
    var bookmarks: [Bookmark] = []

    var isEmpty: Bool { loopA == nil && loopB == nil && start == nil && end == nil && skipIntro == nil && skipOutro == nil && bookmarks.isEmpty }
    var hasLoop: Bool { if let a = loopA, let b = loopB { return b > a + 0.5 } else { return false } }
}

enum MusicTrackMarkRules {
    enum Action: Equatable, Sendable { case none, seek(Double), advance }

    /// Where playback begins: the later of the custom start and the intro to skip, kept clear of the end. Nil when nothing moves it.
    static func startPosition(_ m: MusicTrackMark, duration: Double) -> Double? {
        let s = max(m.start ?? 0, m.skipIntro ?? 0)
        guard s > 0.5 else { return nil }
        if duration > 0, s >= duration - 1 { return nil }
        return s
    }

    /// Where playback stops: the earlier of the custom end and (length - outro). Nil when nothing cuts it short.
    static func endPosition(_ m: MusicTrackMark, duration: Double) -> Double? {
        var e: Double?
        if let x = m.end, x > 1 { e = x }
        if let o = m.skipOutro, o > 0.5, duration > o + 1 { e = min(e ?? .infinity, duration - o) }
        if let v = e, let s = startPosition(m, duration: duration), v <= s + 1 { return nil }
        return e
    }

    /// What the player should do at `position`. A loop wins over the end; a start the song has not reached yet seeks forward (once per load, so a deliberate
    /// seek back to 0:00 afterwards is respected).
    static func action(position: Double, mark m: MusicTrackMark, duration: Double) -> Action {
        if m.loopOn, m.hasLoop, let a = m.loopA, let b = m.loopB, position >= b { return .seek(a) }
        if let e = endPosition(m, duration: duration), position >= e { return .advance }
        return .none
    }

    /// The bookmark nearest before `position`, then after: for previous/next bookmark keys.
    static func neighbour(of position: Double, in marks: [MusicTrackMark.Bookmark], forward: Bool) -> MusicTrackMark.Bookmark? {
        let sorted = marks.sorted { $0.at < $1.at }
        return forward ? sorted.first { $0.at > position + 0.5 } : sorted.last { $0.at < position - 1.5 }
    }

    static func clock(_ s: Double) -> String {
        let t = max(0, Int(s.rounded()))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    /// "1:23", "83" or "1:02:03" typed by the person; nil when it is not a time.
    static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for p in parts {
            guard let v = Double(p), v >= 0 else { return nil }
            total = total * 60 + v
        }
        return total
    }
}

@MainActor @Observable
final class MusicTrackMarkStore {
    static let shared = MusicTrackMarkStore()
    static let key = "music.trackMarks.v1"
    static let maxSongs = 1000

    private(set) var marks: [String: MusicTrackMark]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        marks = (defaults.data(forKey: Self.key)).flatMap { try? JSONDecoder().decode([String: MusicTrackMark].self, from: $0) } ?? [:]
    }

    func mark(for uid: String) -> MusicTrackMark { marks[uid] ?? MusicTrackMark() }

    func edit(_ uid: String, _ change: (inout MusicTrackMark) -> Void) {
        var m = mark(for: uid)
        change(&m)
        if m.isEmpty { marks[uid] = nil } else { marks[uid] = m }
        if marks.count > Self.maxSongs, let drop = marks.keys.first(where: { $0 != uid }) { marks[drop] = nil }
        if let d = try? JSONEncoder().encode(marks) { defaults.set(d, forKey: Self.key) }
    }

    func clear(_ uid: String) { edit(uid) { $0 = MusicTrackMark() } }
}
