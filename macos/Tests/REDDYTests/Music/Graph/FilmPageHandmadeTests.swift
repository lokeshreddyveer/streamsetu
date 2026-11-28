import Foundation
import Testing
@testable import REDDY

/// Awaara-like fixtures built by hand: Raj Kapoor and Nargis in three films, one composer duo, language and era.
struct Cinema {
    let g = G8Graph()
    var awaara = MusicEntityID(kind: .film, token: "0000000000000"), shree420 = MusicEntityID(kind: .film, token: "0000000000000")
    var joker = MusicEntityID(kind: .film, token: "0000000000000"), tamilFilm = MusicEntityID(kind: .film, token: "0000000000000")
    var awaara2010 = MusicEntityID(kind: .film, token: "0000000000000"), indie = MusicEntityID(kind: .film, token: "0000000000000")
    var raj = MusicEntityID(kind: .person, token: "0000000000000"), nargis = MusicEntityID(kind: .person, token: "0000000000000")
    var sj = MusicEntityID(kind: .group, token: "0000000000000"), other = MusicEntityID(kind: .person, token: "0000000000000")

    static func make() async throws -> Cinema {
        var c = Cinema()
        let g = c.g
        c.raj = try await g.person("Raj Kapoor", year: 1924); c.nargis = try await g.person("Nargis", year: 1929); c.other = try await g.person("Someone Else", year: 1980)
        c.sj = try await g.put(.group, "Shankar-Jaikishan", ids: [ExternalID(.wikidata, "Q7488")])
        c.awaara = try await g.film("Awaara", 1951, tmdb: 39039)
        c.shree420 = try await g.film("Shree 420", 1955, tmdb: 40101)
        c.joker = try await g.film("Mera Naam Joker", 1970, tmdb: 40202)
        c.tamilFilm = try await g.film("Tamil Film", 1952, lang: "ta")
        c.awaara2010 = try await g.film("Awaara", 2010, lang: "ta", tmdb: 50010)
        c.indie = try await g.film("Indie Hindi Film", 2012)
        try await g.cast(c.awaara, [c.raj, c.nargis]); try await g.edge(c.awaara, .directedBy, c.raj, role: .director); try await g.edge(c.awaara, .composedBy, c.sj, role: .composer)
        try await g.cast(c.shree420, [c.raj, c.nargis]); try await g.edge(c.shree420, .directedBy, c.raj, role: .director); try await g.edge(c.shree420, .composedBy, c.sj, role: .composer)
        try await g.cast(c.joker, [c.raj]); try await g.edge(c.joker, .directedBy, c.raj, role: .director)
        try await g.cast(c.tamilFilm, [c.nargis])
        try await g.cast(c.awaara2010, [c.other]); try await g.cast(c.indie, [c.other])
        return c
    }
}

@Suite("G8 film page: related films and credits") struct G8RelatedTests {
    @Test func relatedFilmsAreScoredAndExplained() async throws {
        let c = try await Cinema.make()
        let rel = try await g8Run(MusicFilmRelatedLoader(), c.awaara, c.g.store, as: MusicFilmRelatedItem.self)
        #expect(rel.map(\.name) == ["Shree 420", "Mera Naam Joker", "Tamil Film"], "best first: same director, composer and both leads; director and lead; one lead")
        let shree = rel[0]
        #expect(shree.reasons.first == .director("Raj Kapoor") && shree.reasons.contains(.composer("Shankar-Jaikishan")))
        #expect(shree.reasons.contains(.cast(["Raj Kapoor", "Nargis"])) && shree.reasons.contains(.sameLanguage("hi")) && shree.reasons.contains(.sameEra(1950)))
        #expect(rel[1].reasons.contains(.director("Raj Kapoor")) && !rel[1].reasons.contains { if case .composer = $0 { true } else { false } })
        #expect(rel[2].reasons == [.cast(["Nargis"]), .sameEra(1950)], "a different language is not claimed as shared")
        #expect(shree.score > rel[1].score && rel[1].score > rel[2].score)
        #expect(!rel.contains { $0.film == c.awaara }, "never itself")
        #expect(!rel.contains { $0.film == c.indie } && !rel.contains { $0.film == c.awaara2010 }, "language or era alone never makes two films related")
    }

