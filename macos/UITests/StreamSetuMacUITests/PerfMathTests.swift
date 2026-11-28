import XCTest

/// The smoothness arithmetic checked on made-up logs, with no app and no waiting: run these first, they take milliseconds.
final class PerfMathTests: XCTestCase {
    private func frame(_ t: Double, _ dt: Double) -> String { #"{"t":\#(t),"k":"frame","dt":\#(dt)}"# }

    func testSmoothMotionHasNoHitchAndNoJitter() {
        let log = (0..<60).map { frame(Double($0) / 60, 1000.0 / 60) }.joined(separator: "\n")
        let s = PerfMath.summarize(PerfMath.parse(log), from: 0, to: 1)
        XCTAssertEqual(s.frames, 60); XCTAssertEqual(s.dropped, 0)
        XCTAssertEqual(s.hitchMsPerSecond, 0, accuracy: 0.001); XCTAssertEqual(s.jitterMs, 0, accuracy: 0.001)
    }
    func testOneLongFrameIsCountedAsDroppedAndAddsItsLateness() {
        var lines = (0..<59).map { frame(Double($0) / 60, 1000.0 / 60) }
        lines.append(frame(0.99, 100))                                   // 100 ms frame: about 83 ms late
        let s = PerfMath.summarize(PerfMath.parse(lines.joined(separator: "\n")), from: 0, to: 1)
        XCTAssertEqual(s.dropped, 1)
        XCTAssertEqual(s.hitchMsPerSecond, 100 - PerfMath.refreshMs, accuracy: 0.01)
        XCTAssertEqual(s.p99, 100, accuracy: 0.001); XCTAssertGreaterThan(s.jitterMs, 5)
    }
    func testStallsMarksAndMemoryAreReadAndOnlyTheWindowCounts() {
        let log = [#"{"t":1,"k":"stall","ms":80}"#, #"{"t":2,"k":"stall","ms":20}"#, #"{"t":1.5,"k":"mark","name":"search.results"}"#,
                   #"{"t":1.2,"k":"mem","mb":300}"#, #"{"t":5,"k":"mem","mb":999}"#].joined(separator: "\n")
        let s = PerfMath.summarize(PerfMath.parse(log), from: 1, to: 3)
        XCTAssertEqual(s.longestStallMs, 80); XCTAssertEqual(s.stallsOver50, 1)
        XCTAssertEqual(s.marks["search.results"] ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(s.peakMemoryMB, 300, "the 999 MB sample is outside the window")
    }
    func testAnEmptyOrBrokenLogGivesZerosNotACrash() {
        XCTAssertEqual(PerfMath.summarize([], from: 0, to: 0).frames, 0)
        XCTAssertEqual(PerfMath.parse("not json\n{\"t\":1}\n").count, 0)
    }
}
