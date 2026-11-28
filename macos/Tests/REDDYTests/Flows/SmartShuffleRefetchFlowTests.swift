import Testing
import Foundation
@testable import REDDY

/// Smart Shuffle asks for suggestions from a place that runs on every position tick (four times a second). With nothing remembered, an answer that
/// placed nothing, an empty answer or an offline source made it ask again on the very next tick, for as long as music played. The gate remembers the
/// queue an attempt was made for, and backs off after empty answers; the room test says there is none when the stretch after the last suggestion is too short.
@Suite("Flow: Smart Shuffle does not refetch back to back")
struct SmartShuffleRefetchFlowTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let tick = 0.25

    /// Runs `seconds` of ticks the way the player does: ask `need` against the gate, and answer the way the closure says.
    private func run(seconds: Double, key: MusicSuggestGate.Key, need: Int, answer: (inout MusicSuggestGate, Date) -> Void) -> Int {
        var gate = MusicSuggestGate()
        var fetches = 0
        var now = start
        var elapsed = 0.0
        while elapsed < seconds {
            now = start.addingTimeInterval(elapsed)
            if need > 0, gate.shouldFetch(key, now: now) { fetches += 1; answer(&gate, now) }
            elapsed += tick
        }
        return fetches
    }

    @Test func anAnswerThatPlacedNothingIsNotAskedAgainForTheSameQueue() {
        let key = MusicSuggestGate.Key(epoch: 4, own: 20, suggested: 0)
        let fetches = run(seconds: 600, key: key, need: 3) { gate, _ in gate.placedNothing(key) }
        #expect(fetches == 1, "ten minutes of ticks on an unchanged queue must ask once")
    }

    @Test func aChangedQueueIsAskedAboutAgain() {
        var gate = MusicSuggestGate()
        let a = MusicSuggestGate.Key(epoch: 4, own: 20, suggested: 0)
        let b = MusicSuggestGate.Key(epoch: 4, own: 19, suggested: 0)       // one song has played
        gate.placedNothing(a)
        #expect(!gate.shouldFetch(a, now: start))
        #expect(gate.shouldFetch(b, now: start))
        gate.placedNothing(b)
        #expect(!gate.shouldFetch(b, now: start))
        let c = MusicSuggestGate.Key(epoch: 5, own: 19, suggested: 0)       // the queue was replaced or reshuffled
        #expect(gate.shouldFetch(c, now: start))
    }

    @Test func emptyAnswersBackOffInsteadOfFetchingEveryTick() {
        let key = MusicSuggestGate.Key(epoch: 1, own: 30, suggested: 0)
        let fetches = run(seconds: 60, key: key, need: 5) { gate, now in gate.answeredNothing(now: now) }
        // First try at once, the next one after the first back-off (30 s), then the next waits 120 s.
        #expect(fetches == 2, "an offline source must not be asked 240 times a minute")
        #expect(MusicSuggestGate.backoff == MusicSuggestGate.backoff.sorted(), "the waits only grow")
    }

    @Test func aPlacedAnswerResetsTheGateSoTheNextShortfallIsServed() {
        var gate = MusicSuggestGate()
        let key = MusicSuggestGate.Key(epoch: 2, own: 12, suggested: 0)
        gate.answeredNothing(now: start)
        #expect(!gate.shouldFetch(key, now: start.addingTimeInterval(1)))
        gate.reset()
        #expect(gate.shouldFetch(key, now: start.addingTimeInterval(1)))
    }

    @Test func noRoomAfterTheLastSuggestionMeansNothingIsNeeded() {
        // 12 own songs upcoming and no suggestion yet: room for some.
        #expect(MusicSmartSuggest.needed(ownUpcoming: 12, suggestedUpcoming: 0) > 0)
        // The same totals, but only 3 own songs after the last suggestion: `interleave` cannot place one, so asking is pointless.
        #expect(MusicSmartSuggest.needed(ownUpcoming: 12, suggestedUpcoming: 0, ownAfterLastSuggestion: 3) == 0)
        #expect(MusicSmartSuggest.needed(ownUpcoming: 12, suggestedUpcoming: 0, ownAfterLastSuggestion: 4) > 0)
        // Enough suggestions already queued.
        #expect(MusicSmartSuggest.needed(ownUpcoming: 12, suggestedUpcoming: 3) == 0)
    }

    @Test func interleaveNeverPlacesASuggestionLastOrFirst() {
        var rng = SystemRandomNumberGenerator()
        let own = (0..<10).map { i in MusicQueue.Entry(track: MusicTrack(id: "o\(i)", providerID: "p", title: "Own \(i)", durationMs: 1, artists: [])) }
        let sug = (0..<5).map { i in MusicQueue.Entry(track: MusicTrack(id: "s\(i)", providerID: "p", title: "Sug \(i)", durationMs: 1, artists: [])) }
        let out = MusicSmartSuggest.interleave(own: own, suggestions: sug, using: &rng)
        #expect(out.first?.suggested == false)
        #expect(out.last?.suggested == false)
        let placed = out.filter { $0.suggested }.count
        #expect(placed >= 1)
    }
}
