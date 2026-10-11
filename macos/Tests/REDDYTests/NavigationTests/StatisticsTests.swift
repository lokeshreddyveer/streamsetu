import Testing
import Foundation
@testable import REDDY

@Suite struct StatisticsTests {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)   // fixed instant

    private func row(_ id: String, minutesAgo: Double, minutes: Double) -> StatisticsService.Row {
        let start = now.addingTimeInterval(-minutesAgo * 60)
        return .init(itemID: id, start: start, end: start.addingTimeInterval(minutes * 60))
    }

    @Test func totalsAndTopListsAreAggregated() {
        let rows = [row("a", minutesAgo: 600, minutes: 30), row("a", minutesAgo: 300, minutes: 30), row("m", minutesAgo: 100, minutes: 90), row("gone", minutesAgo: 50, minutes: 10)]
        let s = StatisticsService.aggregate(rows, now: now, calendar: cal) { _ in ["a": (.live, "News"), "m": (.movie, "Film")] }
        #expect(s.sessions == 4)
        #expect(s.totalSeconds == 160 * 60)
        #expect(s.longestSession == 90 * 60)
        #expect(s.topChannels.first?.title == "News" && s.topChannels.first?.plays == 2)
        #expect(s.topMovies.first?.seconds == 5400.0)
        #expect(s.liveSeconds == 60 * 60 && s.movieSeconds == 90 * 60)   // unresolved item counts in total only
        #expect(s.days.count == 14 && s.days.last?.date == cal.startOfDay(for: now))
    }

    @Test func catchUpCountsForItsChannelAndAbsurdSessionsAreCapped() {
        let rows = [row("a|catchup|123", minutesAgo: 500, minutes: 20), row("a", minutesAgo: 1000, minutes: 60 * 40)]
        let s = StatisticsService.aggregate(rows, now: now, calendar: cal) { _ in ["a": (.live, "News")] }
        #expect(s.topChannels.count == 1 && s.topChannels[0].plays == 2)
        #expect(s.longestSession == StatisticsService.maxSession)
    }

    @Test func hoursAreSpreadAcrossTheSessionAndEmptyIsEmpty() {
        let midnight: TimeInterval = 1_799_971_200   // 00:00 UTC, the day containing `now`
        let start = Date(timeIntervalSince1970: midnight + 37_800)   // 10:30 UTC
        let s = StatisticsService.aggregate([.init(itemID: "a", start: start, end: start.addingTimeInterval(3600))], now: now, calendar: cal) { _ in [:] }
        #expect(s.hours[10] == 1800 && s.hours[11] == 1800)
        #expect(StatisticsService.aggregate([], now: now, calendar: cal) { _ in [:] }.isEmpty)
    }

    @Test func durationsReadNaturally() {
        #expect(StatisticsPage.duration(0) == "0 min")
        #expect(StatisticsPage.duration(90 * 60) == "1 h 30 min")
        #expect(StatisticsPage.duration(26 * 3600) == "1 d 2 h")
    }
}
