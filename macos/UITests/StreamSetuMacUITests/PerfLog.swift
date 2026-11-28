import Foundation

/// Reads the log the app writes when it runs with STREAMSETU_PERFLOG=<file> (a debug build only): one JSON object per line.
///   {"t":123.456,"k":"frame","dt":16.7}        a frame was shown, dt = milliseconds since the previous frame
///   {"t":123.456,"k":"stall","ms":84.2}        one pass of the main run loop took ms milliseconds (so the UI could not move for that long)
///   {"t":123.456,"k":"mark","name":"search.results"}   something the app says happened
///   {"t":123.456,"k":"mem","mb":412.0}         resident memory, sampled with the frames
/// t is ProcessInfo.systemUptime, which the app and the test runner share, so the test can cut the log to the seconds of one scenario.
struct PerfEvent {
    let t: Double
    let kind: String
    let value: Double
    let name: String
}

struct PerfSummary: Equatable {
    var seconds: Double
    var frames: Int
    /// Frames that took more than one and a half refresh intervals.
    var dropped: Int
    /// Milliseconds of lateness added up over the window, per second of window: Apple's "hitch time ratio" (under 5 good, 5 to 10 noticeable, 10 or more distracting).
    var hitchMsPerSecond: Double
    var p50: Double, p95: Double, p99: Double
    /// Standard deviation of the frame intervals: how uneven the motion was.
    var jitterMs: Double
    var longestStallMs: Double
    var stallsOver50: Int
    var peakMemoryMB: Double
    var marks: [String: Double]

    var line: String {
        String(format: "%.2fs frames=%d dropped=%d hitch=%.1fms/s p50=%.1f p95=%.1f p99=%.1f jitter=%.1f longestStall=%.0fms stalls>50ms=%d mem=%.0fMB", seconds, frames, dropped, hitchMsPerSecond, p50, p95, p99, jitterMs, longestStallMs, stallsOver50, peakMemoryMB)
    }
}

enum PerfMath {
    static let refreshMs = 1000.0 / 60.0

    static func parse(_ text: String) -> [PerfEvent] {
        text.split(separator: "\n").compactMap { line in
            guard let d = line.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let t = o["t"] as? Double, let k = o["k"] as? String else { return nil }
            return PerfEvent(t: t, kind: k, value: (o["dt"] as? Double) ?? (o["ms"] as? Double) ?? (o["mb"] as? Double) ?? 0, name: (o["name"] as? String) ?? "")
        }
    }

    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let i = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[i]
    }

    /// The numbers for the events inside [from, to]. An empty window gives zeros, never a division by zero.
    static func summarize(_ events: [PerfEvent], from: Double, to: Double, refreshMs: Double = PerfMath.refreshMs) -> PerfSummary {
        let inside = events.filter { $0.t >= from && $0.t <= to }
        let frames = inside.filter { $0.kind == "frame" }.map(\.value)
        let sorted = frames.sorted()
        let mean = frames.isEmpty ? 0 : frames.reduce(0, +) / Double(frames.count)
        let variance = frames.isEmpty ? 0 : frames.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(frames.count)
        let seconds = max(0.001, to - from)
        let late = frames.map { max(0, $0 - refreshMs) }.reduce(0, +)
        let stalls = inside.filter { $0.kind == "stall" }.map(\.value)
        var marks: [String: Double] = [:]
        for m in inside where m.kind == "mark" && marks[m.name] == nil { marks[m.name] = m.t - from }
        return PerfSummary(seconds: seconds, frames: frames.count, dropped: frames.filter { $0 > refreshMs * 1.5 }.count, hitchMsPerSecond: late / seconds,
                           p50: percentile(sorted, 0.5), p95: percentile(sorted, 0.95), p99: percentile(sorted, 0.99), jitterMs: variance.squareRoot(),
                           longestStallMs: stalls.max() ?? 0, stallsOver50: stalls.filter { $0 > 50 }.count,
                           peakMemoryMB: inside.filter { $0.kind == "mem" }.map(\.value).max() ?? 0, marks: marks)
    }
}
