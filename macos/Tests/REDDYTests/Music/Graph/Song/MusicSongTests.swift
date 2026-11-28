import Foundation
import Testing
@testable import REDDY

// The song page's pure logic and its section loaders, against hand-built graphs (no network, no player, no UI).

private func ctx(_ f: SongFixture, _ key: String, env: MusicSongLoaderEnv = MusicSongLoaderEnv()) async throws -> MusicSongContext {
    let r = try await MusicSongContextLoader(env: env).load(entity: f[key], store: f.graph, report: SongPartials().reporter)
    return r.items.compactMap { $0.base as? MusicSongContext }[0]
}

private func credits(_ f: SongFixture, _ key: String) async throws -> [MusicSongCreditGroup] {
    let r = try await MusicSongPageCreditsLoader(env: MusicSongLoaderEnv()).load(entity: f[key], store: f.graph, report: SongPartials().reporter)
    return r.items.compactMap { $0.base as? MusicSongCreditGroup }
}

private func names(_ g: MusicSongCreditGroup?) -> [String] { g?.people.map(\.name) ?? [] }

// MARK: version typing

@Suite struct SongVersionTests {
    @Test func coverFromVerifiedEdgeLinksToTheOriginal() async throws {
        let f = await SongFixture.awaara()
        let snap = try #require(try await f.graph.entity(f["cover"]))
        let edges = try await f.graph.edges(of: f["cover"], predicate: .alternateOf, direction: .outgoing, limit: 10)
        let v = MusicSongVersioning.classify(snapshot: snap, outgoing: edges)
        #expect(v.kind == .cover)
        #expect(v.originalID == f["awara"])
        #expect(v.status == .verified && !v.isInferred)
        #expect(v.showsBadge && v.linksToOriginal)
        #expect(MusicSongVersioning.badgeKey(v.kind, inferred: v.isInferred) == "Cover")
        #expect(MusicSongVersioning.originalLineKey(v) == "Cover of %1$@")
    }

    @Test func remixFromAMatcherEdgeIsInferredButStillLinked() async throws {
        let f = await SongFixture.awaara()
        let snap = try #require(try await f.graph.entity(f["remix"]))
        let edges = try await f.graph.edges(of: f["remix"], predicate: .alternateOf, direction: .outgoing, limit: 10)
        let v = MusicSongVersioning.classify(snapshot: snap, outgoing: edges)
        #expect(v.kind == .remix && v.isInferred)
        #expect(v.originalID == f["awara"])
        #expect(MusicSongVersioning.badgeKey(v.kind, inferred: v.isInferred) == "Possibly remix")
    }

    @Test func titleAloneGivesAnInferredKindAndNoLink() async throws {
        let f = await SongFixture.awaara()
        let snap = try #require(try await f.graph.entity(f["karaoke"]))
        let v = MusicSongVersioning.classify(snapshot: snap, outgoing: [])
        #expect(v.kind == .karaoke && v.source == .title && v.isInferred)
        #expect(v.originalID == nil && !v.linksToOriginal)
        #expect(MusicSongVersioning.originalLineKey(v) == nil)
    }

    @Test func aPlainRecordingHasNoBadge() async throws {
        let f = await SongFixture.awaara()
        let snap = try #require(try await f.graph.entity(f["awara"]))
        let v = MusicSongVersioning.classify(snapshot: snap, outgoing: [])
        #expect(v.kind == .unknown && !v.showsBadge)
        #expect(MusicSongVersioning.badgeKey(v.kind, inferred: false) == nil)
    }

    @Test func aRetractedEdgeIsIgnored() async throws {
        let f = await SongFixture.awaara()
        let snap = try #require(try await f.graph.entity(f["cover"]))
        var e = MusicEdge(subject: f["cover"], predicate: .alternateOf, object: f["awara"], confidence: 0.9, status: .verified)
        e.attributes.versionKind = .cover; e.tombstone = true
        #expect(MusicSongVersioning.classify(snapshot: snap, outgoing: [e]).kind == .unknown)
    }

    @Test func groupsAreOrderedAndLiveHasItsOwnSection() async throws {
        let f = await SongFixture.awaara()
        let r = try await MusicSongVersionsLoader(env: MusicSongLoaderEnv()).load(entity: f["awara"], store: f.graph, report: SongPartials().reporter)
        let items = r.items.compactMap { $0.base as? MusicSongVersionItem }
        let groups = MusicSongVersioning.group(items, excluding: f["awara"])
        #expect(groups.map(\.kind) == [.cover, .remix, .karaoke, .unknown])
        #expect(groups.first { $0.kind == .remix }?.items.map(\.id) == [f["remix"]])
        #expect(groups.first { $0.kind == .karaoke }?.items.map(\.id) == [f["karaoke"]])
        // the 1960 recording shares the work but nothing says what kind it is
        #expect(groups.first { $0.kind == .unknown }?.items.map(\.id) == [f["rerec"]])
        #expect(groups.flatMap(\.items).allSatisfy { $0.kind != .live })
        #expect(MusicSongVersioning.liveItems(items, excluding: f["awara"]).map(\.id) == [f["live"]])
        #expect(!groups.flatMap(\.items).contains { $0.id == f["awara"] })
    }

    @Test func aCoverPageListsItsOriginalAndItsSiblings() async throws {
        let f = await SongFixture.awaara()
        let r = try await MusicSongVersionsLoader(env: MusicSongLoaderEnv()).load(entity: f["cover"], store: f.graph, report: SongPartials().reporter)
        let items = r.items.compactMap { $0.base as? MusicSongVersionItem }
        let original = try #require(items.first { $0.relation == .original })
        #expect(original.id == f["awara"])
        #expect(items.contains { $0.id == f["remix"] && $0.relation == .sibling })
    }

