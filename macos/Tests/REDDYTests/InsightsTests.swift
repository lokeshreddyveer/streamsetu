import Testing
import Foundation
@testable import REDDY

@Suite struct ViewingLimitTests {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))! }
    private func fresh() -> ViewingLimits { ViewingLimits(defaults: UserDefaults(suiteName: "limits-\(UUID().uuidString)")!, calendar: cal) }

    @Test func noLimitMeansNothingBlocks() {
        let l = fresh()
        #expect(l.block(for: "k", now: at(20, 12)) == nil)
        #expect(l.remaining(for: "k", now: at(20, 12)) == nil)
    }

    @Test func timeWatchedCountsDownAndBlocksAtZero() {
        let l = fresh()
        l.set(ViewingLimit(dailyMinutes: 30), for: "k")
        l.addUsage(20 * 60, for: "k", now: at(20, 10))
        #expect(l.remaining(for: "k", now: at(20, 11)) == 10.0 * 60)
        #expect(l.block(for: "k", now: at(20, 11)) == nil)
        l.addUsage(10 * 60, for: "k", now: at(20, 12))
        #expect(l.block(for: "k", now: at(20, 12)) == .dailyLimit)
    }

    @Test func aNewDayStartsFresh() {
        let l = fresh()
        l.set(ViewingLimit(dailyMinutes: 30), for: "k")
        l.addUsage(30 * 60, for: "k", now: at(20, 10))
        #expect(l.block(for: "k", now: at(21, 9)) == nil)
    }

    @Test func aParentCanAddTimeForTheDay() {
        let l = fresh()
        l.set(ViewingLimit(dailyMinutes: 30), for: "k")
        l.addUsage(30 * 60, for: "k", now: at(20, 10))
        l.grantExtra(for: "k", now: at(20, 11))
        #expect(l.remaining(for: "k", now: at(20, 11)) == Double(ViewingLimits.extraMinutes) * 60)
        #expect(l.block(for: "k", now: at(20, 11)) == nil)
    }

    @Test func bedtimeAcrossMidnightBlocksUntilMorning() {
        let l = fresh()
        l.set(ViewingLimit(bedtimeOn: true, bedtimeStart: 21 * 60, bedtimeEnd: 7 * 60), for: "k")
        #expect(l.block(for: "k", now: at(20, 15)) == nil)
        #expect(l.block(for: "k", now: at(20, 22)) == .bedtime(until: at(21, 7)))
        #expect(l.block(for: "k", now: at(21, 3)) == .bedtime(until: at(21, 7)))
        #expect(l.block(for: "k", now: at(21, 7)) == nil)
    }

    @Test func eachProfileHasItsOwnLimitAndTime() {
        let l = fresh()
        l.set(ViewingLimit(dailyMinutes: 30), for: "a")
        l.addUsage(30 * 60, for: "a", now: at(20, 10))
        #expect(l.block(for: "a", now: at(20, 11)) == .dailyLimit)
        #expect(l.block(for: "b", now: at(20, 11)) == nil)
    }

    @Test func summaryReadsPlainly() {
        #expect(ViewingLimits.summary(ViewingLimit()) == "No limits")
        #expect(ViewingLimits.summary(ViewingLimit(dailyMinutes: 90, bedtimeOn: true)) == "90 min a day, none 21:00 to 07:00")
        #expect(ViewingLimits.summary(ViewingLimit(dailyMinutes: 120)) == "2 h a day")
    }
}

@Suite struct WeeklyDigestTests {
    @Test func comparesWithTheWeekBefore() {
        var s = ViewingStatistics(); s.totalSeconds = 3 * 3600; s.sessions = 4
        let d = WeeklyDigest.make(thisWeek: s, last7Days: 2 * 3600, seriesWithNewEpisodes: 0, subscriptionNotes: [])
        #expect(d.headline == "You watched 3 h this week")
        #expect(d.comparison == "50% more than the week before")
    }

    @Test func aQuietWeekSaysSoAndAsksNothingOfTheNumbers() {
        let d = WeeklyDigest.make(thisWeek: ViewingStatistics(), last7Days: 3600, seriesWithNewEpisodes: 0, subscriptionNotes: [])
        #expect(d.headline == "A quiet week")
        #expect(d.comparison == nil)
        #expect(d.isEmpty)
    }

    @Test func mostWatchedIsTheLongestAcrossKinds() {
        var s = ViewingStatistics(); s.totalSeconds = 7200
        s.topMovies = [.init(id: "m", title: "Film", seconds: 3000, plays: 1)]
        s.topSeries = [.init(id: "s", title: "Show", seconds: 4000, plays: 3)]
        s.topChannels = [.init(id: "c", title: "News", seconds: 100, plays: 1)]
        let d = WeeklyDigest.make(thisWeek: s, last7Days: 0, seriesWithNewEpisodes: 2, subscriptionNotes: ["Home: Ends today"])
        #expect(d.topTitle == "Show")
        #expect(d.lines.contains("New episodes are waiting in 2 series"))
        #expect(d.lines.contains("Home: Ends today"))
        #expect(!d.isEmpty)
    }

