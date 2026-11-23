import Foundation
import os

/// Measurement support for the performance baseline. Subsystem "perf", category "perf": filter on it in Instruments (os_signpost).
/// Intervals cost next to nothing with no tool attached. Counters and main-thread database timing are OFF unless a benchmark switches them on
/// (one relaxed flag read per call), and nothing here records titles, addresses or logins: names and numbers only.
enum Perf {
    nonisolated static let signposter = OSSignposter(subsystem: "perf", category: "perf")

    /// Set by the benchmarks only.
    nonisolated(unsafe) static var collecting = false
    private nonisolated static let store = OSAllocatedUnfairLock(initialState: Store())
    private struct Store { var counts: [String: Int] = [:]; var mainMs: [String: [Double]] = [:] }

    nonisolated static func begin(_ name: StaticString) -> OSSignpostIntervalState { signposter.beginInterval(name, id: signposter.makeSignpostID()) }
    nonisolated static func end(_ name: StaticString, _ state: OSSignpostIntervalState) { signposter.endInterval(name, state) }
    nonisolated static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T { let s = begin(name); defer { end(name, s) }; return try body() }

    /// Counts an event (a screen model built, an image decoded). No-op unless collecting.
    nonisolated static func bump(_ key: String) { if collecting { store.withLock { $0.counts[key, default: 0] += 1 } } }
    /// Records how long the MAIN thread was blocked in `body` (database reads and writes). No-op unless collecting.
    nonisolated static func main<T>(_ key: String, _ body: () throws -> T) rethrows -> T {
        guard collecting, Thread.isMainThread else { return try body() }
        let t = CFAbsoluteTimeGetCurrent(); defer { let ms = (CFAbsoluteTimeGetCurrent() - t) * 1000; store.withLock { $0.mainMs[key, default: []].append(ms) } }
        return try body()
    }
    nonisolated static func counts() -> [String: Int] { store.withLock { $0.counts } }
    nonisolated static func mainTimes() -> [String: [Double]] { store.withLock { $0.mainMs } }
    nonisolated static func resetCounters() { store.withLock { $0 = Store() } }
}
