import Testing
import Foundation
@testable import REDDY

/// "Reset recommendations" promises that Home, Radio and autoplay start fresh while history, statistics, likes and playlists stay. The graph shelves of
/// Listen Now ("Music directors you play", "Because you played ...") are built from the learned affinity, which ignored the reset date, so they survived it.
/// The reset must clear the affinity (and the recommender's cache) before the Home feed is wiped and composed again.
@MainActor
@Suite("Flow: Reset recommendations clears the graph shelves", .serialized)
struct ResetRecommendationsFlowTests {
    private let composerOld = MusicEntityID.derive(kind: .person, aliasKey: "reset-composer-old")
    private let filmOld = MusicEntityID.derive(kind: .film, aliasKey: "reset-film-old")
    private let songOld = MusicEntityID.derive(kind: .recording, aliasKey: "reset-song-old")
    private let songNew = MusicEntityID.derive(kind: .recording, aliasKey: "reset-song-new")

    @Test func theAffinityBehindTheShelvesForgetsOldPlaysButCountsNewOnes() async {
        let clock = GraphTestClock()
        let t0 = clock.now
        let old = MusicPlayEvent(kind: .completed, at: t0, recording: songOld, composers: [composerOld], film: filmOld)
        let new = MusicPlayEvent(kind: .completed, at: t0.addingTimeInterval(20), recording: songNew)
        let events = [old, new]
        let store = MusicAffinityStore(clock: clock.reader) { events }
        clock.advance(30)
        let before = await store.vector()
        #expect(before.composer[composerOld] != nil && before.film[filmOld] != nil, "before the reset the old plays shape the shelves")

        clock.advance(-15)                                       // the reset happens between the two plays
        await store.reset()
        clock.advance(15)
        let after = await store.vector()

        #expect(after.composer[composerOld] == nil, "a composer learned before the reset must not feed \"Music directors you play\"")
        #expect(after.film[filmOld] == nil)
        #expect(after.recording[songOld] == nil)
        #expect(after.recording[songNew] != nil, "plays after the reset count again")
    }

    @Test func theHomeFeedModelStartsEmptyAfterClearAll() throws {
        let suite = "reset.flow.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MusicHomeFeedModel(defaults: defaults)
        model.clearAll()
        #expect(model.feed == nil)
        #expect(model.graph.isEmpty)
        #expect(model.graphPhase == .idle)
        #expect(model.continueItems.isEmpty)
    }

    @Test func theCutoffHidesOlderPlaysFromEveryReaderAndUndoRestoresThem() {
        MusicTasteReset.undo()
        defer { MusicTasteReset.undo() }
        let track = MusicTrack(id: "r1", providerID: "p", title: "Reset song", durationMs: 100_000, artists: [])
        let cut = Date(timeIntervalSince1970: 2_000_000_000)
        let older = PlayRecord(track: track, at: cut.addingTimeInterval(-100), playedMs: 90_000)
        let newer = PlayRecord(track: track, at: cut.addingTimeInterval(100), playedMs: 90_000)
        MusicTasteReset.mark(cut)
        #expect(MusicTasteReset.cutoff == cut)
        #expect(MusicTasteReset.visible([older, newer]).count == 1)
        MusicTasteReset.undo()
        #expect(MusicTasteReset.visible([older, newer]).count == 2)
    }

    /// The button's own order of work (the settings view is not instantiable here): the cutoff is marked, hidden recommendations and radio learning are
    /// cleared, then the affinity is reset and only after that the Home feed is wiped, so the next compose cannot be built from what was learned.
    @Test func theResetButtonResetsTheAffinityBeforeItWipesTheFeed() throws {
        let file = try #require(GuardScanner.files(under: ["Features/Music"]).first { $0.path == "Features/Music/MusicTasteViews.swift" })
        let code = file.code
        let start = try #require(code.range(of: "private func reset() {"))
        let tail = String(code[start.upperBound...])
        let body = String(tail[..<(tail.range(of: "\n    }\n")?.lowerBound ?? tail.endIndex)])
        let mark = try #require(body.range(of: "MusicTasteReset.mark()"))
        let hidden = try #require(body.range(of: "MusicHiddenRecommendations.shared.clear()"))
        let radio = try #require(body.range(of: "RadioService.shared.forgetLearned()"))
        let affinity = try #require(body.range(of: "MusicRecommenderRuntime.shared.resetAffinity()"))
        let feed = try #require(body.range(of: "MusicHomeFeedModel.shared.clearAll()"))
        #expect(mark.lowerBound < affinity.lowerBound)
        #expect(hidden.lowerBound < affinity.lowerBound && radio.lowerBound < affinity.lowerBound)
        #expect(affinity.lowerBound < feed.lowerBound, "the feed must not be recomposed from the affinity that is about to be reset")
    }

    @Test func resettingTheAffinityAlsoEmptiesTheRecommendersCache() throws {
        let file = try #require(GuardScanner.files(under: ["Services/Music/Graph/Recommendation"]).first { $0.path.hasSuffix("MusicRecommenderRuntime+App.swift") })
        let line = try #require(file.code.components(separatedBy: "\n").first { $0.contains("func resetAffinity()") })
        #expect(line.contains("affinity.reset()") && line.contains("recommender.cache.removeAll()"))
    }
}