    @Test func strongestRelationWinsWhenARecordingArrivesTwice() {
        let id = MusicEntityID(kind: .recording, token: "AAAAAAAAAAAAA")
        let a = MusicSongVersionItem(id: id, name: "x", kind: .remix, confidence: 0.9, relation: .sibling)
        let b = MusicSongVersionItem(id: id, name: "x", kind: .remix, confidence: 0.1, relation: .version)
        #expect(MusicSongVersioning.dedupe([a, b]).first?.relation == .version)
    }
}

// MARK: credits

@Suite struct SongCreditTests {
    @Test func awaraHoonCredits() async throws {
        let f = await SongFixture.awaara()
        let groups = try await credits(f, "awara")
        #expect(names(groups.first { $0.kind == .singers }) == ["Mukesh"])
        #expect(names(groups.first { $0.kind == .composers }) == ["Shankar-Jaikishan"])
        #expect(names(groups.first { $0.kind == .musicDirectors }) == ["Shankar-Jaikishan"])
        #expect(names(groups.first { $0.kind == .lyricists }) == ["Shailendra"])
        #expect(groups.map(\.kind) == [.singers, .composers, .musicDirectors, .lyricists])
    }

    @Test func aProviderPerformerIsNotCalledASinger() {
        let p = MusicEntityID(kind: .person, token: "PPPPPPPPPPPPP"), r = MusicEntityID(kind: .recording, token: "RRRRRRRRRRRRR")
        let e = MusicEdge(subject: r, predicate: .performedBy, object: p, role: .performer)
        let groups = MusicSongCredits.build(rows: [.init(edge: e, name: "Someone")])
        #expect(groups.map(\.kind) == [.performers])
    }

    @Test func instrumentsAndArrangersAreOtherCredits() {
        let r = MusicEntityID(kind: .recording, token: "RRRRRRRRRRRRR")
        func pid(_ t: String) -> MusicEntityID { MusicEntityID(kind: .person, token: t) }
        var sitar = MusicEdge(subject: r, predicate: .performedBy, object: pid("SSSSSSSSSSSSS"), role: .instrumentalist); sitar.attributes.instrument = "sitar"
        let arr = MusicEdge(subject: r, predicate: .composedBy, object: pid("AAAAAAAAAAAAA"), role: .arranger)
        let prod = MusicEdge(subject: r, predicate: .producedBy, object: pid("DDDDDDDDDDDDD"), role: .producer)
        let groups = MusicSongCredits.build(rows: [.init(edge: sitar, name: "Ravi"), .init(edge: arr, name: "Sebastian"), .init(edge: prod, name: "Pia")])
        #expect(groups.map(\.kind) == [.arrangers, .producers, .instruments])
        #expect(groups.last?.people.first?.instrument == "sitar")
    }

    @Test func twoSingersWithTheSameNameStayTwoAndAreToldApart() async throws {
        let f = await SongFixture.awaara()
        await f.entity("kumar1", .person, "Kumar Sanu", uid: "jiosaavn:a-ks1", year: 1957, country: "IN")
        await f.entity("kumar2", .person, "Kumar Sanu", uid: "jiosaavn:a-ks2", year: 1990, country: "US")
        await f.edge("awara", .performedBy, "kumar1", role: .singer, order: 1)
        await f.edge("awara", .performedBy, "kumar2", role: .singer, order: 2)
        let singers = try #require(try await credits(f, "awara").first { $0.kind == .singers })
        let ks = singers.people.filter { $0.name == "Kumar Sanu" }
        #expect(ks.count == 2 && ks[0].id != ks[1].id)
        #expect(Set(ks.compactMap(\.disambiguator)) == ["b. 1957 · IN", "b. 1990 · US"])
        #expect(ks.allSatisfy { $0.homonymCount == 2 && ($0.homonymIndex == 1 || $0.homonymIndex == 2) })
        #expect(singers.people.first { $0.name == "Mukesh" }?.homonymCount == 0)
    }

    @Test func homonymsWithNothingKnownAreStillMarked() {
        let r = MusicEntityID(kind: .recording, token: "RRRRRRRRRRRRR")
        let a = MusicEntityID(kind: .person, token: "AAAAAAAAAAAAA"), b = MusicEntityID(kind: .person, token: "BBBBBBBBBBBBB")
        let rows = [MusicEdge(subject: r, predicate: .performedBy, object: a, role: .singer), MusicEdge(subject: r, predicate: .performedBy, object: b, role: .singer)]
            .map { MusicSongCredits.Row(edge: $0, name: "Anand Bakshi") }
        let g = MusicSongCredits.build(rows: rows)
        #expect(g[0].people.count == 2)
        #expect(g[0].people.allSatisfy { $0.disambiguator == nil && $0.homonymCount == 2 })
    }

    @Test func aSongWithNoCreditsHasNoGroupsAndTheQuietLine() async throws {
        let f = SongFixture()
        await f.entity("bare", .recording, "Untitled Demo", uid: "jiosaavn:s-bare", provisional: true)
        let groups = try await credits(f, "bare")
        #expect(MusicSongCredits.isEmpty(groups))
        #expect(MusicSongVisibility.state(phase: .empty, itemCount: 0, quietWhenEmpty: MusicSongVisibility.quietWhenEmpty(.credits)) == .quietEmpty)
        #expect(MusicSongVisibility.state(phase: .empty, itemCount: 0, quietWhenEmpty: MusicSongVisibility.quietWhenEmpty(.versions)) == .hidden)
    }

