import Testing
import Foundation
@testable import REDDY

@Suite("Album page rules") struct AlbumPageTests {
    private func track(_ id: String, _ title: String, disc: Int? = nil, ms: Int64 = 200_000) -> MusicTrack {
        MusicTrack(id: id, providerID: "p", title: title, durationMs: ms, trackNumber: nil, discNumber: disc, artists: [])
    }
    private func item(_ id: String, _ title: String, disc: Int? = nil, number: Int = 1, ms: Int64 = 1000, playable: Bool = true) -> MusicAlbumTrackItem {
        MusicAlbumTrackItem(id: id, title: title, artistLine: "", disc: disc, number: number, durationMs: ms, isPlayable: playable)
    }

    // MARK: pills

    @Test func aSingleWithOneTrackHasNoPills() {
        #expect(MusicAlbumPillRules.pills(.init(subkind: "single", trackCount: 1, hasAbout: true)).isEmpty)
    }

    @Test func aFilmSoundtrackGetsTheFilmPillAndOnlyPillsWithData() {
        let p = MusicAlbumPillRules.pills(.init(subkind: "soundtrack", trackCount: 8, hasFilm: true, hasVersions: true, hasCredits: true, hasAbout: true))
        #expect(p == [.overview, .tracks, .film, .versions, .credits, .about])
        let plain = MusicAlbumPillRules.pills(.init(subkind: "album", trackCount: 8, hasAbout: true))
        #expect(plain == [.overview, .tracks, .about])
    }

    // MARK: editions

    @Test func aDocumentedDubIsALanguageEdition() {
        let a = MusicAlbumEditionFacts(id: "a", title: "Film (Telugu)", year: 2020, trackCount: 6, dubLanguage: "tel")
        #expect(MusicAlbumEditionRules.badge(a, siblings: []) == .language("tel"))
    }

    @Test func deluxeInTheTitleNeedsASecondSignal() {
        let base = MusicAlbumEditionFacts(id: "b", title: "Night", year: 2015, trackCount: 10)
        let alone = MusicAlbumEditionFacts(id: "d", title: "Night (Deluxe)", year: 2016, trackCount: 10)
        let more = MusicAlbumEditionFacts(id: "d2", title: "Night (Deluxe)", year: 2016, trackCount: 14)
        #expect(MusicAlbumEditionRules.badge(alone, siblings: [base]) != .deluxe)
        #expect(MusicAlbumEditionRules.badge(more, siblings: [base]) == .deluxe)
        #expect(MusicAlbumEditionRules.badge(more, siblings: []) == .standard)
    }

    @Test func remasteredNeedsALaterYearThanASibling() {
        let base = MusicAlbumEditionFacts(id: "b", title: "Night", year: 1990, trackCount: 10)
        let re = MusicAlbumEditionFacts(id: "r", title: "Night (Remastered)", year: 2011, trackCount: 10)
        #expect(MusicAlbumEditionRules.badge(re, siblings: [base]) == .remastered)
        #expect(MusicAlbumEditionRules.badge(re, siblings: [re]) == .standard)
        #expect(MusicAlbumEditionRules.badge(base, siblings: [base, re]) == .original)
    }

    @Test func twoAlbumsWithTheSameTitleAreNotEditionsOfEachOther() {
        // The classifier only ever compares releases it is handed as siblings; with none handed it never invents a relationship.
        let a = MusicAlbumEditionFacts(id: "x", title: "Greatest Hits", year: 2000, trackCount: 12)
        #expect(MusicAlbumEditionRules.badge(a, siblings: []) == .standard)
    }

    @Test func comparisonFindsBonusTracksByFoldedTitle() {
        let a = MusicAlbumEditionFacts(id: "a", title: "A", year: 2015, trackCount: 3, trackTitles: ["One", "Two", "Three"])
        let b = MusicAlbumEditionFacts(id: "b", title: "B", year: 2016, trackCount: 5, trackTitles: ["one", "TWO", "Three", "Bonus Cut", "Demo"])
        let c = MusicAlbumEditionComparison.compare(a, b)
        #expect(c.trackCountDiffers && c.yearDiffers)
        #expect(c.onlyLeft.isEmpty)
        #expect(c.onlyRight == ["Bonus Cut", "Demo"])
    }

    @Test func aSideWithNoKnownSongsIsNeverCalledADifference() {
        let known = MusicAlbumEditionFacts(id: "a", title: "A", year: 2015, trackCount: 3, trackTitles: ["One", "Two", "Three"])
        let unknown = MusicAlbumEditionFacts(id: "b", title: "B", year: 2016, trackCount: 0)
        let c = MusicAlbumEditionComparison.compare(known, unknown)
        #expect(c.onlyLeft.isEmpty && c.onlyRight.isEmpty)
    }

