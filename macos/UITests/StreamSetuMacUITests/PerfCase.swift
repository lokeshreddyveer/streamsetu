import XCTest

/// Base for the speed and smoothness scenarios. The app copy runs with STREAMSETU_PERFLOG, so it writes frame, stall, mark and memory events to a file; a scenario
/// is a block of UI actions that WAITS FOR THINGS (waitForExistence, predicates), never for time. After the block the log between its start and end is summarised,
/// printed, attached, written next to the other results, and held to a budget.
class PerfCase: MacUITestCase {
    /// Apple's guidance for the hitch time ratio: under 5 ms per second is good, 10 or more is distracting. The default budget fails only at "distracting".
    var hitchBudget: Double { 10 }
    var longestStallBudgetMs: Double { 250 }

    var perfFile: URL { Self.outDir.appendingPathComponent("perf-\(name.replacingOccurrences(of: " ", with: "_")).jsonl") }
    override var extraEnvironment: [String: String] { ["STREAMSETU_PERFLOG": perfFile.path] }

    override func setUpWithError() throws {
        try? FileManager.default.createDirectory(at: Self.outDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: perfFile)
        try super.setUpWithError()
    }

    /// Runs `body`, then judges the log of exactly that stretch. `budget` overrides the default hitch budget for a scenario that is allowed to be heavier.
    @discardableResult
    func scenario(_ label: String, hitchBudget budget: Double? = nil, _ body: () throws -> Void) rethrows -> PerfSummary {
        let start = ProcessInfo.processInfo.systemUptime
        try body()
        let end = ProcessInfo.processInfo.systemUptime
        let text = (try? String(contentsOf: perfFile, encoding: .utf8)) ?? ""
        let events = PerfMath.parse(text)
        let s = PerfMath.summarize(events, from: start, to: end)
        let report = "PERF \(name) | \(label) | \(s.line) | marks=\(s.marks.map { "\($0.key)@\(String(format: "%.2f", $0.value))s" }.sorted().joined(separator: ","))"
        print(report)
        attachText(report + "\n" + text, "perf-\(label.replacingOccurrences(of: " ", with: "_")).txt")
        XCTAssertGreaterThan(s.frames, 0, "no frames were logged: is the app a debug build with STREAMSETU_PERFLOG? (\(label))")
        XCTAssertLessThanOrEqual(s.hitchMsPerSecond, budget ?? hitchBudget, "hitch time ratio too high in \(label): \(s.line)")
        XCTAssertLessThanOrEqual(s.longestStallMs, longestStallBudgetMs, "main thread stalled too long in \(label): \(s.line)")
        return s
    }

    /// The seconds from `from` until the app wrote the mark `name` (nil if it never did). Used to time "first results" without polling a clock.
    func markTime(_ name: String, after from: Double) -> Double? {
        let events = PerfMath.parse((try? String(contentsOf: perfFile, encoding: .utf8)) ?? "")
        return events.first { $0.kind == "mark" && $0.name == name && $0.t >= from }.map { $0.t - from }
    }
}