    @Test func anIndependentArtistShowsOnlyWhatWasCredited() async throws {
        let f = SongFixture()
        await f.entity("indie", .recording, "Rooftop Summer", uid: "audius:t1", year: 2024, provisional: true)
        await f.entity("band", .person, "Neon Harbour", provisional: true)
        await f.edge("indie", .performedBy, "band", role: .performer, source: .jiosaavn, score: 0.6)
        let groups = try await credits(f, "indie")
        #expect(groups.map(\.kind) == [.performers])
        let c = try await ctx(f, "indie")
        #expect(c.album == nil && c.film == nil && c.isProvisional)
        #expect(c.version.showsBadge == false)
    }

    @Test func creditsReportSingersBeforeTheRest() async throws {
        let f = await SongFixture.awaara()
        let p = SongPartials()
        let r = try await MusicSongPageCreditsLoader(env: MusicSongLoaderEnv()).load(entity: f["awara"], store: f.graph, report: p.reporter)
        let first = try #require(p.results.first)
        #expect(first.items.compactMap { $0.base as? MusicSongCreditGroup }.map(\.kind) == [.singers])
        #expect(r.items.count == 4)
    }

    @Test func aWorksComposerReachesItsRecording() async throws {
        let f = await SongFixture.awaara()
        await f.entity("lyr", .person, "Lyricist From Work", uid: "mb:lyr")
        await f.edge("work", .writtenBy, "lyr", role: .lyricist)
        #expect(names(try await credits(f, "awara").first { $0.kind == .lyricists }).contains("Lyricist From Work"))
    }
}

// MARK: context: album and film

@Suite struct SongContextTests {
    @Test func hindiFilmSongLinksItsAlbumAndAnInferredFilm() async throws {
        let f = await SongFixture.awaara()
        let c = try await ctx(f, "awara")
        #expect(c.album?.id == f["albumA"])
        #expect(c.album?.displayName == "Awaara (1951)")
        let film = try #require(c.film)
        #expect(film.film.id == f["awaara51"] && film.film.displayName == "Awaara (1951)")
        #expect(film.origin == .viaSoundtrack && film.isInferred && !film.isPlainText)
        #expect(film.evidence == ["via-soundtrack"])
        #expect(c.language == nil || c.language == "hin" || !(c.language ?? "").isEmpty)
    }

    @Test func teluguSongGetsItsFilmOnlyAsInferred() async throws {
        let f = await SongFixture.telugu()
        let c = try await ctx(f, "butta")
        let film = try #require(c.film)
        #expect(film.film.name == "Ala Vaikunthapurramuloo" && film.film.year == 2020)
        #expect(film.isInferred && film.origin == .viaSoundtrack)
        #expect(c.album?.id == f["rel"])
    }

    @Test func aStatedSongInFilmIsVerified() async throws {
        let f = await SongFixture.awaara()
        let c = try await ctx(f, "mera")
        let film = try #require(c.film)
        #expect(film.origin == .direct && !film.isInferred && film.film.id == f["shree420"])
    }

    @Test func aTitleHintStaysPlainText() async throws {
        let f = SongFixture()
        await f.entity("hint", .recording, "Kuch Song (From \"Mystery\")", uid: "jiosaavn:s-hint", provisional: true)
        await f.entity("hintFilm", .film, "Mystery", attrs: ["hintOnly": "1"], provisional: true)
        await f.edge("hint", .featuredIn, "hintFilm", source: .jiosaavn, score: 0.4)
        let film = try #require(try await ctx(f, "hint").film)
        #expect(film.isPlainText && film.origin == .titleHint && film.isInferred)
    }

    @Test func twoFilmsOfOneTitleAreNeverMixedUp() async throws {
        let f = await SongFixture.awaara()
        let film = try #require(try await ctx(f, "awara").film)
        #expect(film.film.id != f["awaara10"])
        #expect(f["awaara10"] != f["awaara51"])
    }

    @Test func aSongWithoutFilmOrAlbumShowsNeither() async throws {
        let f = SongFixture()
        await f.entity("solo", .recording, "Solo", uid: "audius:solo")
        let c = try await ctx(f, "solo")
        #expect(c.film == nil && c.album == nil)
    }
}

// MARK: related, more by, films, playlists, similar

@Suite struct SongRelatedTests {
    @Test func albumMatesAreRelatedWithTheirReason() async throws {
        let f = await SongFixture.awaara()
        let r = try await MusicSongRelatedLoader(env: MusicSongLoaderEnv()).load(entity: f["awara"], store: f.graph, report: SongPartials().reporter)
        let items = r.items.compactMap { $0.base as? MusicSongRelatedItem }
        let ghar = try #require(items.first { $0.id == f["ghar"] })
        #expect(ghar.reason.kind == .sameAlbum || ghar.reason.kind == .samePerformer || ghar.reason.kind == .sameComposer)
        #expect(!items.contains { $0.id == f["awara"] })
        // versions are not "related songs": they have their own sections
        #expect(!items.contains { [f["remix"], f["karaoke"], f["live"], f["cover"]].contains($0.id) })
        #expect(items.allSatisfy { !$0.reason.key.isEmpty })
        let scores = items.map(\.score)
        #expect(scores == scores.sorted(by: >))
    }

