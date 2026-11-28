import Foundation
import Testing
@testable import REDDY

@Suite struct FillBuildersTests {
    @Test func chartScopeIsLabelled() {
        #expect(MusicExploreHub.chartScopeLabel(regionName: "India", isRegional: true) == "Top in India")
        #expect(MusicExploreHub.chartScopeLabel(regionName: "India", isRegional: false) == "Worldwide")
    }

    @Test func homeHasNoBuiltInNamesForAnyCountryOrLanguage() async {
        let g = MusicInMemoryGraph()
        for region in ["IN", "US", "JP", "NG", "DE"] {
            for language in [nil, "hi", "te", "en"] as [String?] {
                let r = await MusicConnectedHome.build(MusicConnectedHomeInput(affinity: .empty, region: region, language: language, preferredLanguages: ["hindi", "te"], seed: 1), store: g)
                #expect(r.shelves.isEmpty, "\(region)/\(language ?? "all"): with no plays and an empty graph nothing is invented")
            }
        }
        #expect(try! await g.counts().entities == 0, "building Home writes no names into the graph")
    }

    @Test func connectedHomePersonalShelvesAreHonestAndSameDayStable() async throws {
        let f = try await FillFixture.make()
        // more composers so a shelf reaches three tiles
        var aff = MusicAffinityVector()
        aff.composer[f.sj] = 4
        for n in ["Naushad", "Madan Mohan", "Khayyam"] {
            let id = try await f.g.upsert(MusicEntityDraft(kind: .person, name: n)).id
            aff.composer[id] = 2
        }
        aff.film[f.film] = 3; aff.film[f.film2] = 2
        aff.savedFilm[f.film] = 3; aff.savedFilm[f.film2] = 2
        let pran = try await f.g.upsert(MusicEntityDraft(kind: .person, name: "Pran")).id
        _ = try await f.g.addEdge(MusicEdge(subject: f.film, predicate: .hasCast, object: pran, role: .actor, order: 2), provenance: FillFixture.src)
        let extraFilm = try await f.g.upsert(MusicEntityDraft(kind: .film, name: "Barsaat", year: 1949)).id
        aff.film[extraFilm] = 1; aff.savedFilm[extraFilm] = 1
        aff.recording[f.song1] = 5
        aff.language["hi"] = 3
        let input = MusicConnectedHomeInput(affinity: aff, region: "IN", language: nil, preferredLanguages: ["hindi"], seed: 77)
        let a = await MusicConnectedHome.build(input, store: f.g)
        let b = await MusicConnectedHome.build(input, store: f.g)
        #expect(a.shelves == b.shelves, "same inputs, same seed, same Home")
        let mine = a.shelves.first { $0.id == "fill.personal.musicDirectors" }
        #expect(mine?.title == "Music directors you play")
        #expect(mine?.scope == .personal)
        #expect(mine?.tiles.first?.title == "Shankar-Jaikishan")
        let films = a.shelves.first { $0.id == "fill.personal.films" }
        #expect(films?.title == "Films with soundtracks you saved")
        let actors = a.shelves.first { $0.id == "fill.personal.actors" }
        #expect(actors?.tiles.first?.title == "Raj Kapoor", "in two of the films whose songs you play")
        // a different seed may reorder what a personal shelf shows (Listen Now varies), but never which shelves exist or what they hold
        var other = input; other.seed = 78
        let c = await MusicConnectedHome.build(other, store: f.g)
        let pa = a.shelves.filter { $0.scope == .personal }, pc = c.shelves.filter { $0.scope == .personal }
        #expect(pa.map(\.id) == pc.map(\.id))
        for (x, y) in zip(pa, pc) { #expect(Set(x.tiles.map(\.title)) == Set(y.tiles.map(\.title)), "\(x.id): same people, any order") }
    }

    @Test func connectedHomeShowsOtherAlbumsBySameComposer() async throws {
        let f = try await FillFixture.make()
        // a second album by Shankar-Jaikishan not containing the played song
        let other1 = try await f.g.upsert(MusicEntityDraft(kind: .album, name: "Chori Chori OST", year: 1956)).id
        let other2 = try await f.g.upsert(MusicEntityDraft(kind: .album, name: "Shree 420 OST", year: 1955)).id
        let other3 = try await f.g.upsert(MusicEntityDraft(kind: .album, name: "Sangam OST", year: 1964)).id
        for a in [other1, other2, other3] { _ = try await f.g.addEdge(MusicEdge(subject: a, predicate: .musicDirectedBy, object: f.sj, role: .musicDirector), provenance: FillFixture.src) }
        var aff = MusicAffinityVector(); aff.recording[f.song1] = 5; aff.composer[f.sj] = 3
        let r = await MusicConnectedHome.build(MusicConnectedHomeInput(affinity: aff, region: "IN", language: nil, preferredLanguages: [], seed: 1), store: f.g)
        let s = r.shelves.first { $0.id == "fill.related.byComposer" }
        #expect(s?.title == "Because you played Awaara Hoon: more albums by Shankar-Jaikishan")
        let titles = Set((s?.tiles ?? []).map(\.title))
        #expect(titles.isSuperset(of: ["Chori Chori OST", "Shree 420 OST", "Sangam OST"]))
        #expect(s?.tiles.contains { $0.entity == f.ost } == false, "not the album the song is on")
    }

    @Test func searchFindsPeopleFilmsAndTheirWorks() async throws {
        let f = try await FillFixture.make()
        let r = await MusicSearchEntities.search("shankar jaikishan", store: f.g)
        #expect(r.best?.entity == f.sj)
        #expect(r.best?.tileKind == .musicDirector)
        #expect(r.works?.links(.film).count == 2)
        #expect(r.availableFilters.contains(.people) && r.availableFilters.contains(.musicDirectors))
        let film = await MusicSearchEntities.search("awaara", store: f.g)
        #expect(film.best?.tileKind == .film || film.best?.tileKind == .song || film.best?.tileKind == .soundtrack)
        #expect(film.rows(.soundtracks).contains { $0.entity == f.ost })
        #expect(film.rows(.films).contains { $0.entity == f.film })
        let none = await MusicSearchEntities.search("a", store: f.g)
        #expect(none.isEmpty)
    }

    @Test func searchFindsRomanisedAndFamousNamesAndNeverVariousArtists() async throws {
        let f = try await FillFixture.make()
        let r = await MusicSearchEntities.search("various", store: f.g)
        #expect(!r.rows(.all).contains { MusicLinkMatrix.isVariousArtists($0.title) })
    }

    @Test func didYouMean() {
        let names = ["Shankar-Jaikishan", "Mukesh"]
        #expect(MusicSearchEntities.didYouMean("shankr jaikishan", names: names) == "Shankar-Jaikishan")
        #expect(MusicSearchEntities.didYouMean("mukseh", names: ["Mukesh", "Mohammed Rafi"]) == "Mukesh")
        #expect(MusicSearchEntities.didYouMean("Mukesh", names: ["Mukesh"]) == nil)
        #expect(MusicSearchEntities.didYouMean("muk", names: ["Mukesh"]) == nil, "a prefix is a match, not a typo")
        #expect(MusicSearchEntities.didYouMean("zzzzzz", names: names) == nil)
        #expect(MusicSearchEntities.distance(Array("ab"), Array("ba")) == 1)
    }

    @Test func trackContextHasDirectorFilmAndCast() async throws {
        let f = try await FillFixture.make()
        let reader = MusicTrackContextReader(store: f.g)
        let c = await reader.context(for: f.song1)
        #expect(c.musicDirector?.name == "Shankar-Jaikishan")
        #expect(c.film?.name == "Awaara")
        #expect(c.cast.map(\.name) == ["Raj Kapoor", "Nargis"])
        #expect(c.singers.map(\.name) == ["Mukesh"])   // Various Artists is not a singer link
        #expect(c.line() == "Shankar-Jaikishan · Awaara (1951) · Raj Kapoor, Nargis")
        let unknown = await reader.context(for: f.lone)
        #expect(unknown.isEmpty)
        #expect(unknown.line(fallbackArtists: "Someone", fallbackAlbum: "Album X") == "Someone · Album X")
    }

    @Test func downloadsGroupByFilmThenAlbumThenSingles() async throws {
        let f = try await FillFixture.make()
        let reader = MusicTrackContextReader(store: f.g)
        let c1 = await reader.context(for: f.song1), c2 = await reader.context(for: f.song2)
        let rows = [
            MusicDownloadRowInfo(uid: "p:1", title: "Awaara Hoon", artistLine: "Mukesh", providerID: "p", albumID: "a1", albumTitle: "Awaara OST", thumbURL: "u1", context: c1),
            MusicDownloadRowInfo(uid: "p:2", title: "Ghar Aaya", artistLine: "Mukesh", providerID: "p", albumID: "a1", albumTitle: "Awaara OST", thumbURL: nil, context: c2),
            MusicDownloadRowInfo(uid: "p:3", title: "Other", artistLine: "Various Artists, X", providerID: "p", albumID: "a9", albumTitle: "Some Album", thumbURL: nil, context: nil),
            MusicDownloadRowInfo(uid: "p:4", title: "Single", artistLine: "Y", providerID: "p", albumID: nil, albumTitle: nil, thumbURL: nil, context: nil)]
        let groups = MusicDownloadGrouping.group(rows)
        #expect(groups.map(\.kind) == [.film, .album, .singles])
        #expect(groups[0].title == "Awaara (1951)"); #expect(groups[0].rows.count == 2); #expect(groups[0].entity == f.film); #expect(groups[0].subtitle == "Shankar-Jaikishan")
        #expect(groups[1].entity == MusicEntityID.provisional(kind: .release, providerUID: "p:a9"))
        #expect(groups[1].subtitle == "", "Various Artists is not shown as the maker")
        #expect(groups[2].entity == nil)
    }

    @Test func radioPlansComeFromEntities() async throws {
        let f = try await FillFixture.make()
        let sj = await MusicRadioEntitySeeds.plan(for: f.sj, store: f.g)
        #expect(sj?.explanation == "Radio from Shankar-Jaikishan: songs they are credited on")
        let seeds = Set(sj?.seedSongs ?? [])
        #expect(seeds.isSuperset(of: [f.song1, f.song2]))
        let actor = await MusicRadioEntitySeeds.plan(for: f.raj, store: f.g)
        #expect(actor?.seedSongs.isEmpty == false, "an actor's radio comes from the songs of their films")
        #expect(actor?.explanation.hasSuffix("songs from their films") == true)
        let va = await MusicRadioEntitySeeds.plan(for: f.various, store: f.g)
        #expect(va == nil || va?.seedSongs.isEmpty == true)
    }

    @Test func completenessPlannerIsBoundedAndOrdered() {
        let ids: [MusicEntityID] = [MusicEntityID(kind: .album, token: "AAAAAAAAAAAAA"), MusicEntityID(kind: .person, token: "BBBBBBBBBBBBB"), MusicEntityID(kind: .film, token: "CCCCCCCCCCCCC"),
                                    MusicEntityID(kind: .genre, token: "DDDDDDDDDDDDD"), MusicEntityID(kind: .person, token: "EEEEEEEEEEEEE")]
        let p = MusicCompletenessPlanner.plan(ids, asked: [ids[4]], sessionCount: 0)
        #expect(p == [ids[1], ids[2], ids[0]])
        #expect(MusicCompletenessPlanner.plan(ids, asked: [], sessionCount: 0, perScreen: 2).count == 2)
        #expect(MusicCompletenessPlanner.plan(ids, asked: [], sessionCount: 160).isEmpty)
    }

    /// The journey: Home -> Awaara (film) -> song -> singer -> album -> film -> actor, following only links; every step is a real page and Back unwinds.
    @Test func journeyHomeToAwaaraToSongToSingerToAlbumToFilmToActor() async throws {
        let f = try await FillFixture.make()
        // Home is built from what the person plays (no built-in names): three composers they play give a "Music directors you play" shelf.
        var aff = MusicAffinityVector()
        aff.composer[f.sj] = 4
        for n in ["Naushad", "Madan Mohan", "Khayyam"] {
            let id = try await f.g.upsert(MusicEntityDraft(kind: .person, name: n)).id
            aff.composer[id] = 2
        }
        let r = await MusicConnectedHome.build(MusicConnectedHomeInput(affinity: aff, region: "IN", language: nil, preferredLanguages: [], seed: 5), store: f.g)
        #expect(r.shelves.contains { $0.id == "fill.personal.musicDirectors" })   // Home has the person's own shelf
        var stack: [MusicEntityID] = []
        func go(_ d: MusicLinkDestination) -> MusicEntityID? {
            guard case .page(let id, _) = d else { Issue.record("dead end \(d)"); return nil }
            if let i = stack.lastIndex(of: id) { stack.removeSubrange((i + 1)...) } else { stack.append(id) }
            return id
        }
        // Home -> the Awaara film via search
        let hit = await MusicSearchEntities.search("awaara", store: f.g)
        let film = try #require(hit.rows(.films).first)
        #expect(go(.page(film.entity, role: nil)) == f.film)
        let filmSet = await MusicLinkMatrix.read(f.film, store: f.g)
        let song = try #require(go(filmSet.destination(.song)))
        let songSet = await MusicLinkMatrix.read(song, store: f.g)
        let singer = try #require(go(songSet.destination(.singer)))
        #expect(singer == f.mukesh)
        let singerSet = await MusicLinkMatrix.read(singer, store: f.g)
        let album = try #require(go(singerSet.destination(.soundtrack)))
        #expect(album == f.ost)
        let albumSet = await MusicLinkMatrix.read(album, store: f.g)
        let backToFilm = try #require(go(albumSet.destination(.film)))
        #expect(backToFilm == f.film)           // A, B, ... A truncates to the first A, like the app's stack
        #expect(stack == [f.film])
        let filmAgain = await MusicLinkMatrix.read(backToFilm, store: f.g)
        let actor = try #require(go(filmAgain.destination(.actor)))
        #expect(actor == f.raj)
        #expect(stack == [f.film, f.raj])
        let actorSet = await MusicLinkMatrix.read(actor, store: f.g)
        #expect(actorSet.has(.film) && actorSet.has(.song))   // the actor page lists films and songs: no dead end at the end
    }
}
