import Testing
import Foundation
@testable import REDDY

@Suite struct PlayerExtrasTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "test-\(UUID().uuidString)")! }

    @Test func timesAreReadInAnyOfTheThreeForms() {
        #expect(PlaybackCoordinator.parseTime("1:23:45") == 5025)
        #expect(PlaybackCoordinator.parseTime("83:45") == 5025)
        #expect(PlaybackCoordinator.parseTime("45") == 45)
        #expect(PlaybackCoordinator.parseTime("abc") == nil)
        #expect(PlaybackCoordinator.parseTime("") == nil)
        #expect(PlaybackCoordinator.parseTime("1:2:3:4") == nil)
        #expect(PlaybackCoordinator.parseTime("-5") == nil)
    }

    @Test func aTitleRemembersWhatWasChosen() {
        let m = ItemMemory(defaults: defaults())
        #expect(m.entry(for: "movie-1") == nil)
        m.save(.init(audioLanguage: "hi", subtitleLanguage: "off", rate: 1.25, audioDelay: 0.2, subtitleDelay: -0.5), for: "movie-1")
        let e = m.entry(for: "movie-1")
        #expect(e?.audioLanguage == "hi"); #expect(e?.subtitleLanguage == "off"); #expect(e?.rate == 1.25); #expect(e?.audioDelay == 0.2)
        #expect(m.entry(for: "movie-2") == nil)
    }

    @Test func memoryCanBeTurnedOff() {
        let m = ItemMemory(defaults: defaults())
        m.save(.init(audioLanguage: "en"), for: "a")
        m.enabled = false
        #expect(m.entry(for: "a") == nil)
        m.save(.init(audioLanguage: "te"), for: "b")      // nothing is stored while it is off
        m.enabled = true
        #expect(m.entry(for: "b") == nil)
    }

    @Test func memoryKeepsOnlyTheNewest() {
        let m = ItemMemory(defaults: defaults())
        for i in 0..<450 { m.save(.init(audioLanguage: "en", savedAt: Date(timeIntervalSince1970: Double(i))), for: "t\(i)") }
        #expect(m.entry(for: "t0") == nil)
        #expect(m.entry(for: "t449") != nil)
    }

    @Test func theOpeningIsLearnedFromALongEarlyJump() {
        let s = IntroSkip(defaults: defaults())
        #expect(s.target(seriesID: "s", position: 10) == 90)                          // the default, until something is learned
        #expect(s.isOpeningSkip(from: 12, to: 75))
        #expect(!s.isOpeningSkip(from: 12, to: 20))                                  // a short skip is not an opening
        #expect(!s.isOpeningSkip(from: 1200, to: 1260))                              // nor is a jump late in the episode
        s.learn(seriesID: "s", end: 140)
        #expect(s.target(seriesID: "s", position: 30) == 140)
        #expect(s.target(seriesID: "s", position: 138) == nil)                       // already at the end of it
        #expect(s.target(seriesID: "other", position: 30) == 90)
    }

    @Test func aRecapIsFoundFromItsChapterAndSkippedToTheNextOne() {
        let marks = EpisodeMarks(defaults: defaults())
        let chapters = [PlaybackChapter(time: 0, title: "Previously on"), PlaybackChapter(time: 75, title: "Opening"), PlaybackChapter(time: 1500, title: "End Credits")]
        #expect(marks.recapEnd(chapters: chapters, position: 20, duration: 1560) == 75)
        #expect(marks.recapEnd(chapters: chapters, position: 74, duration: 1560) == nil)       // already at the end of it
        #expect(marks.recapEnd(chapters: chapters, position: 300, duration: 1560) == nil)
        #expect(marks.recapEnd(chapters: [PlaybackChapter(time: 0, title: "Chapter 1")], position: 10, duration: 1560) == nil)
    }

    @Test func creditsComeFromAChapterOrFromTheFirstSkipInTheSeries() {
        let marks = EpisodeMarks(defaults: defaults())
        let chapters = [PlaybackChapter(time: 0, title: "Episode"), PlaybackChapter(time: 1500, title: "End Credits")]
        #expect(marks.creditsStart(seriesID: "s", chapters: chapters, duration: 1560) == 1500)
        #expect(marks.creditsStart(seriesID: "s", chapters: [], duration: 1560) == nil)       // nothing known yet
        #expect(marks.isCreditsSkip(from: 1480, to: 1550, duration: 1560))
        #expect(!marks.isCreditsSkip(from: 600, to: 700, duration: 1560))                     // not near the end
        #expect(!marks.isCreditsSkip(from: 1480, to: 1500, duration: 1560))                   // does not reach the end
        marks.learn(seriesID: "s", from: 1480, duration: 1560)
        #expect(marks.creditsStart(seriesID: "s", chapters: [], duration: 1700) == 1620)      // 80 seconds before the end, for every episode of the series
        #expect(marks.creditsStart(seriesID: "other", chapters: [], duration: 1700) == nil)
        #expect(marks.creditsStart(seriesID: "s", chapters: [], duration: 300) == nil)        // too short to have credits
    }
}
