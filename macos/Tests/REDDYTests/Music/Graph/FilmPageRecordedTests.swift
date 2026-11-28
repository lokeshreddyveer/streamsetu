import Foundation
import Testing
@testable import REDDY

@Suite("G8 film page: recorded films") struct G8RecordedFilmTests {
    private func awaara1951() async throws -> (ResolverRig, MusicEntityID) {
        let rig = ResolverRig()
        let r = await rig.resolver.enrichAlbum(ResolverRig.album1951, tracks: ResolverRig.tracks1951, hints: MusicAlbumHints(language: "hi", musicBy: ["Shankar Jaikishan"]))
        let film = try #require(r.linkedFilm)
        _ = await rig.resolver.enrichFilm(film)
        return (rig, film)
    }

    @Test func awaara1951HasCastDirectorComposerAndAnInferredSoundtrack() async throws {
        let (rig, film) = try await awaara1951()
        let cast = try await g8Run(MusicFilmCastLoader(), film, rig.store, as: MusicFilmPersonItem.self)
        #expect(cast.count == 9 && cast.first?.name == "Raj Kapoor" && cast.map(\.order) == (0..<9).map { Optional($0) })
        #expect(cast.allSatisfy { $0.role == .actor && $0.creditLevel == .film })
        let crew = try await g8Run(MusicFilmCrewLoader(), film, rig.store, as: MusicFilmCrewItem.self)
        #expect(crew.map(\.role) == [.director, .producer, .composer])
        #expect(crew[0].people.map(\.name) == ["Raj Kapoor"] && crew[2].people.first?.isGroup == true)
        let rajAsCast = try #require(cast.first), rajAsDirector = crew[0].people[0]
        #expect(rajAsCast.person == rajAsDirector.person, "one person with three roles on the film")

        let overview = try #require(try await g8Run(MusicFilmOverviewLoader(), film, rig.store, as: MusicFilmOverview.self).first)
        #expect(overview.title == "Awaara" && overview.year == 1951 && overview.languages == ["Hindi"] && overview.synopsis == nil)

        let albums = try await g8Run(MusicFilmSoundtracksLoader(), film, rig.store, as: MusicFilmAlbumItem.self)
        #expect(albums.count == 1 && albums[0].dubLanguage == nil)
        #expect(albums[0].status == .inferred && albums[0].confidence >= 0.85)
        #expect(albums[0].matchEvidence.contains("composer") && albums[0].matchEvidence.contains("title"), "the page can say how the match was made")
    }

