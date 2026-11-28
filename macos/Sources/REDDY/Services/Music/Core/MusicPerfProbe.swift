import Foundation
import Observation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

// A built-in responsiveness meter for the targets the owner set: a page opens in under 200 ms, a play press answers in under 100 ms, and the main thread never
// stalls for more than 50 ms (a dropped frame at 60 FPS is 16.7 ms). It watches the main run loop: each pass is timed, a long one is a "slow moment", and an
// action marked at its start (opening a page, pressing play) is finished at the next moment the main thread is idle. Numbers stay on this device and are only
// shown in Settings or copied by the person. The arithmetic is plain functions so it is tested without a screen.

enum MusicPerfBudget {
    static let pageOpenMs = 200.0
    static let playPressMs = 100.0
    static let slowMomentMs = 50.0
    static let frameMs = 1000.0 / 60.0

    enum Kind: String, Sendable, CaseIterable { case pageOpen, playPress, slowMoment }

    static func limit(_ k: Kind) -> Double {
        switch k { case .pageOpen: pageOpenMs; case .playPress: playPressMs; case .slowMoment: slowMomentMs }
    }

    static func exceeds(_ k: Kind, ms: Double) -> Bool { ms > limit(k) }
}

struct MusicPerfSample: Identifiable, Equatable, Sendable {
    var id = UUID()
    var kind: MusicPerfBudget.Kind
    var label: String
    var ms: Double
    var at: Date
}

struct MusicPerfSummary: Equatable, Sendable {
    var count = 0
    var overBudget = 0
    var median = 0.0
    var p95 = 0.0
    var worst = 0.0
}

enum MusicPerfStats {
    /// The value at fraction `p` (0...1) of the sorted list, by nearest rank. Zero for an empty list.
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        let i = Int((Double(s.count) * min(1, max(0, p))).rounded(.up)) - 1
        return s[min(s.count - 1, max(0, i))]
    }

    static func summary(_ samples: [MusicPerfSample], kind: MusicPerfBudget.Kind) -> MusicPerfSummary {
        let ms = samples.filter { $0.kind == kind }.map(\.ms)
        return MusicPerfSummary(count: ms.count, overBudget: ms.filter { MusicPerfBudget.exceeds(kind, ms: $0) }.count,
                                median: percentile(ms, 0.5), p95: percentile(ms, 0.95), worst: ms.max() ?? 0)
    }

    static func report(_ samples: [MusicPerfSample]) -> String {
        func line(_ title: String, _ k: MusicPerfBudget.Kind) -> String {
            let s = summary(samples, kind: k)
            return "\(title): \(s.count) measured, \(s.overBudget) over \(Int(MusicPerfBudget.limit(k))) ms, median \(Int(s.median)) ms, 95th \(Int(s.p95)) ms, worst \(Int(s.worst)) ms"
        }
        var out = [line("Page opens", .pageOpen), line("Play presses", .playPress), line("Slow moments", .slowMoment)]
        let worst = samples.sorted { $0.ms > $1.ms }.prefix(10)
        if !worst.isEmpty { out.append("Slowest:"); out += worst.map { "  \($0.kind.rawValue) \($0.label) \(Int($0.ms)) ms" } }
        return out.joined(separator: "\n")
    }
}

@MainActor @Observable
final class MusicPerfProbe {
    static let shared = MusicPerfProbe()
    static let capacity = 400

    private(set) var samples: [MusicPerfSample] = []
    @ObservationIgnored private var observer: CFRunLoopObserver?
    @ObservationIgnored private var passStart: CFAbsoluteTime = 0
    @ObservationIgnored private var pending: [(kind: MusicPerfBudget.Kind, label: String, start: CFAbsoluteTime)] = []

    /// Starts watching the main run loop. Safe to call again.
    func start() {
        guard observer == nil else { return }
        let activities: CFRunLoopActivity = [.afterWaiting, .beforeWaiting]
        let obs = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true, 0) { [weak self] _, activity in
            MainActor.assumeIsolated { self?.tick(activity) }
        }
        observer = obs
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
    }

    private func tick(_ activity: CFRunLoopActivity) {
        let now = CFAbsoluteTimeGetCurrent()
        if activity.contains(.afterWaiting) { passStart = now; return }
        // Before waiting: the pass is over and the main thread is about to be idle.
        if passStart > 0 {
            let ms = (now - passStart) * 1000
            if ms > MusicPerfBudget.slowMomentMs { add(.slowMoment, pending.first?.label ?? "", ms) }
        }
        guard !pending.isEmpty else { return }
        let done = pending
        pending.removeAll()
        for p in done { add(p.kind, p.label, (now - p.start) * 1000) }
    }

    /// An action starts now (a page is asked for, play is pressed). It is finished the next time the main thread is idle.
    func mark(_ kind: MusicPerfBudget.Kind, _ label: String) {
        guard kind != .slowMoment, pending.count < 8 else { return }
        pending.append((kind, label, CFAbsoluteTimeGetCurrent()))
    }

    private func add(_ kind: MusicPerfBudget.Kind, _ label: String, _ ms: Double) {
        samples.append(MusicPerfSample(kind: kind, label: label, ms: ms, at: Date()))
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
        if MusicPerfBudget.exceeds(kind, ms: ms) { MusicDebugLog.log("perf", "\(kind.rawValue) \(label) took \(Int(ms)) ms (limit \(Int(MusicPerfBudget.limit(kind))))") }
    }

    func clear() { samples.removeAll(); pending.removeAll() }
    func report() -> String { MusicPerfStats.report(samples) }
}