    @Test func aRemakeWithTheSameTitleIsASeparateFilmAndNeverMerged() async throws {
        let c = try await Cinema.make()
        #expect(c.awaara != c.awaara2010)
        let rel = try await g8Run(MusicFilmRelatedLoader(), c.awaara, c.g.store, as: MusicFilmRelatedItem.self)
        #expect(!rel.contains { $0.film == c.awaara2010 })
        let versions = try await g8Run(MusicFilmVersionsLoader(), c.awaara, c.g.store, as: MusicFilmVersionItem.self)
        #expect(versions.isEmpty, "no stated edge, so no 'also known as' or dub line")
        // The scorer itself drops a duplicate of the same name and year, but keeps a same-name film of another year.
        let subject = MusicFilmSubject(film: c.awaara, name: "Awaara", year: 1951, lang: "hi")
        let dup = MusicFilmCandidate(film: c.awaara2010, name: "Awaara", year: 1951, lang: "hi", imageRef: nil, links: [.director(person: c.raj, name: "Raj Kapoor")])
        let other = MusicFilmCandidate(film: c.shree420, name: "Awaara", year: 2010, lang: "hi", imageRef: nil, links: [.director(person: c.raj, name: "Raj Kapoor")])
        #expect(MusicFilmRelatedScorer.rank(subject: subject, candidates: [dup, other]).map(\.film) == [c.shree420])
    }

    @Test func moreFilmsByTheDirectorAreNewestFirstAndExcludeThisFilm() async throws {
        let c = try await Cinema.make()
        let more = try await g8Run(MusicFilmDirectorFilmsLoader(), c.awaara, c.g.store, as: MusicFilmRelatedItem.self)
        #expect(more.map(\.name) == ["Mera Naam Joker", "Shree 420"] && more.allSatisfy { $0.reasons == [.director("Raj Kapoor")] })
    }

    @Test func moreMusicFromTheComposerAndOtherSoundtracksOfTheCastComeFromMatchedAlbumsOnly() async throws {
        let c = try await Cinema.make()
        let g = c.g
        let ost1 = try await g.put(.album, "Shree 420 OST", year: 1955, subkind: "soundtrack"), ost2 = try await g.put(.album, "Joker OST", year: 1970, subkind: "soundtrack")
        let weak = try await g.put(.album, "Maybe Joker", year: 1971, subkind: "soundtrack"), mine = try await g.put(.album, "Awaara OST", year: 1951, subkind: "soundtrack")
        let solo = try await g.put(.album, "Shankar Jaikishan Hits", year: 1960, subkind: "compilation")
        try await g.edge(ost1, .soundtrackOf, c.shree420, prov: G8Graph.matcher); try await g.edge(ost2, .soundtrackOf, c.joker, prov: G8Graph.matcher)
        var low = G8Graph.matcher; low.score = 0.3
        try await g.edge(weak, .soundtrackOf, c.joker, prov: low); try await g.edge(mine, .soundtrackOf, c.awaara, prov: G8Graph.matcher)
        try await g.edge(solo, .composedBy, c.sj, role: .composer)
        let castMusic = try await g8Run(MusicFilmCastMusicLoader(), c.awaara, g.store, as: MusicFilmAlbumItem.self)
        #expect(Set(castMusic.map(\.name)) == ["Shree 420 OST", "Joker OST"], "a weak 0.3 match and this film's own album are left out")
        #expect(castMusic.allSatisfy { $0.via == "Raj Kapoor" || $0.via == "Nargis" } && castMusic.first { $0.name == "Shree 420 OST" }?.filmName == "Shree 420")
        let composer = try await g8Run(MusicFilmComposerMusicLoader(), c.awaara, g.store, as: MusicFilmAlbumItem.self)
        #expect(Set(composer.map(\.name)) == ["Shankar Jaikishan Hits", "Shree 420 OST"] && !composer.contains { $0.name == "Awaara OST" } && composer.allSatisfy { $0.via == "Shankar-Jaikishan" })
        #expect(composer.map(\.year) == [1960, 1955], "newest first")
    }

