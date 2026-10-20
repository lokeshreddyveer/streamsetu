import Testing
import Foundation
@testable import REDDY

@Suite struct TonightTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ch(_ id: String) -> Channel {
        Channel(id: id, sourceID: UUID(), providerID: id, name: "Channel \(id)", normalizedName: "channel \(id)", categoryID: nil, categoryName: nil, logoURL: nil, epgID: nil, language: nil, country: nil, resolutionHint: nil, sortOrder: 0, streamRef: "x")
    }
    private func prog(_ id: Int64, _ title: String, from a: Double, to b: Double) -> EPGProgram {
        EPGProgram(id: id, sourceID: UUID(), xmltvChannelID: "x", start: now.addingTimeInterval(a * 60), end: now.addingTimeInterval(b * 60), title: title)
    }

    @Test func whatIsOnNowAndWhatIsNextAreSeparatedPerChannel() {
        let a = ch("a"), b = ch("b")
        let plan = TonightBuilder.build(now: now, channels: [a, b], programs: [
            "a": [prog(1, "Match", from: -20, to: 40), prog(2, "News", from: 40, to: 70), prog(3, "Film", from: 70, to: 160)],
            "b": [prog(4, "Quiz", from: 15, to: 45)],
        ], recordings: [], upNext: [], alerts: [])
        #expect(plan.onNow.map(\.program.title) == ["Match"])
        #expect(plan.later.map(\.program.title) == ["Quiz", "News"])            // one per channel, soonest first
    }

    @Test func programmesBeyondTheEveningAreLeftOut() {
        let a = ch("a")
        let plan = TonightBuilder.build(now: now, channels: [a], programs: ["a": [prog(1, "Late", from: 6 * 60, to: 7 * 60)]], recordings: [], upNext: [], alerts: [])
        #expect(plan.isEmpty)
    }

    @Test func recordingsWithinADayAreKeptInOrder() {
        let r = { (id: String, mins: Double) in TonightPlan.Recording(id: id, title: id, channelName: "C", start: self.now.addingTimeInterval(mins * 60)) }
        let plan = TonightBuilder.build(now: now, channels: [], programs: [:], recordings: [r("far", 30 * 60), r("later", 300), r("soon", 30), r("past", -300)], upNext: [], alerts: ["x"])
        #expect(plan.recordings.map(\.id) == ["soon", "later"])
        #expect(plan.alerts == ["x"] && !plan.isEmpty)
    }

    @Test func nothingMeansAnEmptyPlan() {
        #expect(TonightBuilder.build(now: now, channels: [], programs: [:], recordings: [], upNext: [], alerts: []).isEmpty)
    }
}