    @Test func theNotificationKeepsToThreeLines() {
        var s = ViewingStatistics(); s.totalSeconds = 3600; s.hours[21] = 3600
        s.topSeries = [.init(id: "s", title: "Show", seconds: 3000, plays: 1)]
        let d = WeeklyDigest.make(thisWeek: s, last7Days: 3600, seriesWithNewEpisodes: 1, subscriptionNotes: ["A: Ends today"])
        #expect(d.notificationBody.components(separatedBy: ". ").count == 3)
    }

    @Test func theNextFireIsASundayAtSixInTheEvening() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let wed = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12))!       // a Wednesday
        let fire = WeeklyDigestSchedule.nextFire(after: wed, calendar: cal)
        let c = cal.dateComponents([.weekday, .hour, .minute, .day], from: fire)
        #expect(c.weekday == 1 && c.hour == 18 && c.minute == 0 && c.day == 25)
    }
}

@Suite struct PrivacyReportTests {
    @Test func reflectsWhatIsSwitchedOn() {
        let r = PrivacyReport.make(.init(diagnosticsOn: false, hasTMDBKey: true, hasOpenSubtitles: false, iCloudSync: true, lanSync: false))
        func status(_ id: String) -> PrivacyReport.Status? { r.sentOut.first { $0.id == id }?.status }
        #expect(status("diag") == .off)
        #expect(status("tmdb") == .on)
        #expect(status("subs") == .off)
        #expect(status("icloud") == .on)
        #expect(status("lan") == .off)
        #expect(status("trailer") == .whenYouAsk)
    }

    @Test func countsComeFromTheDevice() {
        let r = PrivacyReport.make(.init(profileCount: 2, historyCount: 1, favoriteCount: 12, playlistCount: 3))
        #expect(r.stored.first { $0.id == "history" }?.detail.hasPrefix("1 title.") == true)
        #expect(r.stored.first { $0.id == "fav" }?.detail.hasPrefix("12 favourites") == true)
        #expect(r.stored.first { $0.id == "profiles" }?.detail.hasPrefix("2 profiles") == true)
    }

    @Test func yourProviderIsAlwaysListed() {
        #expect(PrivacyReport.make(.init()).sentOut.contains { $0.id == "provider" && $0.status == .on })
    }
}

@Suite struct StartOverTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func prog(from a: Double, to b: Double) -> EPGProgram { EPGProgram(id: 1, sourceID: UUID(), xmltvChannelID: "x", start: now.addingTimeInterval(a * 60), end: now.addingTimeInterval(b * 60), title: "Match") }

    @Test func offeredWhenItBeganAWhileAgoAndThereIsAnArchive() {
        #expect(StartOver.canOffer(program: prog(from: -30, to: 60), archiveDays: 3, now: now))
    }
    @Test func notOfferedJustAfterItStartsOrWithoutAnArchive() {
        #expect(!StartOver.canOffer(program: prog(from: -2, to: 90), archiveDays: 3, now: now))
        #expect(!StartOver.canOffer(program: prog(from: -30, to: 60), archiveDays: 0, now: now))
    }
    @Test func notOfferedForShortProgrammesOrOnesNotOnNow() {
        #expect(!StartOver.canOffer(program: prog(from: -10, to: 3), archiveDays: 3, now: now))
        #expect(!StartOver.canOffer(program: prog(from: -90, to: -30), archiveDays: 3, now: now))
    }
}

@Suite struct UsualEveningTests {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))! }
    private let now = Date(timeIntervalSince1970: 0)

    @Test func findsTheHourAndWhatIsOftenPlayedThen() {
        let today = cal.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 12))!
        let rows: [(itemID: String, start: Date)] = [("show", at(20, 21)), ("show", at(21, 21, 30)), ("news", at(22, 21, 10)), ("show", at(23, 20, 50)), ("lunch", at(24, 12))]
        let pick = UsualEvening.pick(sessions: rows, now: today, calendar: cal)
        #expect(pick?.itemID == "show")
        #expect(pick?.hour == 21)
        #expect(pick?.days == 4)
    }
    @Test func tooFewDaysIsNoHabit() {
        let today = at(28, 12)
        #expect(UsualEvening.pick(sessions: [("a", at(20, 21)), ("a", at(21, 21)), ("a", at(22, 21))], now: today, calendar: cal) == nil)
    }
    @Test func oldViewingIsIgnored() {
        let today = at(28, 12)
        let rows: [(itemID: String, start: Date)] = [("a", cal.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 21))!), ("a", cal.date(from: DateComponents(year: 2026, month: 8, day: 2, hour: 21))!),
                                                     ("a", cal.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 21))!), ("a", cal.date(from: DateComponents(year: 2026, month: 8, day: 4, hour: 21))!)]
        #expect(UsualEvening.pick(sessions: rows, now: today, calendar: cal) == nil)
    }
    @Test func theReminderComesTenMinutesBefore() {
        let fire = UsualEvening.nextFire(hour: 21, after: at(28, 12), calendar: cal)
        let c = cal.dateComponents([.hour, .minute, .day], from: fire)
        #expect(c.hour == 20 && c.minute == 50 && c.day == 28)
    }
    @Test func catchUpCountsForItsChannel() {
        let today = at(28, 12)
        let rows: [(itemID: String, start: Date)] = [("ch|catchup|1", at(20, 21)), ("ch", at(21, 21)), ("ch|catchup|2", at(22, 21)), ("ch", at(23, 21))]
        #expect(UsualEvening.pick(sessions: rows, now: today, calendar: cal)?.itemID == "ch")
    }
}