    @Test func aWeakOrConflictedSoundtrackLinkIsNotShownAndADuplicateEditionIsFolded() async throws {
        let c = try await Cinema.make()
        let g = c.g
        let group = try await g.put(.album, "Joker", year: 1970, subkind: "soundtrack"), release = try await g.put(.release, "Joker (provider)", year: 1970, subkind: "soundtrack")
        let weak = try await g.put(.album, "Weak", year: 1970), stated = try await g.put(.album, "Stated OST", year: 1970, subkind: "soundtrack")
        try await g.edge(group, .soundtrackOf, c.joker, prov: G8Graph.matcher); try await g.edge(release, .soundtrackOf, c.joker, prov: G8Graph.matcher)
        try await g.edge(release, .editionOf, group)
        var low = G8Graph.matcher; low.score = 0.4
        try await g.edge(weak, .soundtrackOf, c.joker, prov: low)
        try await g.edge(stated, .soundtrackOf, c.joker, prov: G8Graph.wd)
        let albums = try await g8Run(MusicFilmSoundtracksLoader(), c.joker, g.store, as: MusicFilmAlbumItem.self)
        #expect(albums.map(\.name) == ["Stated OST", "Joker"], "stated before inferred; the release folds into its album; the guess is out")
        #expect(albums[0].matchEvidence.isEmpty && albums[0].status == .verified && albums[1].matchEvidence == ["title", "composer"])
    }

    @Test func aFilmWithoutASoundtrackShowsNoMusicSectionsAndStillHasCastCrewAndRelatedFilms() async throws {
        let c = try await Cinema.make()
        let center = await g8Center(c.g.store)
        let model = await MainActor.run { MusicFilmGraphModel(center: center, watch: MusicFilmWatchLogic(isInLibrary: { _ in false }, open: { _ in false })) }
        await MainActor.run { model.open(c.joker); model.loadLazy(MusicFilmSectionKey.related) }
        await g8Wait { MusicFilmSectionKey.core.allSatisfy { model.section($0).phase != .loading && model.section($0).phase != .idle } && model.section(MusicFilmSectionKey.related).phase != .loading && model.entity?.isWorking != true }
        let (plan, albums, songs, cast, crew, related, singers) = await MainActor.run {
            (model.musicPlan, model.albums.count, model.songs.count, model.cast.count, model.crew.count, model.related.count, model.singers.count)
        }
        #expect(plan == .noSoundtrack && albums == 0 && songs == 0 && singers == 0, "plan \(plan) albums \(albums) songs \(songs) singers \(singers)")
        #expect(cast == 1 && crew == 1 && related >= 1)
        await MainActor.run { model.close() }
    }

    @Test func aTVSeriesHasCastOSTAlbumsAndSongsOnTheSamePage() async throws {
        let g = G8Graph()
        let series = try await g.put(.series, "Crash Landing", year: 2019, lang: "ko", ids: [ExternalID(.tmdbTV, "94796")], attrs: ["seasons": "1"])
        let lead = try await g.person("Hyun Bin", year: 1982), lead2 = try await g.person("Son Ye-jin", year: 1982)
        try await g.cast(series, [lead, lead2])
        let ost = try await g.put(.album, "Crash Landing On You OST", year: 2020, subkind: "soundtrack")
        try await g.edge(ost, .soundtrackOf, series, prov: G8Graph.matcher)
        let song = try await g.put(.recording, "Give You My Heart", ids: [ExternalID(.provider, "ytmusic:abc123")]), singer = try await g.person("IU", year: 1993)
        try await g.edge(song, .trackOn, ost, attrs: { var a = EdgeAttributes(); a.position = 1; return a }())
        try await g.edge(song, .performedBy, singer, role: .singer)
        let overview = try #require(try await g8Run(MusicFilmOverviewLoader(), series, g.store, as: MusicFilmOverview.self).first)
        #expect(overview.isSeries && overview.seasons == 1 && overview.languages == ["Korean"])
        #expect(try await g8Run(MusicFilmCastLoader(), series, g.store, as: MusicFilmPersonItem.self).count == 2)
        let albums = try await g8Run(MusicFilmSoundtracksLoader(), series, g.store, as: MusicFilmAlbumItem.self)
        #expect(albums.map(\.name) == ["Crash Landing On You OST"])
        let songs = try await g8Run(MusicFilmSongsLoader(), series, g.store, as: MusicFilmSongItem.self)
        #expect(songs.map(\.title) == ["Give You My Heart"] && songs[0].singers.map(\.name) == ["IU"] && songs[0].providerUID == "ytmusic:abc123")
        let ref = MusicFilmWatchRefs.ref(snapshot: try await g.store.entity(series), externalIDs: try await g.store.externalIDs(of: series))
        #expect(ref == MusicFilmWatchRef(tmdbID: 94796, title: "Crash Landing", year: 2019, isSeries: true))
    }

