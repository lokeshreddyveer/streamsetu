import Foundation
import Testing
@testable import REDDY

/// A music player stand-in with the contract of the real one: `pauseForOtherAudio` pauses and keeps the queue and the position
/// (Services/Music/Playback/MusicPlayer.swift: `func pauseForOtherAudio() { if isPlaying { pause() } }`, and pause() touches no queue).
@MainActor final class FakeMusicPlayer {
    var queue = ["q0", "q1", "q2"]
    var current = "q0"
    var position = 41.0
    var isPlaying = true
    var pauses = 0
    func snapshot() -> [String] { queue + [current, String(position), String(isPlaying)] }
}

@MainActor @Suite("G8 film page: Watch Movie") struct G8WatchTests {
    private func openedFilm(_ g: G8Graph, _ film: MusicEntityID, bridge: FakeWatchBridge, gated: Bool = false) async -> MusicFilmGraphModel {
        let center = await g8Center(g.store)
        let model = await MainActor.run { MusicFilmGraphModel(center: center, watch: bridge.logic) }
        await MainActor.run { model.open(film); model.refreshWatch(gated: gated) }
        await g8Wait(seconds: 0.5) { model.watch != .hidden || gated }
        return model
    }

    @Test func aFilmInTheLibraryShowsTheButtonAndOneTapCallsTheBridgeOnceWithTheTMDBId() async throws {
        let c = try await Cinema2.make()
        let bridge = await FakeWatchBridge()
        await MainActor.run { bridge.library = [39039] }
        let model = await openedFilm(c.g, c.awaara, bridge: bridge)
        let state = await MainActor.run { model.watch }
        #expect(state == .available(MusicFilmWatchRef(tmdbID: 39039, title: "Awaara", year: 1951)))
        let outcome = await MainActor.run { model.pressWatch(gated: false) }
        let (opened, presses) = await MainActor.run { (bridge.opened, model.watchPresses) }
        #expect(outcome == .opened && opened.count == 1 && opened[0].tmdbID == 39039 && presses == 1)
        await MainActor.run { model.close() }
    }

    @Test func aFilmNotInTheLibraryHasNoButtonOnlyAQuietLineAndTapsDoNothing() async throws {
        let c = try await Cinema2.make()
        let bridge = await FakeWatchBridge()
        let model = await openedFilm(c.g, c.awaara, bridge: bridge)
        let state = await MainActor.run { model.watch }
        #expect(state == .notInLibrary)
        let outcome = await MainActor.run { model.pressWatch(gated: false) }
        let opened = await MainActor.run { bridge.opened }
        #expect(outcome == .unavailable && opened.isEmpty)
        await MainActor.run { model.close() }
    }

    @Test func aGatedProfileHidesBothAndNeverAsksTheLibrary() async throws {
        let c = try await Cinema2.make()
        let bridge = await FakeWatchBridge()
        await MainActor.run { bridge.library = [39039] }
        let model = await openedFilm(c.g, c.awaara, bridge: bridge, gated: true)
        try await Task.sleep(nanoseconds: 30_000_000)
        let (state, asked) = await MainActor.run { (model.watch, bridge.asked) }
        #expect(state == .hidden && asked == 0)
        await MainActor.run { model.close() }
    }

    @Test func aFilmWithNoTMDBIdIsNotClaimedAsMissingFromTheLibrary() async throws {
        let c = try await Cinema2.make()
        let bridge = await FakeWatchBridge()
        let model = await openedFilm(c.g, c.noTMDB, bridge: bridge)
        try await Task.sleep(nanoseconds: 30_000_000)
        let state = await MainActor.run { model.watch }
        #expect(state == .hidden, "we cannot tell, so we say nothing")
        await MainActor.run { model.close() }
    }