    @Test func anAlbumPageListsItsEditionsAndReadsTheirSongsWhereTheyHang() async throws {
        let g = MusicInMemoryGraph()
        let src = MusicProvenance(source: .musicbrainz, license: .cc0, evidence: [MusicProvenance.statedToken])
        let album = try await g.upsert(MusicEntityDraft(kind: .album, name: "Night")).id
        let r1 = try await g.upsert(MusicEntityDraft(kind: .release, name: "Night", year: 2015)).id
        let r2 = try await g.upsert(MusicEntityDraft(kind: .release, name: "Night (Deluxe)", year: 2016)).id
        for r in [r1, r2] { _ = try await g.addEdge(MusicEdge(subject: r, predicate: .editionOf, object: album), provenance: src) }
        let s1 = try await g.upsert(MusicEntityDraft(kind: .recording, name: "One")).id
        let s2 = try await g.upsert(MusicEntityDraft(kind: .recording, name: "Two")).id
        _ = try await g.addEdge(MusicEdge(subject: s1, predicate: .trackOn, object: r1), provenance: src)
        _ = try await g.addEdge(MusicEdge(subject: s1, predicate: .trackOn, object: r2), provenance: src)
        _ = try await g.addEdge(MusicEdge(subject: s2, predicate: .trackOn, object: r2), provenance: src)
        let reader = MusicSoundtrackReader(g)
        let versions = await MusicAlbumReads.versions(reader, entity: album)
        #expect(Set(versions.map(\.id)) == [r1, r2], "an album concept lists its own editions")
        let fromRelease = await MusicAlbumReads.versions(reader, entity: r1)
        #expect(Set(fromRelease.map(\.id)) == [r2], "a release page lists its sibling, not itself or its parent")
        let titles = await MusicAlbumReads.editionTracks(reader, album)
        #expect(Set(titles.titles) == ["One", "Two"], "the songs of an album concept are read from its editions, once each")
        #expect(titles.titles.count == 2)
    }

    // MARK: tracks

    @Test func multiDiscOrderIsPreservedWithinEachDisc() {
        let items = [item("a", "A", disc: 2, number: 1), item("b", "B", disc: 1, number: 2), item("c", "C", disc: 1, number: 1), item("d", "D", disc: 2, number: 2)]
        let g = MusicAlbumTrackView.discs(items, disc: \.disc)
        #expect(g.map(\.disc) == [1, 2])
        #expect(g[0].items.map(\.id) == ["b", "c"])
        #expect(g[1].items.map(\.id) == ["a", "d"])
    }

    @Test func oneDiscIsNotGrouped() {
        let g = MusicAlbumTrackView.discs([item("a", "A"), item("b", "B")], disc: \.disc)
        #expect(g.count == 1 && g[0].disc == nil)
    }

    @Test func sortingIsAViewAndNeverChangesTheSource() {
        let source = [item("1", "Zebra", ms: 100), item("2", "Apple", ms: 300), item("3", "Mango", ms: 200)]
        let copy = source
        #expect(MusicAlbumTrackView.view(source, query: "", sort: .title, filter: .all, liked: [], played: []).map(\.id) == ["2", "3", "1"])
        #expect(MusicAlbumTrackView.view(source, query: "", sort: .duration, filter: .all, liked: [], played: []).map(\.id) == ["2", "3", "1"])
        #expect(MusicAlbumTrackView.view(source, query: "", sort: .releaseOrder, filter: .all, liked: [], played: []).map(\.id) == ["1", "2", "3"])
        #expect(source == copy)
    }

    @Test func searchAndFiltersNarrowTheView() {
        let source = [item("1", "Zebra"), item("2", "Apple"), item("3", "Mango")]
        #expect(MusicAlbumTrackView.view(source, query: " APP ", sort: .releaseOrder, filter: .all, liked: [], played: []).map(\.id) == ["2"])
        #expect(MusicAlbumTrackView.view(source, query: "", sort: .releaseOrder, filter: .favourites, liked: ["3"], played: []).map(\.id) == ["3"])
        #expect(MusicAlbumTrackView.view(source, query: "", sort: .releaseOrder, filter: .unplayed, liked: [], played: ["1", "3"]).map(\.id) == ["2"])
    }

    // MARK: playback modes