    @Test func bandsOrderTheReasons() {
        let a = MusicSongRelatedItem(id: MusicEntityID(kind: .recording, token: "AAAAAAAAAAAAA"), name: "a", reason: MusicSongReason(kind: .samePerformer, subject: "x"), score: 0)
        let b = MusicSongRelatedItem(id: MusicEntityID(kind: .recording, token: "BBBBBBBBBBBBB"), name: "b", reason: MusicSongReason(kind: .sameAlbum, subject: "y"), score: 0)
        let c = MusicSongRelatedItem(id: MusicEntityID(kind: .recording, token: "CCCCCCCCCCCCC"), name: "c", reason: MusicSongReason(kind: .sameComposer, subject: "z"), score: 0)
        let ranked = MusicSongRelated.rank([(a, 1), (b, 0.1), (c, 0.5)])
        #expect(ranked.map(\.name) == ["b", "c", "a"])
    }

    @Test func aWeakInferredReasonReadsLikeAFirmOneWithoutAHedge() {
        let weak = MusicSongRelated.makeReason(.sameFilm, subject: "Awaara", confidence: 0.5, status: .inferred)
        let strong = MusicSongRelated.makeReason(.sameFilm, subject: "Awaara", confidence: 0.9, status: .inferred)
        #expect(weak.key == strong.key && weak.key == "From the film %1$@" && weak.possibly)
    }

    @Test func duplicateReasonsKeepTheStrongestAndCountTheRest() {
        let id = MusicEntityID(kind: .recording, token: "AAAAAAAAAAAAA")
        let x = MusicSongRelatedItem(id: id, name: "x", reason: MusicSongReason(kind: .samePerformer, subject: "p"), score: 0)
        let y = MusicSongRelatedItem(id: id, name: "x", reason: MusicSongReason(kind: .sameAlbum, subject: "q"), score: 0)
        let r = MusicSongRelated.rank([(x, 0.9), (y, 0.9)])
        #expect(r.count == 1 && r[0].reason.kind == .sameAlbum && r[0].alsoCount == 1)
    }

    @Test func providerSuggestionsJoinWithoutDuplicates() async throws {
        let f = await SongFixture.awaara()
        let graphItems = [MusicSongRelatedItem(id: f["ghar"], name: "Ghar Aaya Mera Pardesi", artistLine: "Lata Mangeshkar", reason: MusicSongReason(kind: .sameAlbum, subject: "Awaara"), score: 1000)]
        func track(_ id: String, _ title: String, _ artist: String) -> MusicTrack { MusicTrack(id: id, providerID: "ytmusic", title: title, durationMs: 1, artists: [MusicArtistRef(id: "", name: artist)]) }
        let provider = [track("1", "Ghar Aaya Mera Pardesi", "Lata Mangeshkar"),      // same song as a graph item
                        track("2", "Awara Hoon", "Mukesh"),                             // the page's own song
                        track("3", "Ramaiya Vastavaiya", "Mukesh"), track("3", "Ramaiya Vastavaiya", "Mukesh")]
        let merged = MusicSongRelated.merge(graph: graphItems, provider: provider, providerName: "YouTube Music", excluding: [f["awara"]], selfName: "Awara Hoon")
        #expect(merged.map(\.name) == ["Ghar Aaya Mera Pardesi", "Ramaiya Vastavaiya"])
        #expect(merged[1].reason.kind == .providerSuggestion && merged[1].reason.subject == "YouTube Music" && merged[1].track?.id == "3")
        #expect(merged[1].id == MusicEntityID.provisional(kind: .recording, providerUID: "ytmusic:3"))
    }

    @Test func moreByTheSingerIsTheSingersOtherSongs() async throws {
        let f = await SongFixture.awaara()
        let r = try await MusicSongMoreLoader(env: MusicSongLoaderEnv(), section: .moreBySinger).load(entity: f["awara"], store: f.graph, report: SongPartials().reporter)
        let items = r.items.compactMap { $0.base as? MusicSongRelatedItem }
        #expect(Set(items.map(\.id)) == [f["dum"], f["kisi"], f["jaane"], f["mera"]])
        #expect(items.allSatisfy { $0.reason.kind == .samePerformer && $0.reason.subject == "Mukesh" })
        #expect(!items.contains { $0.id == f["awara"] })
    }

    @Test func moreByTheComposerCoversTheMusicDirectorToo() async throws {
        let f = await SongFixture.awaara()
        let r = try await MusicSongMoreLoader(env: MusicSongLoaderEnv(), section: .moreByComposer).load(entity: f["awara"], store: f.graph, report: SongPartials().reporter)
        let items = r.items.compactMap { $0.base as? MusicSongRelatedItem }
        #expect(Set(items.map(\.id)) == [f["kisi"], f["mera"]])
        #expect(items.allSatisfy { $0.reason.subject == "Shankar-Jaikishan" })
    }

    @Test func otherFilmsOfTheCreditedPeopleExcludeTheSongsOwnFilm() async throws {
        let f = await SongFixture.awaara()
        let r = try await MusicSongFilmsLoader(env: MusicSongLoaderEnv()).load(entity: f["awara"], store: f.graph, report: SongPartials().reporter)
        let items = r.items.compactMap { $0.base as? MusicSongRelatedItem }
        #expect(items.map(\.id) == [f["shree420"]])
        #expect(items[0].reason.kind == .sameComposer && items[0].reason.subject == "Shankar-Jaikishan")
        #expect(!items.contains { $0.id == f["awaara51"] || $0.id == f["awaara10"] })
    }