    @Test func aTapAfterTheLibraryChangedFallsBackToTheQuietLine() async throws {
        let c = try await Cinema2.make()
        let bridge = await FakeWatchBridge()
        await MainActor.run { bridge.library = [39039] }
        let model = await openedFilm(c.g, c.awaara, bridge: bridge)
        await MainActor.run { bridge.library = [] }
        let outcome = await MainActor.run { model.pressWatch(gated: false) }
        await g8Wait { model.watch == .notInLibrary }
        let (state, opened) = await MainActor.run { (model.watch, bridge.opened.count) }
        #expect(outcome == .unavailable && state == .notInLibrary && opened == 0)
        await MainActor.run { model.close() }
    }

    @Test func openingTheFilmPageAndPressingWatchLeavesTheMusicQueueAndPlayerUntouchedAndPlayOnTheMovieThenPausesMusicKeepingTheQueue() async throws {
        let c = try await Cinema2.make()
        let bridge = await FakeWatchBridge()
        await MainActor.run { bridge.library = [39039] }
        let (ownership, player) = await MainActor.run { () -> (AudioOwnership, FakeMusicPlayer) in
            let o = AudioOwnership(), p = FakeMusicPlayer()
            o.register(ClosureAudioParticipant(.music, isPlaying: { p.isPlaying }, pause: { if p.isPlaying { p.isPlaying = false; p.pauses += 1 } }))
            o.register(ClosureAudioParticipant(.nativePlayer, isPlaying: { false }, pause: {}))
            _ = o.claim(.music, reason: .musicPlay)
            return (o, p)
        }
        let before = await MainActor.run { player.snapshot() }
        let model = await openedFilm(c.g, c.awaara, bridge: bridge)
        // The page is open and the person presses Watch Movie: the app opens its movie page. Nothing here touches audio.
        _ = await MainActor.run { model.pressWatch(gated: false) }
        let (afterTap, owner1) = await MainActor.run { (player.snapshot(), ownership.owner) }
        #expect(afterTap == before && owner1 == .music, "D5: the page and the button leave audio playing")
        // Then Play on the movie: the app's native player claims the audio and music pauses (queue and position kept).
        await MainActor.run { _ = ownership.claim(.nativePlayer, reason: .nativePlay) }
        let (afterPlay, owner2, pauses) = await MainActor.run { (player.snapshot(), ownership.owner, player.pauses) }
        #expect(owner2 == .nativePlayer && pauses == 1)
        #expect(Array(afterPlay.prefix(4)) == Array(before.prefix(4)) && afterPlay[4] == before[4] && afterPlay[5] == "false", "queue, current song and position are kept; only isPlaying changed")
        await MainActor.run { model.close() }
    }
}

/// Films with TMDB ids for the Watch Movie cases.
private struct Cinema2 {
    let g = G8Graph()
    var awaara = MusicEntityID(kind: .film, token: "0000000000000"), noTMDB = MusicEntityID(kind: .film, token: "0000000000000")
    static func make() async throws -> Cinema2 {
        var c = Cinema2()
        c.awaara = try await c.g.film("Awaara", 1951, tmdb: 39039)
        c.noTMDB = try await c.g.film("Obscure Film", 1962)
        return c
    }
}

@MainActor @Suite("G8 film page: model, routing, reasons") struct G8ModelTests {
    @Test func twoViewsOnOneFilmShareOneLoadOfEachSection() async throws {
        let c = try await Cinema.make()
        let center = await g8Center(c.g.store)
        let logic = MusicFilmWatchLogic(isInLibrary: { _ in false }, open: { _ in false })
        let a = await MainActor.run { MusicFilmGraphModel(center: center, watch: logic) }, b = await MainActor.run { MusicFilmGraphModel(center: center, watch: logic) }
        await MainActor.run { a.open(c.awaara); b.open(c.awaara) }
        await g8Wait { a.section(MusicFilmSectionKey.cast).phase == .loaded }
        let (runs, leases, same) = await MainActor.run { (a.entity!.sectionRuns, center.leaseCount(c.awaara), a.entity === b.entity) }
        #expect(same && leases == 2 && MusicFilmSectionKey.core.allSatisfy { runs[$0] == 1 }, "\(runs)")
        await MainActor.run { b.loadLazy(MusicFilmSectionKey.related); a.loadLazy(MusicFilmSectionKey.related) }
        await g8Wait { a.section(MusicFilmSectionKey.related).phase == .loaded }
        let relRuns = await MainActor.run { a.entity!.sectionRuns[MusicFilmSectionKey.related] }
        #expect(relRuns == 1)
        await MainActor.run { a.close(); b.close() }
        let after = await MainActor.run { center.leaseCount(c.awaara) }
        #expect(after == 0)
    }

