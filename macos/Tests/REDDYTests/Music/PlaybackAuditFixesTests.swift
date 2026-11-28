import Testing
import Foundation
@testable import REDDY

/// Regression tests for the playback audit: queue sections, suggestions, paged playlists, id-less albums and the new wording.
private func song(_ i: Int) -> MusicTrack {
    MusicTrack(id: "t\(i)", providerID: "p", title: "Song \(i)", durationMs: 200_000, artists: [MusicArtistRef(id: "a\(i % 3)", name: "Artist \(i % 3)")])
}

@MainActor @Suite("Playback audit fixes") struct PlaybackAuditFixesTests {
    @Test func anAlbumWithNoIdGetsNoGoToItem() {
        var t = song(1)
        t.album = MusicAlbumRef(id: "", title: "Local Album")
        let titles = MusicTrackLinkItems.goTo(track: t, context: nil).map(\.title)
        #expect(!titles.contains(Localized.string("Go to %@", "Local Album")))
        t.album = MusicAlbumRef(id: "al1", title: "Real Album")
        #expect(MusicTrackLinkItems.goTo(track: t, context: nil).map(\.title).contains(Localized.string("Go to %@", "Real Album")))
    }

    @Test func anAlbumRefWithNoIdHasNoSharedArtworkIdentity() {
        let none = MusicArtworkSubject.derive(MusicAlbumRef(id: "", title: "A"), providerID: "p")
        let some = MusicArtworkSubject.derive(MusicAlbumRef(id: "x", title: "A"), providerID: "p")
        #expect(none.id == nil)
        #expect(some.id != nil)
    }

    @Test func moveToBottomStopsInFrontOfTheAutoplayRows() {
        var q = MusicQueue()
        q.replace(with: (0..<4).map(song), startAt: 0)
        q.append([song(10), song(11)], auto: true)
        let moved = q.moveUpcoming(from: 1, to: q.count - 1)
        #expect(moved)
        #expect(q.entries[3].track.id == "t1")
        #expect(q.entries[4].auto && q.entries[5].auto && !q.entries[3].auto)
    }

    @Test func rowsHandedOverLateJoinTheListNotTheQueuedRows() {
        var q = MusicQueue()
        q.replace(with: (0..<3).map(song), startAt: 0)
        q.append([song(20)], auto: true)
        let added = q.extendContext([song(5), song(6)])
        #expect(added == 2)
        let late = q.entries.filter { ["t5", "t6"].contains($0.track.id) }
        #expect(late.count == 2 && late.allSatisfy { !$0.queued && !$0.queuedEnd && !$0.auto })
        #expect(q.entries.last?.auto == true)
        #expect(q.manualRemovedRows().isEmpty)
        var empty = MusicQueue()
        #expect(empty.extendContext([song(1)]) == 0)
    }

    @Test func theFingerprintFollowsTheUnshuffledOrderAlone() {
        var q = MusicQueue()
        q.replace(with: (0..<5).map(song), startAt: 0)
        q.setShuffle(true)
        var s = q.snapshot(position: 0)
        let a = MusicQueue(snapshot: s).fingerprint()
        s.preShuffle = s.preShuffle.map { Array($0.reversed()) }
        let b = MusicQueue(snapshot: s).fingerprint()
        #expect(a != b)
    }

    @Test func aSuggestionFetchThatPlacedNothingIsNotAskedAgainUntilSomethingChanges() {
        var gate = MusicSuggestGate()
        let key = MusicSuggestGate.Key(epoch: 1, own: 8, suggested: 1)
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(gate.shouldFetch(key, now: now))
        gate.placedNothing(key)
        #expect(!gate.shouldFetch(key, now: now))
        #expect(gate.shouldFetch(MusicSuggestGate.Key(epoch: 1, own: 7, suggested: 1), now: now))
        gate.reset()
        gate.answeredNothing(now: now)
        #expect(!gate.shouldFetch(key, now: now.addingTimeInterval(5)))
        #expect(gate.shouldFetch(key, now: now.addingTimeInterval(31)))
    }

    @Test func suggestionsAreNotWantedWhenTheTailHasNoRoomForOne() {
        #expect(MusicSmartSuggest.needed(ownUpcoming: 40, suggestedUpcoming: 0, ownAfterLastSuggestion: 2) == 0)
        #expect(MusicSmartSuggest.needed(ownUpcoming: 40, suggestedUpcoming: 0, ownAfterLastSuggestion: 40) > 0)
    }

    @Test func keepIsNotOfferedOnAnAutoplayRowThatAlreadyPlayed() {
        var auto = MusicQueue.Entry(track: song(1), auto: true)
        #expect(MusicQueueLogic.offersKeep(auto, past: false))
        #expect(!MusicQueueLogic.offersKeep(auto, past: true))
        auto.suggested = true
        #expect(MusicQueueLogic.offersKeep(auto, past: true))
    }

    @Test func aLongPlaylistIsReadPageByPageAndStopsOnARepeatedPage() async {
        let first = MusicPage<MusicTrack>(items: [song(0), song(1)], next: .offset(offset: 2, limit: 2))
        let all = await MusicEntityActions.allPages(first) { page in
            guard case .offset(let o, _) = page else { return nil }
            if o == 2 { return MusicPage(items: [song(2), song(3)], next: .offset(offset: 4, limit: 2)) }
            if o == 4 { return MusicPage(items: [song(4)], next: nil) }
            return nil
        }
        #expect(all.map(\.id) == ["t0", "t1", "t2", "t3", "t4"])
        let loop = await MusicEntityActions.allPages(first) { _ in MusicPage(items: [song(0), song(1)], next: .offset(offset: 2, limit: 2)) }
        #expect(loop.count == 2)
        let capped = await MusicEntityActions.allPages(first, more: { page in
            guard case .offset(let o, _) = page else { return nil }
            return MusicPage(items: [song(o)], next: .offset(offset: o + 1, limit: 1))
        }, maxPages: 3)
        #expect(capped.count == 4)
    }

    @Test func newPlaybackWordingHasHindiAndTelugu() throws {
        let keys = ["First match in your order", "Playing next", "Playing next: %d songs", "Couldn't play %1$@: %2$@",
                    "Sent to the host. It plays only if the host agrees.", "The host added your song.", "The host did not add your song."]
        for code in ["hi", "te"] {
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/Localization/\(code).lproj/Localizable.strings")
            let table = try #require(NSDictionary(contentsOf: url) as? [String: String])
            for k in keys { #expect(table[k] != nil && table[k] != k, "\(code): \(k)") }
        }
    }
}
