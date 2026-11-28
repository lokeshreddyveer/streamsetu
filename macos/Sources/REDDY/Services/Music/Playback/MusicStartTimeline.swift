import Foundation

/// The stages between pressing play and hearing the song, in the order they normally happen.
enum MusicStartStage: Int, CaseIterable, Sendable, Comparable {
    case press, searched, candidate, streamsListed, verified, resolved, proxyReady, proxyFirstByte, itemReady, firstSound

    var label: String {
        switch self {
        case .press: return "press"
        case .searched: return "search"
        case .candidate: return "candidate"
        case .streamsListed: return "streams"
        case .verified: return "verified"
        case .resolved: return "resolved"
        case .proxyReady: return "proxy"
        case .proxyFirstByte: return "first byte"
        case .itemReady: return "ready"
        case .firstSound: return "sound"
        }
    }

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// One start, as milliseconds since the press.
struct MusicStartReport: Sendable, Equatable {
    var offsets: [MusicStartStage: Double] = [:]
    var tags: [String] = []

    var timeToFirstSound: Double? { offsets[.firstSound] }

    /// Stages that happened, each with the time since the previous stage that happened.
    var steps: [(stage: MusicStartStage, atMs: Double, deltaMs: Double)] {
        var out: [(MusicStartStage, Double, Double)] = []
        var last = 0.0
        for s in offsets.keys.sorted() {
            let at = offsets[s] ?? 0
            out.append((s, at, max(0, at - last)))
            last = max(last, at)
        }
        return out
    }

    /// For example "search +310 / candidate +4 / streams +420 / verified +180 / sound +900 (cache hit)".
    var summary: String {
        var parts = steps.filter { $0.stage != .press }.map { "\($0.stage.label) +\(Int($0.deltaMs.rounded()))" }
        if parts.isEmpty { parts = ["no stages"] }
        let t = tags.isEmpty ? "" : " (" + tags.joined(separator: ", ") + ")"
        return parts.joined(separator: " / ") + t
    }

    /// The same, as cumulative milliseconds, which is what the matrix prints.
    var cumulative: String {
        let parts = steps.filter { $0.stage != .press }.map { "\($0.stage.label) \(Int($0.atMs.rounded()))" }
        return parts.joined(separator: " > ")
    }

    static func == (a: Self, b: Self) -> Bool { a.offsets == b.offsets && a.tags == b.tags }
}

/// Cheap per-track start timeline: monotonic timestamps behind one lock, newest tracks kept. Nothing is written to disk or sent anywhere.
/// The first stamp of a stage wins, so a retry cannot rewrite how the first attempt went.
final class MusicStartTimeline: @unchecked Sendable {
    static let shared = MusicStartTimeline()

    private struct Entry { var origin: UInt64; var stamps: [MusicStartStage: UInt64] = [:]; var tags: [String] = [] }

    private let lock = NSLock()
    private let clock: @Sendable () -> UInt64
    private let capacity: Int
    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    /// `clock` returns monotonic nanoseconds.
    init(capacity: Int = 24, clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.capacity = capacity
        self.clock = clock
    }

    /// The person pressed play on this track: starts a fresh timeline.
    func begin(_ key: String) {
        let t = clock()
        lock.withLock {
            if entries[key] == nil { order.append(key) }
            var e = Entry(origin: t)
            e.stamps[.press] = t
            entries[key] = e
            while order.count > capacity { entries[order.removeFirst()] = nil }
        }
    }

    /// Stamps a stage. A track with no press yet (a pre-resolve) is timed from its first stamp.
    func mark(_ key: String, _ stage: MusicStartStage) {
        let t = clock()
        lock.withLock {
            var e: Entry
            if let existing = entries[key] { e = existing } else {
                e = Entry(origin: t)
                order.append(key)
                while order.count > capacity { entries[order.removeFirst()] = nil }
            }
            if e.stamps[stage] == nil { e.stamps[stage] = t }
            entries[key] = e
        }
    }

    func tag(_ key: String, _ text: String) {
        lock.withLock {
            guard var e = entries[key], !e.tags.contains(text) else { return }
            e.tags.append(text)
            entries[key] = e
        }
    }

    func report(_ key: String) -> MusicStartReport? {
        lock.withLock {
            guard let e = entries[key] else { return nil }
            var r = MusicStartReport(tags: e.tags)
            for (s, t) in e.stamps { r.offsets[s] = Double(t &- e.origin) / 1_000_000 }
            return r
        }
    }

    func has(_ key: String, _ stage: MusicStartStage) -> Bool { lock.withLock { entries[key]?.stamps[stage] != nil } }

    func clear() { lock.withLock { entries = [:]; order = [] } }
}