    @Test func continueAlbumQueuesOnlyWhatIsNotAlreadyComingUp() {
        let t = [track("1", "A"), track("2", "B"), track("3", "C"), track("4", "D")]
        let rest = MusicAlbumPlayback.continuation(t, currentUID: "p:1")
        #expect(rest.map(\.id) == ["2", "3", "4"])
        #expect(MusicAlbumPlayback.notQueued(rest, upcoming: ["p:3"]).map(\.id) == ["2", "4"])
        #expect(MusicAlbumPlayback.notQueued(rest, upcoming: ["p:2", "p:3", "p:4"]).isEmpty, "an album that is already queued adds nothing twice")
        #expect(MusicAlbumPlayback.continuation(t, currentUID: "p:4").isEmpty, "the last song has nothing after it")
    }

    @Test func playbackModesPickTheRightTracks() {
        let t = [track("1", "A", disc: 1), track("2", "B", disc: 1), track("3", "C", disc: 2)]
        func plan(_ m: MusicAlbumPlaybackMode, liked: Set<String> = [], played: Set<String> = []) -> MusicAlbumPlaybackPlan? { MusicAlbumPlayback.plan(m, tracks: t, liked: liked, played: played) }
        #expect(plan(.sequence)?.tracks.count == 3 && plan(.sequence)?.shuffled == false)
        #expect(plan(.shuffle)?.shuffled == true)
        #expect(plan(.disc(2))?.tracks.map(\.id) == ["3"])
        #expect(plan(.shuffleDisc(1))?.tracks.map(\.id) == ["1", "2"] && plan(.shuffleDisc(1))?.shuffled == true)
        #expect(plan(.fromTrack("p:2"))?.startIndex == 1)
        #expect(plan(.fromTrack("p:zzz")) == nil)
        #expect(plan(.favouritesOnly, liked: ["p:3"])?.tracks.map(\.id) == ["3"])
        #expect(plan(.favouritesOnly) == nil)
        #expect(plan(.unplayedOnly, played: ["p:1"])?.tracks.map(\.id) == ["2", "3"])
        #expect(plan(.continueAlbum(currentUID: "p:3"))?.startIndex == 2)
        #expect(plan(.continueAlbum(currentUID: nil)) == nil)
    }

    // MARK: availability

    @Test func availabilityIsReportedOnlyWhenPartial() {
        #expect(MusicAlbumAvailability.partial(playable: 8, total: 10)?.playable == 8)
        #expect(MusicAlbumAvailability.partial(playable: 10, total: 10) == nil)
        #expect(MusicAlbumAvailability.partial(playable: 0, total: 0) == nil)
    }

    // MARK: credits

    @Test func creditRolesMapToAlbumGroupsAndFilmCrewHasNone() {
        #expect(MusicAlbumCreditGroup.of(.singer) == .vocals)
        #expect(MusicAlbumCreditGroup.of(.musicDirector) == .composition)
        #expect(MusicAlbumCreditGroup.of(.lyricist) == .songwriting)
        #expect(MusicAlbumCreditGroup.of(.actor) == nil)
    }

    // MARK: listening

    @Test func listeningStatsUseTheAppsPlayRule() {
        let a = track("1", "A"), b = track("2", "B"), c = track("3", "C")
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let history = [
            PlayRecord(track: a, at: day, playedMs: 190_000),
            PlayRecord(track: a, at: day.addingTimeInterval(86_400), playedMs: 150_000),
            PlayRecord(track: b, at: day.addingTimeInterval(1000), playedMs: 10_000),     // a skip: not counted
            PlayRecord(track: track("9", "Other"), at: day, playedMs: 190_000),            // another album
        ]
        let s = MusicAlbumListening.stats(trackUIDs: [a.uid, b.uid, c.uid], history: history, liked: [c.uid, "p:9"])
        #expect(s.trackCount == 3 && s.explored == 1 && s.totalPlays == 2 && s.favourites == 1)
        #expect(s.mostPlayed?.uid == a.uid && s.mostPlayed?.plays == 2)
        #expect(s.firstListened == day && s.lastListened == day.addingTimeInterval(86_400))
        #expect(s.unplayed == [b.uid, c.uid])
        #expect(s.hasAny)
        #expect(!MusicAlbumListening.stats(trackUIDs: [a.uid], history: [], liked: []).hasAny)
    }

    // MARK: export

    @Test func exportKeepsAlbumOrderAndQuotesCSV() {
        let items = [item("1", "Say \"Hi\"", disc: 1, number: 1), item("2", "Two", disc: 1, number: 2)]
        let csv = MusicAlbumExport.csv(items: items)
        #expect(csv.contains("\"Say \"\"Hi\"\"\""))
        #expect(csv.components(separatedBy: "\n").first == "disc,number,title,artists,duration_seconds")
        #expect(MusicAlbumExport.plainText(title: "T", items: items).hasPrefix("T\n1-1. Say"))
    }
}
