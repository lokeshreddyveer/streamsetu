import Foundation
import Testing
@testable import REDDY

private func english(_ r: MusicSoundtrackReason) -> String { r.text(MusicSoundtrackText.english) }

@Suite("Compilation artist guard") struct CompilationArtistTests {
    @Test func variousArtistsIsALabelNotAPerson() {
        for n in ["Various Artists", "various artists", "  VARIOUS ARTISTS ", "Various", "V.A.", "VA", "Varios Artistas", "Verschiedene Interpreten", "Artistes divers", "विभिन्न कलाकार", "వివిధ కళాకారులు"] {
            #expect(MusicCompilationArtist.isCompilation(n), "\(n)")
        }
    }
    @Test func realNamesAreNotCompilations() {
        for n in ["Vishal Mishra", "Various Cruelties", "VAN HALEN", "Diversion", "Variousa", "", "  ", "Pritam"] { #expect(!MusicCompilationArtist.isCompilation(n), "\(n)") }
    }
    @Test func adaptersNeverMakeAnArtistOfIt() {
        let album = MusicAlbum(id: "49986025", providerID: "jiosaavn", title: "ANIMAL - TELUGU", artists: [MusicArtistRef(id: "x", name: "Various Artists"), MusicArtistRef(id: "y", name: "Pritam")])
        let plan = MusicGraphAdapters.plan(for: album)
        #expect(plan.links.count == 1 && plan.links.first?.draft.name == "Pritam")
        let track = MusicTrack(id: "t", providerID: "jiosaavn", title: "Evarevaro", durationMs: 200_000, artists: [MusicArtistRef(id: "x", name: "Various Artists")])
        #expect(!MusicGraphAdapters.plan(for: track).links.contains { $0.predicate == .performedBy })
    }
}

@Suite("ANIMAL - TELUGU: the album page over recorded data", .serialized) struct AnimalAlbumTests {
    @Test func theFilmLinkCastAndMusicCreditsAreThere() async throws {
        let (g, _) = try await AnimalFixtures.build()
        let r = MusicSoundtrackReader(g.graph)
        let h = try #require(await MusicSoundtrackBuild.header(r, id: g.album))
        #expect(h.title == "ANIMAL - TELUGU" && h.year == 2023)
        #expect(h.film?.id == g.film && h.film?.title == "Animal")
        let cast = await MusicSoundtrackBuild.cast(r, id: g.album).cast.map(\.person.name)
        for n in ["Ranbir Kapoor", "Rashmika Mandanna", "Anil Kapoor", "Bobby Deol"] { #expect(cast.contains(n), "cast has \(n)") }
        #expect(cast.first == "Ranbir Kapoor")
        let credits = await MusicSoundtrackBuild.credits(r, id: g.album)
        let names = credits.groups.flatMap(\.credits).map(\.person.name)
        #expect(names.contains("Vishal Mishra") && names.contains("Pritam Chakraborty") && names.contains("Jaani"))
        let singers = credits.groups.filter { $0.kind == .singer }.flatMap(\.credits).map(\.person.name)
        #expect(singers.contains("Anantha Sriram"))
        #expect(!names.contains("Various Artists"), "a compilation credit is not a contributor")
    }

    @Test func moreByTheActualContributorsNeverVariousArtists() async throws {
        let (g, _) = try await AnimalFixtures.build()
        let r = MusicSoundtrackReader(g.graph)
        let composers = await MusicSoundtrackBuild.moreByComposers(r, id: g.album)
        var reasons: [String] = []
        var titles: [String] = []
        for e in composers {
            switch e {
            case .album(let a): titles.append(a.title); reasons.append(english(a.reason))
            case .song(let s): titles.append(s.title); reasons.append(english(s.reason))
            }
        }
        #expect(titles.contains("Kabir Singh") || titles.contains("Brahmastra"), "albums by the same composers: \(titles)")
        #expect(reasons.allSatisfy { !$0.isEmpty && !$0.contains("Various") })
        let singers = await MusicSoundtrackBuild.moreBySingers(r, id: g.album)
        #expect(singers.allSatisfy { !$0.singers.contains("Various Artists") && !english($0.reason).contains("Various") })
        let related = await MusicSoundtrackBuild.related(r, id: g.album)
        #expect(!related.isEmpty && related.allSatisfy { !english($0.reason).isEmpty && !english($0.reason).contains("Various") })
        #expect(!related.contains { $0.title.contains("Various") })
        let lines = await MusicSoundtrackBuild.singerLines(r, recordings: g.recordings.values.map { $0 })
        #expect(!lines.values.joined().contains("Various Artists"))
    }

    @Test func relatedTeluguAndHindiSoundtracksComeWithReasons() async throws {
        let (g, _) = try await AnimalFixtures.build()
        let related = await MusicSoundtrackBuild.related(MusicSoundtrackReader(g.graph), id: g.album)
        let byTitle = Dictionary(related.map { ($0.title, $0) }, uniquingKeysWith: { a, _ in a })
        // the Hindi release group of the same film, and other films of the same director or composer, each with its own reason
        #expect(byTitle["ANIMAL"] != nil || byTitle["Kabir Singh"] != nil || byTitle["Arjun Reddy"] != nil)
        for (t, a) in byTitle { #expect(!english(a.reason).isEmpty, "\(t) says why") }
    }

    @Test func sameTitleRowsOfDifferentEditionsStaySeparateAndSayWhichOne() async throws {
        let (g, standard) = try await AnimalFixtures.build()
        #expect(standard.count == 6 && g.providerTracks.count == 9)
        let std = MusicSoundtrackSongs.rows(provider: standard, recordings: [], singers: [:])
        #expect(std.count == 6 && std.allSatisfy { $0.edition == nil }, "one of each title: nothing to mark")
        let deluxe = MusicSoundtrackSongs.rows(provider: g.providerTracks, recordings: [], singers: [:])
        #expect(deluxe.count == 9 && Set(deluxe.map(\.id)).count == 9, "no row is merged or dropped")
        #expect(deluxe.compactMap(\.edition).count == 3, "the three versions (Child's, Soul, Extended Film) name themselves")
        #expect(deluxe.first { $0.title == "Evarevaro (Soul Version)" }?.edition == .named("Soul Version"))
        // The same title twice on one album (the repeated Kashmeeru and Yaalo Yaalaa of the owner's 8-song view)
        let repeated = standard + [standard[4], standard[5]].enumerated().map { i, t in
            MusicSoundtrackTrackLite(uid: t.uid + "-b\(i)", title: t.title, durationMs: t.durationMs, artistLine: t.artistLine, disc: 1, number: 7 + i)
        }
        let rows = MusicSoundtrackSongs.rows(provider: repeated, recordings: [], singers: [:])
        #expect(rows.count == 8, "all eight stay")
        let kashmeeru = rows.filter { $0.title == "Kashmeeru" }
        #expect(kashmeeru.count == 2 && kashmeeru.map(\.edition) == [.repeated(1), .repeated(2)])
        #expect(Set(kashmeeru.map(\.id)).count == 2, "two recordings, not one")
        #expect(rows.filter { $0.title == "Ammayi" }.first?.edition == nil)
    }

    @Test func theGraphKeepsTheEditionsAsSeparateRecordings() async throws {
        let (g, _) = try await AnimalFixtures.build()
        let a = try #require(g.recordings["Evarevaro"]), b = try #require(g.recordings["deluxe:Evarevaro"])
        #expect(a != b)
        let on = await MusicSoundtrackReader(g.graph).recordings(await MusicSoundtrackReader(g.graph).family(of: g.album))
        #expect(on.filter { $0.title == "Evarevaro" }.count == 1, "an edition's track is not folded into the standard album's list")
    }
}

extension MusicJourneys {
@MainActor
@Suite("Journeys over ANIMAL - TELUGU") struct AnimalJourneyTests {
    private func names(_ d: MusicPersonViewData?, _ id: MusicPersonSectionID) -> [String] { d?.section(id)?.entries.map(\.name) ?? [] }
    private func data(_ s: [String: MusicEntitySection], _ v: MusicPersonView) -> MusicPersonViewData? {
        s[MusicPersonViewLoader.key(v)]?.items.compactMap { $0.base as? MusicPersonViewData }.first
    }

    @Test func albumToFilmToCastToFilmographyToOtherFilmToItsSoundtrack() async throws {
        let (g, _) = try await AnimalFixtures.build()
        let rig = try JourneyRig(g)
        defer { rig.cleanup() }
        let start = rig.player
        let ranbir = try #require(g.people["Ranbir Kapoor"])
        rig.go(g.album)
        var album = await rig.album(g.album)
        #expect(album[MusicSoundtrackKey.header]?.items.isEmpty == false && album[MusicSoundtrackKey.cast]?.items.isEmpty == false)
        rig.go(g.film)
        let film = await rig.film(g.film)
        #expect(film[MusicFilmSectionKey.cast]?.items.isEmpty == false && film[MusicFilmSectionKey.soundtracks]?.items.isEmpty == false)
        rig.go(ranbir, role: .actor)
        let actor = await rig.person(ranbir, .actor)
        let filmography = names(data(actor, .actor), .filmography)
        #expect(filmography.contains("Animal") && filmography.contains("Brahmastra"), "filmography: \(filmography)")
        let other = try #require(g.films["Brahmastra"])
        rig.go(other)
        let otherFilm = await rig.film(other)
        #expect(otherFilm[MusicFilmSectionKey.soundtracks]?.items.isEmpty == false)
        let soundtrack = try #require(g.albums["Brahmastra"])
        rig.go(soundtrack)
        album = await rig.album(soundtrack)
        #expect(album[MusicSoundtrackKey.header]?.items.isEmpty == false)
        #expect(rig.stackIDs == [g.album, g.film, ranbir, other, soundtrack])
        #expect(rig.player == start)
        rig.back(); rig.back()
        #expect(rig.top == ranbir && rig.hub.nav.top?.entityRoute?.role == .actor)
        #expect(rig.player == start)
    }

    @Test func albumToSongToSingerToOtherAlbums() async throws {
        let (g, _) = try await AnimalFixtures.build()
        let rig = try JourneyRig(g)
        defer { rig.cleanup() }
        let start = rig.player
        let evarevaro = try #require(g.recordings["Evarevaro"]), vishal = try #require(g.people["Vishal Mishra"])
        rig.go(g.album)
        _ = await rig.album(g.album)
        rig.go(evarevaro)
        let song = await rig.song(evarevaro)
        let credits = song["song.credits"]?.items.map { String(describing: $0) }.joined(separator: " ") ?? ""
        #expect(credits.contains("Vishal Mishra"), "the song credits Vishal Mishra")
        #expect(!credits.contains("Various Artists"))
        rig.go(vishal, role: .singer)
        let singer = await rig.person(vishal, .singer)
        let albums = names(data(singer, .singer), .albums) + names(data(singer, .singer), .singles) + names(data(singer, .singer), .filmSongs) + names(data(singer, .singer), .topSongs)
        #expect(!albums.isEmpty, "the singer page lists albums or songs")
        #expect(!albums.contains("Various Artists"))
        #expect(rig.player == start)
        let kabir = try #require(g.albums["Kabir Singh"])
        rig.go(kabir)
        _ = await rig.album(kabir)
        #expect(rig.stackIDs == [g.album, evarevaro, vishal, kabir] && rig.player == start)
    }

    @Test func albumToComposerToOtherFilmSoundtracksThenPlay() async throws {
        let (g, _) = try await AnimalFixtures.build()
        let rig = try JourneyRig(g)
        defer { rig.cleanup() }
        let start = rig.player
        let vishal = try #require(g.people["Vishal Mishra"])
        rig.go(g.album)
        _ = await rig.album(g.album)
        rig.go(vishal, role: .composer)
        let composer = await rig.person(vishal, .composer)
        let d = data(composer, .composer)
        let soundtracks = names(d, .soundtracks) + names(d, .films) + names(d, .albums) + names(d, .popularCompositions)
        #expect(soundtracks.contains("Kabir Singh") || soundtracks.contains("Animal") || soundtracks.contains("ANIMAL - TELUGU"), "composer work: \(soundtracks)")
        let kabir = try #require(g.albums["Kabir Singh"])
        rig.go(kabir)
        _ = await rig.album(kabir)
        #expect(rig.player == start, "nothing played while navigating")
        let track = MusicTrack(id: "kabir-1", providerID: JourneyAudio.id, title: "Kabir Singh (title song)", durationMs: 200_000, artists: [MusicArtistRef(id: "", name: "Vishal Mishra")])
        rig.hub.play([track], at: 0)
        #expect(rig.player != start && rig.hub.player.queue.map(\.id) == ["kabir-1"])
        #expect(rig.top == kabir)
    }
}
}
