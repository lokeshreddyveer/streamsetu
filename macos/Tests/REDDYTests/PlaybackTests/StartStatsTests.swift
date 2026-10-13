import Testing
import Foundation
@testable import REDDY

@Suite struct StartStatsTests {
    private func stats() -> StartStats { StartStats(defaults: UserDefaults(suiteName: "startstats-\(UUID().uuidString)")!) }

    @Test func startsAreAveragedPerPlaylistAndPlayer() {
        let s = stats(), a = UUID(), b = UUID()
        for t in [10.0, 20.0, 30.0] { s.recordStart(source: a, engine: .avPlayer, live: false, seconds: t) }
        s.recordStart(source: b, engine: .mpv, live: true, seconds: 2)
        let rows = s.rows()
        let apple = rows.first { $0.source == a }!
        #expect(apple.record.plays == 3 && apple.record.average == 20 && apple.record.slowest == 30)
        #expect(rows.count == 2)
    }

    @Test func failuresAreCountedAndAbsurdTimesIgnored() {
        let s = stats(), a = UUID()
        s.recordFailure(source: a, engine: .mpv, live: false); s.recordFailure(source: a, engine: .mpv, live: false)
        s.recordStart(source: a, engine: .mpv, live: false, seconds: 5000)      // a stuck screen left open overnight is not a start time
        let r = s.rows().first!.record
        #expect(r.failures == 2 && r.plays == 0)
    }

    @Test func theRecordsSurviveARestart() {
        let d = UserDefaults(suiteName: "startstats-\(UUID().uuidString)")!
        let a = UUID()
        StartStats(defaults: d).recordStart(source: a, engine: .avPlayer, live: false, seconds: 12)
        #expect(StartStats(defaults: d).rows().first?.record.plays == 1)
        let again = StartStats(defaults: d); again.reset()
        #expect(StartStats(defaults: d).rows().isEmpty)
    }

    @Test func aFasterPlayerIsSuggestedOnlyWhenBothWereTriedAndTheGapIsReal() {
        let s = stats(), a = UUID()
        for _ in 0..<3 { s.recordStart(source: a, engine: .avPlayer, live: false, seconds: 16) }
        #expect(StartStats.suggestion(rows: s.rows(), source: a) == nil)                 // only one player tried
        for _ in 0..<3 { s.recordStart(source: a, engine: .mpv, live: false, seconds: 7) }
        let hint = StartStats.suggestion(rows: s.rows(), source: a)
        #expect(hint?.engine == .mpv && hint?.fasterBy == 9)
        let t = stats(), b = UUID()
        for _ in 0..<3 { t.recordStart(source: b, engine: .avPlayer, live: false, seconds: 10); t.recordStart(source: b, engine: .mpv, live: false, seconds: 8) }
        #expect(StartStats.suggestion(rows: t.rows(), source: b) == nil)                 // a 2 s gap is not worth a change
    }

    @Test func liveTVNeverDrivesTheSuggestion() {
        let s = stats(), a = UUID()
        for _ in 0..<3 { s.recordStart(source: a, engine: .avPlayer, live: true, seconds: 30); s.recordStart(source: a, engine: .mpv, live: true, seconds: 2) }
        #expect(StartStats.suggestion(rows: s.rows(), source: a) == nil)
    }
}
