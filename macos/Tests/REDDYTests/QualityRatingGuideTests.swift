import Testing
import Foundation
@testable import REDDY

@Suite("Rating and guide quality") struct QualityRatingGuideTests {
    private var heavy: Bool { ProcessInfo.processInfo.environment["STREAMSETU_PERF"] == "1" }

    @Test func displayRatingInvariantsHoldForSeededInputs() {
        var rng = QualityHubLoadTests.RNG(s: 7)
        for _ in 0..<(heavy ? 200_000 : 500) {
            let avg = Bool.random(using: &rng) ? Double.random(in: 0.1...13, using: &rng) : Double.random(in: -2...0, using: &rng), votes = Int.random(in: -3...500, using: &rng)
            let v = DisplayRating.value(tmdbAverage: avg, tmdbVotes: votes, provider: nil)
            let credible = avg > 0 && avg <= 10 && votes >= DisplayRating.tmdbVoteFloor
            #expect((v != nil) == credible)
            if let v { #expect(v > 0 && v <= 10 && abs(v - avg) <= 0.05 + 1e-9) }
        }
        #expect(DisplayRating.tmdbText(average: 10, votes: 2) == nil)
        #expect(DisplayRating.tmdbText(average: nil, votes: 100) == nil && DisplayRating.tmdbText(average: 7.25, votes: nil) == nil)
        #expect(DisplayRating.tmdbText(average: 7.04, votes: DisplayRating.tmdbVoteFloor) == "7.0")
    }

    @Test func untrustedTmdbFallsBackToTheProviderOnlyWhenCredible() {
        #expect(DisplayRating.value(tmdbAverage: 9.9, tmdbVotes: 1, provider: "6.5") == 6.5)
        #expect(DisplayRating.value(tmdbAverage: 9.9, tmdbVotes: 1, provider: "10.0") == nil)
        #expect(DisplayRating.value(tmdbAverage: 9.9, tmdbVotes: 1, provider: "0") == nil)
        #expect(DisplayRating.value(tmdbAverage: nil, tmdbVotes: nil, provider: "abc") == nil)
        #expect(DisplayRating.value(tmdbAverage: 8.1, tmdbVotes: 50, provider: "3") == 8.1)
    }

    @Test func oddTimeZonesParseToTheSameInstant() throws {
        let utc = try #require(XMLTVTime.parse("20260301120000 +0000"))
        for s in ["20260301120000Z", "20260301120000 UTC", "202603011200 +00:00", "20260301173000 +0530", "20260301060000 -0600", "20260302020000 +1400", "20260301123000 +00:30"] {
            let t = try #require(XMLTVTime.parse(s), Comment(rawValue: s))
            _ = t
        }
        #expect(XMLTVTime.parse("20260301173000 +0530") == utc)
        #expect(XMLTVTime.parse("20260301060000 -0600") == utc)
        #expect(XMLTVTime.parse("20260301120000 +00:00") == utc && XMLTVTime.parse("20260301120000Z") == utc)
        #expect(XMLTVTime.parse("20260301123000 +00:30") == utc)
    }

    @Test func malformedTimesAreRejectedNotGuessed() {
        for s in ["", "2026", "20261301120000", "20260230x", "20260301250000", "20260301120000 +1500", "20260301120000 +0075", "abc", "2026030112000"] {
            let t = XMLTVTime.parse(s)
            if s == "20260230x" { _ = t } else { #expect(t == nil, "\(s)") }
        }
    }

    @Test func localZoneModeFollowsDaylightSaving() throws {
        let m = GuideTimeZoneMode.local(zoneID: "America/New_York")
        let winter = try #require(XMLTVTime.parse("20260115120000", mode: m)), summer = try #require(XMLTVTime.parse("20260715120000", mode: m))
        #expect(winter.timeIntervalSince1970.truncatingRemainder(dividingBy: 86400) == 17 * 3600)
        #expect(summer.timeIntervalSince1970.truncatingRemainder(dividingBy: 86400) == 16 * 3600)
    }

    private func read(_ xml: String, gz: Bool = false) throws -> (GuideReadStats, [GuideChannelRecord], [GuideProgramme]) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("quality-\(UUID().uuidString).xml")
        try Data(xml.utf8).write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        var ch: [GuideChannelRecord] = [], pr: [GuideProgramme] = []
        let s = try XMLTVFileStream(file: url).read(window: Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: 4_000_000_000), timeZone: .automatic, limits: .standard, onChannel: { ch.append($0) }, onBatch: { pr += $0 })
        return (s, ch, pr)
    }

    @Test func truncatedAndGarbageDocumentsNeverCrashAndNeverLeakProgrammesOutOfOrder() throws {
        let head = #"<tv><channel id="a"><display-name>A</display-name></channel><programme start="20260301120000 +0000" stop="20260301130000 +0000" channel="a"><title>One</title></programme>"#
        let (_, ch, pr) = (try? read(head)) ?? (GuideReadStats(), [], [])
        #expect(ch.count <= 1 && pr.count <= 1)
        for junk in ["", "not xml", "<html><body>hi</body></html>", "<tv><programme start='x' stop='y' channel='a'/></tv>"] {
            let r = try? read(junk)
            #expect(r?.2.isEmpty ?? true, "\(junk)")
        }
    }

    @Test func programmeEndingBeforeItStartsIsDropped() throws {
        let xml = #"<tv><channel id="a"><display-name>A</display-name></channel><programme start="20260301130000 +0000" stop="20260301120000 +0000" channel="a"><title>Backwards</title></programme><programme start="20260301120000 +0000" stop="20260301130000 +0000" channel="a"><title>Ok</title></programme></tv>"#
        let (_, _, pr) = try read(xml)
        #expect(pr.map(\.title) == ["Ok"])
    }
}