    @Test func leavingCancelsLazyWorkAndDropsTheLease() async throws {
        let c = try await Cinema.make()
        let center = await g8Center(c.g.store)
        let model = await MainActor.run { MusicFilmGraphModel(center: center, watch: MusicFilmWatchLogic(isInLibrary: { _ in false }, open: { _ in false })) }
        await MainActor.run { model.open(c.awaara); model.loadLazy(MusicFilmSectionKey.castMusic); model.close() }
        let (lease, held) = await MainActor.run { (model.lease, center.leaseCount(c.awaara)) }
        #expect(lease == nil && held == 0)
        await MainActor.run { model.loadLazy(MusicFilmSectionKey.related) }   // after close: ignored
        #expect(await MainActor.run { model.section(MusicFilmSectionKey.related).phase } == .idle)
    }

    @Test func songsWithNoCopyAreMatchedInOneBoundedBatchAndNeverAskedTwice() async throws {
        let g = G8Graph()
        let film = try await g.film("Songs", 1999)
        let ost = try await g.put(.album, "Songs OST", year: 1999, subkind: "soundtrack")
        try await g.edge(ost, .soundtrackOf, film, prov: G8Graph.matcher)
        for i in 0..<40 {
            let r = try await g.put(.recording, "Song \(i)")
            try await g.edge(r, .trackOn, ost, attrs: { var a = EdgeAttributes(); a.position = i + 1; return a }())
        }
        final class Calls: @unchecked Sendable { var batches: [Int] = []; let lock = NSLock() }
        let calls = Calls()
        let center = await g8Center(g.store)
        let model = await MainActor.run {
            MusicFilmGraphModel(center: center, watch: MusicFilmWatchLogic(isInLibrary: { _ in false }, open: { _ in false }), matcher: { rows in
                calls.lock.withLock { calls.batches.append(rows.count) }
                return rows.enumerated().map { i, r in i % 2 == 0 ? MusicTrack(id: "m-\(r.title)", providerID: "ytmusic", title: r.title, durationMs: 1, artists: []) : nil }
            })
        }
        await MainActor.run { model.open(film) }
        await g8Wait { model.section(MusicFilmSectionKey.songs).phase == .loaded }
        await MainActor.run { model.resolveUnplayable() }
        await g8Wait { !model.resolvingSongs && !model.matched.isEmpty }
        await MainActor.run { model.resolveUnplayable() }
        await g8Wait { !model.resolvingSongs }
        try await Task.sleep(nanoseconds: 20_000_000)
        let (batches, matched, unplayable, playable) = await MainActor.run { (calls.lock.withLock { calls.batches }, model.matched.count, model.unplayableCount, model.playableOriginals.count) }
        #expect(batches.allSatisfy { $0 <= MusicFilmGraphModel.matchBatch } && batches.reduce(0, +) == 40, "bounded batches that together ask every song once, no repeats: \(batches)")
        #expect(matched == 20 && playable == 20 && unplayable == 20, "unmatched songs stay unplayable instead of being faked")
        await MainActor.run { model.close() }
    }