@MainActor @Suite struct NowPlayingBoardTests {
    private func record(_ device: String, title: String, ts: Int64, deleted: Bool = false) -> LanRecord {
        LanRecord(kind: "now", key: [device], ts: ts, deleted: deleted, value: deleted ? nil : ["title": .string(title), "pos": .double(12), "dev": .string("Fire TV"), "src": .string("abc"), "kind": .string("movie"), "prov": .string("7")])
    }

    @Test func showsWhatAnotherDeviceIsPlayingAndForgetsItWhenItStops() {
        let b = NowPlayingBoard()
        let t = Int64(Date().timeIntervalSince1970 * 1000)
        b.ingest([record("tv", title: "Film", ts: t)])
        #expect(b.current().map(\.title) == ["Film"])
        #expect(b.current().first?.deviceName == "Fire TV")
        b.ingest([record("tv", title: "", ts: t + 1000, deleted: true)])
        #expect(b.current().isEmpty)
    }
    @Test func anOlderRecordDoesNotReplaceANewerOne() {
        let b = NowPlayingBoard()
        let t = Int64(Date().timeIntervalSince1970 * 1000)
        b.ingest([record("tv", title: "New", ts: t)])
        b.ingest([record("tv", title: "Old", ts: t - 5000)])
        #expect(b.current().map(\.title) == ["New"])
    }
    @Test func staleEntriesAreLeftOut() {
        let b = NowPlayingBoard()
        let old = Int64((Date().timeIntervalSince1970 - 600) * 1000)
        b.ingest([record("tv", title: "Film", ts: old)])
        #expect(b.current().isEmpty)
    }
}

@Suite struct FavouritePersonTests {
    @Test func theMostSharedPersonWinsAndNeedsTwoTitles() {
        let watched = ["a": ["Mahesh Babu", "Rajamouli"], "b": ["Mahesh Babu", "Other"], "c": ["Someone"]]
        let top = DiscoverService.favouritePerson(in: watched)
        #expect(top?.name == "Mahesh Babu")
        #expect(top?.titles == 2)
    }
    @Test func nobodyInTwoTitlesMeansNoRow() {
        #expect(DiscoverService.favouritePerson(in: ["a": ["X"], "b": ["Y"]]) == nil)
        #expect(DiscoverService.favouritePerson(in: [:]) == nil)
    }
    @Test func theSamePersonWrittenTwoWaysCountsOnce() {
        #expect(DiscoverService.favouritePerson(in: ["a": ["Keanu Reeves"], "b": ["keanu  reeves"]])?.titles == 2)
    }
}

@Suite struct ConnectionAdviceTests {
    @Test func warnsOnlyWhenTheNextStreamWouldGoOverTheLimit() {
        #expect(ConnectionAdvice.message(tilesFromSource: 1, limit: 1) != nil)
        #expect(ConnectionAdvice.message(tilesFromSource: 0, limit: 1) == nil)
        #expect(ConnectionAdvice.message(tilesFromSource: 2, limit: 3) == nil)
        #expect(ConnectionAdvice.message(tilesFromSource: 3, limit: 3) != nil)
    }
    @Test func saysNothingWhenTheProviderDoesNotSayOrSaysZero() {
        #expect(ConnectionAdvice.message(tilesFromSource: 4, limit: nil) == nil)
        #expect(ConnectionAdvice.message(tilesFromSource: 4, limit: 0) == nil)
    }
    @Test func theMessageNamesTheLimit() {
        #expect(ConnectionAdvice.message(tilesFromSource: 1, limit: 1)?.contains("1 stream at a time") == true)
        #expect(ConnectionAdvice.message(tilesFromSource: 2, limit: 2)?.contains("2 streams at a time") == true)
    }
}