    @Test func playlistsComeOnlyFromRealEdgesAndTheLibrary() async throws {
        let f = await SongFixture.awaara()
        let r = try await MusicSongPlaylistsLoader(env: MusicSongLoaderEnv()).load(entity: f["awara"], store: f.graph, report: SongPartials().reporter)
        let provider = r.items.compactMap { $0.base as? MusicSongPlaylistItem }
        #expect(provider.map(\.name) == ["Golden Hits"] && provider[0].source == .provider && provider[0].entityID == f["playlist"])
        let mine = UUID(), other = UUID()
        let local = MusicSongPlaylists.local(containing: ["ytmusic:AbCdEfGhIjK"], in: [
            .init(id: mine, name: "Road trip", trackUIDs: ["x:1", "ytmusic:AbCdEfGhIjK"], created: Date(timeIntervalSince1970: 5)),
            .init(id: other, name: "Gym", trackUIDs: ["x:1"])])
        #expect(local.map(\.localID) == [mine])
        #expect(MusicSongPlaylists.combine(local: local, provider: provider).map(\.name) == ["Road trip", "Golden Hits"])
        #expect(MusicSongPlaylists.local(containing: [], in: []).isEmpty)
    }

    @Test func similarRecordingsNeedTwoSharedFacetKinds() async throws {
        let f = await SongFixture.awaara()
        let r = try await MusicSongSimilarLoader(env: MusicSongLoaderEnv()).load(entity: f["awara"], store: f.graph, report: SongPartials().reporter)
        let items = r.items.compactMap { $0.base as? MusicSongRelatedItem }
        #expect(items.contains { $0.id == f["ghar"] })
        let ghar = try #require(items.first { $0.id == f["ghar"] })
        #expect(ghar.reason.kind == .sharedFacets)
        #expect(ghar.reason.subject?.contains("Hindi") == true)
        // Dum Bhar shares language and era (two kinds) and is similar too; the page's own song never is
        #expect(items.contains { $0.id == f["dum"] } && !items.contains { $0.id == f["awara"] })
    }

    @Test func sharedFacetCounting() {
        func i(_ t: String) -> MusicEntityID { MusicEntityID(kind: .language, token: t) }
        var a = MusicSongRelated.Facets(), b = MusicSongRelated.Facets()
        a.language = [i("LLLLLLLLLLLLL")]; b.language = [i("LLLLLLLLLLLLL")]
        #expect(MusicSongRelated.sharedFacets(a, b).kinds == 1)
        a.era = [MusicEntityID(kind: .era, token: "EEEEEEEEEEEEE")]; b.era = a.era
        #expect(MusicSongRelated.sharedFacets(a, b).kinds == 2)
    }
}

// MARK: visibility

@Suite struct SongVisibilityTests {
    @Test func blockStates() {
        #expect(MusicSongVisibility.state(phase: .idle, itemCount: 0) == .skeleton)
        #expect(MusicSongVisibility.state(phase: .loading, itemCount: 0) == .skeleton)
        #expect(MusicSongVisibility.state(phase: .loading, itemCount: 3) == .content)
        #expect(MusicSongVisibility.state(phase: .partial, itemCount: 1) == .content)
        #expect(MusicSongVisibility.state(phase: .loaded, itemCount: 2) == .content)
        #expect(MusicSongVisibility.state(phase: .loaded, itemCount: 0) == .hidden)
        #expect(MusicSongVisibility.state(phase: .empty, itemCount: 0, quietWhenEmpty: true) == .quietEmpty)
        #expect(MusicSongVisibility.state(phase: .failed, itemCount: 0) == .hidden)
        #expect(MusicSongVisibility.state(phase: .failed, itemCount: 4) == .content)
    }

    @Test func blocksAreTheNineThatSayDifferentThings() {
        // Live is a kind of version, the film is in the header, similar is a second Related list, and in-playlists is about the library, not the song.
        #expect(MusicSongBlock.order.map(\.rawValue) == ["header", "credits", "lyrics", "versions", "samples", "related", "moreBySinger", "moreByComposer", "sources"])
    }
}

// MARK: lyrics

@Suite struct SongLyricsLogicTests {
    @Test func noLyricsIsAQuietMiss() {
        #expect(MusicSongLyricsLogic.display(lyrics: nil, loading: false, finished: true) == .none(missed: true))
        #expect(MusicSongLyricsLogic.display(lyrics: nil, loading: false, finished: false) == .none(missed: false))
        #expect(MusicSongLyricsLogic.display(lyrics: nil, loading: true, finished: false) == .skeleton)
    }

    @Test func plainLyricsDropSectionMarkers() {
        let l = MusicLyrics(plain: "[Chorus]\nAwara hoon\n\nYa gardish mein hoon\n")
        #expect(MusicSongLyricsLogic.display(lyrics: l, loading: false, finished: true, limit: 1) == .lines(shown: ["Awara hoon"], total: 2, synced: false))
    }

    @Test func syncedAndInstrumental() {
        let s = MusicLyrics(synced: [MusicLyricLine(timeMs: 0, text: "a"), MusicLyricLine(timeMs: 10, text: " ")])
        #expect(MusicSongLyricsLogic.display(lyrics: s, loading: false, finished: true) == .lines(shown: ["a"], total: 1, synced: true))
        #expect(MusicSongLyricsLogic.display(lyrics: MusicLyrics(instrumental: true), loading: false, finished: true) == .instrumental)
    }