    @Test func theFilmPageOpensFromTheFilmLayersValuesByAnyOfTheFilmsIds() async throws {
        let g = G8Graph()
        let film = try await g.put(.film, "Awaara", year: 1951, lang: "hi", ids: [ExternalID(.wikidata, "Q858681")])
        var info = MusicFilmInfo(title: "Awaara", year: 1951, language: "hi", tmdbID: 39039, wikidataID: "Q858681", imdbID: "tt0043306", source: .tmdb)
        #expect(await MusicFilmPageRouting.filmID(for: info, store: g.store) == film, "found by its Wikidata id although TMDB is tried first")
        info.wikidataID = nil; info.tmdbID = nil; info.imdbID = nil
        let byName = await MusicFilmPageRouting.filmID(for: info, store: g.store)
        #expect(byName == .provisional(kind: .film, name: "Awaara", year: 1951) && byName != film, "no id: a name-and-year id, never the 1951 entity by luck")
        var other = info; other.year = 2010
        #expect(await MusicFilmPageRouting.filmID(for: other, store: g.store) != byName)
        let tmdbOnly = MusicFilmInfo(title: "Awaara", year: 1951, language: "hi", tmdbID: 39039, source: .tmdb)
        #expect(await MusicFilmPageRouting.filmID(for: tmdbOnly, store: g.store) == .provisional(kind: .film, externalID: ExternalID(.tmdbMovie, "39039")))
    }

    @Test func musicPlanSaysLoadingUntilEverythingSettledThenOneQuietLine() {
        typealias B = MusicFilmPageBuilders
        #expect(B.musicPlan(soundtracks: .loading, songs: .idle, haveAlbums: false, haveSongs: false, enriching: false) == .loading)
        #expect(B.musicPlan(soundtracks: .empty, songs: .empty, haveAlbums: false, haveSongs: false, enriching: true) == .loading, "enrichment may still add an album")
        #expect(B.musicPlan(soundtracks: .empty, songs: .empty, haveAlbums: false, haveSongs: false, enriching: false) == .noSoundtrack)
        #expect(B.musicPlan(soundtracks: .failed, songs: .failed, haveAlbums: false, haveSongs: false, enriching: false) == .failed)
        #expect(B.musicPlan(soundtracks: .failed, songs: .empty, haveAlbums: false, haveSongs: false, enriching: false) == .failed)
        #expect(B.musicPlan(soundtracks: .partial, songs: .loading, haveAlbums: true, haveSongs: false, enriching: true) == .showSections)
    }

    @Test func crewFoldsTheMusicLineWhenComposerAndMusicDirectorAreTheSamePeople() {
        let p = MusicEntityID.provisional(kind: .person, name: "A R Rahman"), q = MusicEntityID.provisional(kind: .person, name: "Gulzar")
        func item(_ id: MusicEntityID, _ n: String, _ r: MusicRole) -> MusicFilmPersonItem {
            MusicFilmPersonItem(person: id, name: n, imageRef: nil, role: r, character: nil, order: nil, status: .verified, creditLevel: .film, nameOnly: false, attribution: nil, birthYear: nil)
        }
        let same = MusicFilmPageBuilders.crew([item(p, "A R Rahman", .composer), item(p, "A R Rahman", .musicDirector), item(q, "Gulzar", .screenwriter)])
        #expect(same.map(\.role) == [.screenwriter, .musicDirector])
        let differ = MusicFilmPageBuilders.crew([item(p, "A R Rahman", .composer), item(q, "Gulzar", .musicDirector)])
        #expect(differ.map(\.role) == [.musicDirector, .composer])
        // Cast: a name-only entry that repeats a known person is dropped; a name-only person alone stays.
        var nameOnly = item(MusicEntityID.provisional(kind: .person, name: "x1"), "A R Rahman", .actor); nameOnly.nameOnly = true
        var lone = item(MusicEntityID.provisional(kind: .person, name: "x2"), "Walk On", .actor); lone.nameOnly = true
        #expect(MusicFilmPageBuilders.cast([nameOnly, item(p, "A R Rahman", .actor), lone]).map(\.name) == ["A R Rahman", "Walk On"])
    }

    @Test func languageNamesFollowTheLocaleAndKeepUnknownCodesVisible() {
        let en = Locale(identifier: "en")
        #expect(MusicFilmLanguageNames.name(for: "hi", locale: en) == "Hindi" && MusicFilmLanguageNames.name(for: "tel", locale: en) == "Telugu")
        #expect(MusicFilmLanguageNames.name(for: "zzz", locale: en) == "ZZZ")
    }
}