    @Test func duplicateSongsOfAnAlbumFoldToTheOneThatPlays() {
        func s(_ t: String, _ pos: Int, uid: String?) -> MusicFilmSongItem {
            MusicFilmSongItem(recording: MusicEntityID.provisional(kind: .recording, name: t + "\(pos)"), title: t, durationMs: nil, imageRef: nil,
                              album: MusicEntityID.provisional(kind: .album, name: "A"), albumName: "A", dubLanguage: nil, disc: 1, position: pos, singers: [],
                              providerUID: uid, releaseProviderUID: nil, status: .inferred)
        }
        let rows = [s("Awaara Hoon", 3, uid: nil), s("Ek Do Teen", 1, uid: "jiosaavn:t1"), s("AWAARA HOON", 3, uid: "jiosaavn:t3"), s("Naiya", 2, uid: nil)]
        let out = MusicFilmSongRules.arranged(rows, limit: 10)
        #expect(out.map(\.title) == ["Ek Do Teen", "Naiya", "AWAARA HOON"] && out.last?.providerUID == "jiosaavn:t3")
        #expect(MusicFilmSongRules.arranged(rows, limit: 2).count == 2)
        #expect(MusicFilmSongRules.split(providerUID: "jiosaavn:a:b")?.id == "a:b" && MusicFilmSongRules.split(providerUID: "nocolon") == nil)
    }

    @Test func aProvisionalSingerFoldsIntoTheEstablishedOneOfTheSameNameButTwoEstablishedStayTwo() {
        let a = MusicEntityID.provisional(kind: .person, name: "Mukesh", year: 1923), b = MusicEntityID.provisional(kind: .person, name: "Mukesh", year: 1990)
        let p = MusicEntityID.provisional(kind: .person, name: "Mukesh")
        let r = MusicFilmSongRules.collapse([MusicFilmSingerRef(person: p, name: "Mukesh", imageRef: nil, established: false), MusicFilmSingerRef(person: a, name: "Mukesh")])
        #expect(r.map(\.person) == [a])
        #expect(MusicFilmSongRules.collapse([MusicFilmSingerRef(person: a, name: "Mukesh"), MusicFilmSingerRef(person: b, name: "Mukesh")]).count == 2)
        #expect(MusicFilmSongRules.withoutDisambiguator("आवारा (1951 फ़िल्म)") == "आवारा" && MusicFilmSongRules.withoutDisambiguator("Awaara") == "Awaara")
    }

    @Test func aCancelledWalkStopsAndABigCastStaysBounded() async throws {
        let g = G8Graph()
        let big = try await g.film("Crowd", 2000)
        var people: [MusicEntityID] = []
        for i in 0..<120 { people.append(try await g.person("Extra \(i)", year: 1950 + i % 40)) }
        try await g.cast(big, people)
        let cast = try await g8Run(MusicFilmCastLoader(), big, g.store, as: MusicFilmPersonItem.self)
        #expect(cast.count == MusicFilmGraphReading.castCap && cast.first?.order == 0)
        let t = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await MusicFilmCastLoader().load(entity: big, store: g.store, report: MusicSectionReporter { _ in }); return false } catch is CancellationError { return true } catch { return false }
        }
        #expect(await t.value, "a cancelled load throws CancellationError and writes nothing")
    }
}