    @Test func romanisationOnlyForNonLatinText() {
        #expect(MusicSongLyricsLogic.needsRomanisation(["आवारा हूँ"]))
        #expect(MusicSongLyricsLogic.needsRomanisation(["బుట్ట బొమ్మ"]))
        #expect(!MusicSongLyricsLogic.needsRomanisation(["Awara hoon", "café"]))
    }

    @Test func sharedTranslationOnlyForThePlayingSong() {
        #expect(MusicSongLyricsLogic.usesSharedTranslation(pageTrackUID: "a:1", playingUID: "a:1"))
        #expect(!MusicSongLyricsLogic.usesSharedTranslation(pageTrackUID: "a:1", playingUID: "a:2"))
        #expect(!MusicSongLyricsLogic.usesSharedTranslation(pageTrackUID: "a:1", playingUID: nil))
    }
}

// MARK: sources and the playable row

@Suite struct SongSourceTests {
    private func base() -> MusicTrack {
        MusicTrack(id: "AbCdEfGhIjK", providerID: "ytmusic", title: "Awara Hoon", durationMs: 233_000, artists: [MusicArtistRef(id: "UC1", name: "Mukesh")], isrc: "INA000100001")
    }

    @Test func trustFollowsTheMatcherScore() {
        #expect(MusicSongSources.trust(score: 0.9, deltaMs: nil) == .verified)
        #expect(MusicSongSources.trust(score: 0.7, deltaMs: 1_500) == .verified)
        #expect(MusicSongSources.trust(score: 0.7, deltaMs: 6_000) == .unverified)
        #expect(MusicSongSources.trust(score: 0.7, deltaMs: nil) == .unverified)
    }

    @Test func qualityLabels() {
        #expect(MusicSongSources.qualityLabel(streams: nil) == nil)
        #expect(MusicSongSources.qualityLabel(streams: [MusicStream(url: "u", codec: "aac", container: "m4a", bitrate: 128), MusicStream(url: "v", codec: "aac", container: "m4a", bitrate: 256)]) == "256 kbps")
        #expect(MusicSongSources.qualityLabel(streams: [MusicStream(url: "u", codec: "flac", container: "flac", bitrate: nil, sampleRate: 44_100)]) == "Lossless")
    }

    @Test func listIsOrderedDeduplicatedAndBadged() {
        let own = MusicSongSources.ownRow(of: base(), providerName: "YouTube Music", isAudioProvider: true, chosen: nil)
        let twin = MusicCanonicalTwin(providerID: "jiosaavn", sourceID: "s1", title: "Awara Hoon", artist: "Mukesh", album: nil, durationMs: 233_500, externalURL: nil, score: 0.9, deltaMs: 500, hasStreams: true)
        let weak = MusicCanonicalTwin(providerID: "audius", sourceID: "s2", title: "Awara Hoon", artist: "x", album: nil, durationMs: 250_000, externalURL: nil, score: 0.65, deltaMs: 17_000)
        let rows = MusicSongSources.combine([MusicSongSources.source(twin: weak, providerName: "Audius", chosen: nil), MusicSongSources.source(twin: twin, providerName: "JioSaavn", chosen: "jiosaavn:s1")]
                                            + [own].compactMap { $0 } + [MusicSongSources.source(twin: twin, providerName: "JioSaavn", chosen: nil)])
        // The copy the matcher is unsure of (another song with a similar name) is not listed beside verified ones.
        #expect(rows.map(\.providerID) == ["ytmusic", "jiosaavn"])
        #expect(rows.map(\.trust) == [.verified, .verified])
        #expect(rows[1].isChosen && rows.count == 2)
        // With nothing verified, the unsure copies are all there is, and are shown badged.
        let only = MusicSongSources.combine([MusicSongSources.source(twin: weak, providerName: "Audius", chosen: nil)])
        #expect(only.map(\.providerID) == ["audius"] && only[0].trust == .unverified)
        // The YouTube providers serve the same video under one id: one row, not "YouTube Music" and "YouTube Music (basic)".
        let a = MusicCanonicalTwin(providerID: "ytmusic", sourceID: "VID", title: "T", artist: "A", album: nil, durationMs: 200_000, externalURL: nil, score: 0.95, deltaMs: 0)
        let b = MusicCanonicalTwin(providerID: "youtube-music", sourceID: "VID", title: "T", artist: "A", album: nil, durationMs: 200_000, externalURL: nil, score: 0.95, deltaMs: 0)
        let one = MusicSongSources.combine([MusicSongSources.source(twin: b, providerName: "YouTube Music (basic)", chosen: nil), MusicSongSources.source(twin: a, providerName: "YouTube Music", chosen: nil)])
        #expect(one.count == 1 && one[0].providerName == "YouTube Music")
        #expect(MusicSongSources.ownRow(of: base(), providerName: "Apple", isAudioProvider: false, chosen: nil) == nil)
    }

    @Test func playFromASourceKeepsTheSongsWordsAndCredits() {
        let twin = MusicCanonicalTwin(providerID: "ytmusic", sourceID: "ZZZZZZZZZZZ", title: "Awara Hoon - Topic", artist: "Mukesh", album: nil, durationMs: 232_000, externalURL: "https://x", score: 0.9, deltaMs: 1_000)
        let s = MusicSongSources.source(twin: twin, providerName: "YouTube Music", chosen: nil)
        let t = MusicSongSources.playable(from: s, base: base())
        #expect(t.uid == "ytmusic:ZZZZZZZZZZZ" && t.title == "Awara Hoon" && t.videoID == "ZZZZZZZZZZZ" && t.isrc == "INA000100001")
        #expect(t.artists.first?.name == "Mukesh" && t.durationMs == 233_000)
    }