    @Test func awaaraSongsAreAllRecordingsOnTheSoundtrackWithSingersAndPlayableCopies() async throws {
        let (rig, film) = try await awaara1951()
        let songs = try await g8Run(MusicFilmSongsLoader(), film, rig.store, as: MusicFilmSongItem.self)
        #expect(songs.count == 10)
        #expect(songs.map(\.title).prefix(3) == ["Ek Do Teen", "Hum Tujhse Mohabbat Kar Ke", "Awaara Hoon"])
        #expect(songs.map { $0.position } == (1...10).map { Optional($0) }, "album order")
        // The three saved provider tracks play at once; the MusicBrainz-only ones wait for a catalogue match.
        #expect(songs.filter(\.playsDirectly).map(\.providerUID) == ["jiosaavn:t1", "jiosaavn:t2", "jiosaavn:t3"])
        let direct = songs.compactMap(MusicFilmSongRules.playableTrack)
        #expect(direct.map(\.uid) == ["jiosaavn:t1", "jiosaavn:t2", "jiosaavn:t3"] && direct[0].title == "Ek Do Teen" && direct[0].durationMs == 168_000)
        // One credit per performer: the provider's "Mukesh" and MusicBrainz's "Mukesh" are one line on a song.
        for s in songs { #expect(Set(s.singers.map { MusicGraphText.latin($0.name) }).count == s.singers.count, "\(s.title): \(s.singers.map(\.name))") }
        let mukesh = songs.first { $0.title == "Awaara Hoon" }!.singers
        #expect(mukesh.map(\.name) == ["Mukesh"])
        let singers = MusicFilmPageBuilders.singers(from: songs)
        #expect(singers.first?.name == "Lata Mangeshkar" && singers.first?.songCount == 6)
        #expect(singers.map(\.name).filter { $0 == "Mukesh" }.count == 1 && singers.first { $0.name == "Mukesh" }?.songCount == 3)
        // Never invented: a song with no playable copy is not turned into a track without a match.
        let unmatched = songs.filter { !$0.playsDirectly }
        #expect(MusicFilmSongRules.queue(songs: unmatched, matched: [:]).isEmpty)
        let row = MusicFilmSongRules.catalogueRow(for: unmatched[0])
        #expect(row.providerID == "graph" && row.title == unmatched[0].title && row.artists.map(\.name) == unmatched[0].singers.map(\.name))
        let twin = MusicTrack(id: "x1", providerID: "ytmusic", title: unmatched[0].title, durationMs: 1, artists: [])
        #expect(MusicFilmSongRules.queue(songs: Array(songs.prefix(4)), matched: [songs[3].recording: twin]).map(\.uid) == ["jiosaavn:t1", "jiosaavn:t2", "jiosaavn:t3", "ytmusic:x1"])
    }

    @Test func awaara2010IsAPaiyaaDubAndIsNeverMixedWithTheFilmOf1951() async throws {
        let (rig, f1951) = try await awaara1951()
        let r = await rig.resolver.enrichAlbum(ResolverRig.album2010, tracks: [ResolverRig.track(1, "Thuli Thuli", ms: 250_000, artist: "Yuvan Shankar Raja")],
                                                hints: MusicAlbumHints(language: "te", musicBy: ["Yuvan Shankar Raja"]))
        let paiyaa = try #require(r.linkedFilm)
        #expect(paiyaa != f1951)
        _ = await rig.resolver.enrichFilm(paiyaa)

        let albums = try await g8Run(MusicFilmSoundtracksLoader(), paiyaa, rig.store, as: MusicFilmAlbumItem.self)
        let dub = try #require(albums.first { $0.dubLanguage != nil })
        #expect(dub.dubLanguage == "te" && dub.name.contains("Awa"))
        let versions = try await g8Run(MusicFilmVersionsLoader(), paiyaa, rig.store, as: MusicFilmVersionItem.self)
        let dubbed = try #require(versions.first { $0.kind == .dubbedAlbum })
        #expect(dubbed.album == dub.album && dubbed.language == "Telugu")
        // The 1951 film page knows nothing of it: no 2010 album, no dub version, no Paiyaa cast.
        let albums1951 = try await g8Run(MusicFilmSoundtracksLoader(), f1951, rig.store, as: MusicFilmAlbumItem.self)
        #expect(!albums1951.contains { $0.album == dub.album })
        let versions1951 = try await g8Run(MusicFilmVersionsLoader(), f1951, rig.store, as: MusicFilmVersionItem.self)
        #expect(versions1951.allSatisfy { $0.kind == .alias } && !versions1951.contains { $0.album == dub.album })
        let songs1951 = try await g8Run(MusicFilmSongsLoader(), f1951, rig.store, as: MusicFilmSongItem.self)
        #expect(!songs1951.contains { $0.album == dub.album })
        let cast1951 = Set(try await g8Run(MusicFilmCastLoader(), f1951, rig.store, as: MusicFilmPersonItem.self).map(\.person))
        let castPaiyaa = Set(try await g8Run(MusicFilmCastLoader(), paiyaa, rig.store, as: MusicFilmPersonItem.self).map(\.person))
        #expect(cast1951.isDisjoint(with: castPaiyaa))
        // Songs of the film: the dubbed edition's songs are the dub album's, flagged, after the originals.
        let songs = try await g8Run(MusicFilmSongsLoader(), paiyaa, rig.store, as: MusicFilmSongItem.self)
        #expect(songs.allSatisfy { $0.album != albums1951.first?.album })
        let rel = try await g8Run(MusicFilmRelatedLoader(), f1951, rig.store, as: MusicFilmRelatedItem.self)
        #expect(!rel.contains { $0.film == paiyaa })
    }

    @Test func vikram2022HasItsWholeCastInBillingOrder() async throws {
        let rig = ResolverRig(tmdb: nil)
        let sug = MusicIMDbParser.search(MetadataFixtures.data("imdb_suggestion_vikram.json"))
        _ = try await rig.resolver.ingest({ var b = sug; b.isSearch = false; return b }())
        let film = try #require(try await rig.store.resolveAlias(for: ExternalID(.imdbTitle, "tt9179430")))
        _ = await rig.resolver.enrichFilm(film)
        let cast = try await g8Run(MusicFilmCastLoader(), film, rig.store, as: MusicFilmPersonItem.self)
        #expect(cast.count == 29, "got \(cast.count)")
        #expect(cast.contains { $0.name == "Kamal Haasan" } && cast.contains { $0.name == "Vijay Sethupathi" } && cast.contains { $0.name == "Fahadh Faasil" })
        let orders = cast.compactMap(\.order)
        #expect(orders == orders.sorted() && Set(cast.map(\.person)).count == cast.count)
        let crew = try await g8Run(MusicFilmCrewLoader(), film, rig.store, as: MusicFilmCrewItem.self)
        #expect(crew.contains { $0.role == .director })
        // A film with no soundtrack in the graph: both music sections are empty, no error.
        #expect(try await g8Run(MusicFilmSoundtracksLoader(), film, rig.store, as: MusicFilmAlbumItem.self).isEmpty)
        #expect(try await g8Run(MusicFilmSongsLoader(), film, rig.store, as: MusicFilmSongItem.self).isEmpty)
    }

    @Test func anOutageKeepsServingTheCachedFilmAndTheSectionsStayLoaded() async throws {
        let (rig, film) = try await awaara1951()
        rig.clock.advance(120 * 86_400)
        rig.transport.failAll = .network("HTTP 503")
        let again = await rig.resolver.enrichFilm(film)
        #expect(again.stale && !again.failed.isEmpty)
        let center = await g8Center(rig.store)
        let model = await MainActor.run { MusicFilmGraphModel(center: center, watch: MusicFilmWatchLogic(isInLibrary: { _ in false }, open: { _ in false })) }
        await MainActor.run { model.open(film) }
        await g8Wait { model.section(MusicFilmSectionKey.cast).phase == .loaded && model.section(MusicFilmSectionKey.songs).phase == .loaded }
        let (cast, albums, songs, plan, failed) = await MainActor.run {
            (model.cast.count, model.albums.count, model.songs.count, model.musicPlan,
             MusicFilmSectionKey.core.contains { model.section($0).phase == .failed })
        }
        #expect(cast == 9 && albums == 1 && songs == 10 && plan == .showSections && !failed, "no error state for enrichment-only data")
        await MainActor.run { model.close() }
    }
}