    @Test func playableRowFromTheGraph() async throws {
        let f = await SongFixture.awaara()
        let snap = try #require(try await f.graph.entity(f["awara"]))
        let ids = try await f.graph.externalIDs(of: f["awara"])
        let t = try #require(MusicSongPlayable.track(snapshot: snap, externalIDs: ids, artists: [MusicArtistRef(id: "a", name: "Mukesh")], album: nil, preferredProviders: ["jiosaavn", "ytmusic"]))
        #expect(t.providerID == "ytmusic" && t.id == "AbCdEfGhIjK" && t.title == "Awara Hoon" && t.durationMs == 233_000)
        #expect(t.videoID == "AbCdEfGhIjK" && t.isrc == "INA000100001")
        #expect(MusicSongPlayable.uids(ids) == ["ytmusic:AbCdEfGhIjK"])
        // a recording with no provider alias has no row to play from the graph alone
        let bare = MusicEntitySnapshot(id: f["work"], subkind: nil, name: "Awara Hoon", nameLatin: "awara hoon", lang: nil, year: nil, yearEnd: nil, country: nil, durationMs: nil,
                                       imageRef: nil, attrs: [:], provisional: false, state: .live, pinned: false, mergedInto: nil, createdAt: Date(), updatedAt: Date())
        #expect(MusicSongPlayable.track(snapshot: bare, externalIDs: [ExternalID(.mbWork, "w")], artists: [], album: nil) == nil)
    }

    @Test func aGraphOnlyRecordingGetsAWordsOnlyRowAndNoPlayButton() async throws {
        let f = SongFixture()
        await f.entity("mbOnly", .recording, "Awara Hoon (MB)", extra: [ExternalID(.mbid, "abc")])
        let snap = try #require(try await f.graph.entity(f["mbOnly"]))
        let ids = try await f.graph.externalIDs(of: f["mbOnly"])
        #expect(MusicSongPlayable.track(snapshot: snap, externalIDs: ids, artists: [], album: nil) == nil)
        let base = MusicSongPlayable.searchBase(snapshot: snap, artists: [MusicArtistRef(id: "", name: "Mukesh")], album: nil)
        #expect(base.providerID == MusicSongPlayable.searchBaseProviderID && base.title == "Awara Hoon (MB)" && base.artists.first?.name == "Mukesh")
        // a copy found for it plays under its own provider, with the page song's words
        let twin = MusicCanonicalTwin(providerID: "jiosaavn", sourceID: "x9", title: "Awara Hoon", artist: "Mukesh", album: nil, durationMs: nil, externalURL: nil, score: 0.9, deltaMs: nil)
        let t = MusicSongSources.playable(from: MusicSongSources.source(twin: twin, providerName: "JioSaavn", chosen: nil), base: base)
        #expect(t.uid == "jiosaavn:x9" && t.title == "Awara Hoon (MB)")
    }

    @Test func videoIDsAreOnlyYouTubeShaped() {
        #expect(MusicSongPlayable.youTubeVideoID([ExternalID(.provider, "ytmusic:AbCdEfGhIjK")]) == "AbCdEfGhIjK")
        #expect(MusicSongPlayable.youTubeVideoID([ExternalID(.provider, "ytmusic:short")]) == nil)
        #expect(MusicSongPlayable.youTubeVideoID([ExternalID(.provider, "jiosaavn:AbCdEfGhIjK")]) == nil)
        #expect(MusicSongPlayable.youTubeVideoID([ExternalID(.ytVideo, "dQw4w9WgXcQ")]) == "dQw4w9WgXcQ")
    }
}

// MARK: gate, model integration, outage, credits wiring

@Suite struct SongModelTests {
    @Test func theGateNeverRunsMoreThanThreeAndCancelsWaiters() async throws {
        let gate = MusicSongLoadGate(limit: 3)
        let counter = SongPeak()
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<12 { g.addTask { _ = try? await gate.run { await counter.enter(); try? await Task.sleep(nanoseconds: 5_000_000); await counter.leave() } } }
        }
        let peak = await counter.peak
        #expect(peak <= 3 && peak >= 2)
        // a waiter that is cancelled leaves the queue with CancellationError
        let tiny = MusicSongLoadGate(limit: 1)
        let hold = Task { try await tiny.run { try await Task.sleep(nanoseconds: 200_000_000) } }
        try await Task.sleep(nanoseconds: 20_000_000)
        let waiter = Task { try await tiny.run { 1 } }
        try await Task.sleep(nanoseconds: 20_000_000)
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        _ = try await hold.value
    }

    @MainActor @Test func allSectionsLoadThroughTheModelWithSharedReads() async throws {
        let f = await SongFixture.awaara()
        let store = MusicEntityStore(graph: f.graph)
        let model = MusicEntityModel(id: f["awara"], store: store)
        let env = MusicSongLoaderEnv()
        model.start()
        for _ in 0..<200 where model.snapshot == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(model.snapshot?.name == "Awara Hoon")
        for l in env.loaders() { model.load(l) }
        for _ in 0..<400 where model.isWorking { try await Task.sleep(nanoseconds: 5_000_000) }
        for k in MusicSongSectionKey.allCases {
            let s = model.section(k.loaderKey)
            #expect(s.phase == .loaded || s.phase == .empty, "\(k.rawValue) is \(s.phase)")
        }
        #expect(model.section(MusicSongSectionKey.credits.loaderKey).items(MusicSongCreditGroup.self).count == 4)
        let walks = await env.hood.walks, reads = await env.credits.reads, gatePeak = await env.gate.peak
        #expect(walks == 1)
        #expect(reads == 1)
        #expect(gatePeak <= 3)
        #expect(model.sectionRuns[MusicSongSectionKey.related.loaderKey] == 1)
    }

    @MainActor @Test func aMetadataOutageStillShowsTheCachedGraph() async throws {
        let f = await SongFixture.awaara()
        let store = MusicEntityStore(graph: f.graph, enricher: SongOutageEnricher())
        let model = MusicEntityModel(id: f["awara"], store: store)
        model.start()
        for _ in 0..<200 where model.snapshot == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        for _ in 0..<100 where store.enrichmentRuns == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(model.phase == .loaded || model.phase == .partial)
        model.load(MusicSongPageCreditsLoader(env: MusicSongLoaderEnv()))
        for _ in 0..<200 where model.section("song.credits").phase != .loaded { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(model.section("song.credits").items(MusicSongCreditGroup.self).map(\.kind).contains(.singers))
    }

    @MainActor @Test func cancellingTheModelStopsTheSections() async throws {
        let f = await SongFixture.awaara()
        let store = MusicEntityStore(graph: f.graph)
        let model = MusicEntityModel(id: f["awara"], store: store)
        model.start()
        for _ in 0..<200 where model.snapshot == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        model.load(MusicSongRelatedLoader(env: MusicSongLoaderEnv()))
        model.cancelAll()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(model.section("song.related").phase != .loading)
    }
}

actor SongPeak {
    private var now = 0
    private(set) var peak = 0
    func enter() { now += 1; peak = max(peak, now) }
    func leave() { now -= 1 }
}

// MARK: YouTube Music credits wired into the graph

@Suite struct SongCreditWiringTests {
    private func credits() -> [MusicCredit] {
        [MusicCredit(name: "Mukesh", role: .performer), MusicCredit(name: "Shankar-Jaikishan", role: .composer), MusicCredit(name: "Shailendra", role: .lyricist)]
    }

    @Test func writesWhatThePanelListedAndOnlyForAVideoID() async throws {
        let f = await SongFixture.awaara()
        let calls = SongCallCounter()
        let fetcher = MusicRecordingCreditsFetcher(store: f.graph, youTubeMusic: { id in await calls.record(id); return credits() })
        // a recording without a YouTube video id never asks
        let none = await fetcher.run(f["ghar"])
        let asked0 = await calls.ids
        #expect(none.changed.isEmpty && asked0.isEmpty)
        // the YouTube Music recording does, once
        await f.entity("ytSong", .recording, "Ytm Song", uid: "ytmusic:QwErTyUiOp1")
        let r = await fetcher.run(f["ytSong"])
        let asked1 = await calls.ids
        #expect(r.changed == [f["ytSong"]] && asked1 == ["QwErTyUiOp1"])
        let rows1 = await MusicSongReads.creditRows(f.graph, f["ytSong"], predicates: MusicSongReads.creditPredicates)
        let groups = MusicSongCredits.build(rows: rows1)
        #expect(groups.map(\.kind) == [.performers, .composers, .lyricists])
        #expect(groups.flatMap(\.people).allSatisfy { $0.status == .inferred && $0.level == .song })
        // the recording row is not turned provisional or renamed by the draft
        #expect(try await f.graph.entity(f["ytSong"])?.name == "Ytm Song")
        // fresh: the second run does not ask again
        _ = await fetcher.run(f["ytSong"])
        let asked2 = await calls.ids
        #expect(asked2.count == 1)
    }

    @Test func anOutageWritesNothingAndBacksOff() async throws {
        let f = await SongFixture.awaara()
        await f.entity("ytSong", .recording, "Ytm Song", uid: "ytmusic:QwErTyUiOp1")
        let calls = SongCallCounter()
        let fetcher = MusicRecordingCreditsFetcher(store: f.graph, youTubeMusic: { id in await calls.record(id); return [] })
        let r = await fetcher.run(f["ytSong"])
        #expect(r.changed.isEmpty)
        let rows2 = await MusicSongReads.creditRows(f.graph, f["ytSong"], predicates: MusicSongReads.creditPredicates)
        #expect(MusicSongCredits.isEmpty(MusicSongCredits.build(rows: rows2)))
        _ = await fetcher.run(f["ytSong"])
        let asked3 = await calls.ids
        #expect(asked3.count == 1)
        // credits that were already cached stay as they are
        #expect(names(try await credits(f, "awara").first { $0.kind == .singers }) == ["Mukesh"])
    }

    @Test func aProviderThatIsOffAsksNothing() async throws {
        let f = await SongFixture.awaara()
        await f.entity("ytSong", .recording, "Ytm Song", uid: "ytmusic:QwErTyUiOp1")
        let fetcher = MusicRecordingCreditsFetcher(store: f.graph, youTubeMusic: nil)
        let off = await fetcher.run(f["ytSong"])
        #expect(off.changed.isEmpty)
    }

    private func credits(_ f: SongFixture, _ key: String) async throws -> [MusicSongCreditGroup] {
        let r = try await MusicSongPageCreditsLoader(env: MusicSongLoaderEnv()).load(entity: f[key], store: f.graph, report: SongPartials().reporter)
        return r.items.compactMap { $0.base as? MusicSongCreditGroup }
    }
}

actor SongCallCounter {
    private(set) var ids: [String] = []
    func record(_ id: String) { ids.append(id) }
}
