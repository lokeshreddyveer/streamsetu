import Foundation
import Testing
@testable import REDDY

private func english(_ r: MusicSoundtrackReason) -> String { r.text(MusicSoundtrackText.english) }

/// Sections A to K of the Awaara (1951) soundtrack page, built from the fixture graph (MusicBrainz tracklist and credits, Wikidata Q858681 cast and crew).
@Suite struct SoundtrackSectionTests {
    // MARK: A header

    @Test func headerStatesTheFilmYearLanguageAndMakers() async throws {
        let g = try await SoundtrackFixtureGraph.build()
        let h = try #require(await MusicSoundtrackBuild.header(MusicSoundtrackReader(g.graph), id: g.album))
        #expect(h.title == "Awaara")
        #expect(h.year == 1951)
        #expect(h.languageName == "Hindi")
        #expect(h.isSoundtrackType)
        #expect(h.subkind == "soundtrack")
        let film = try #require(h.film)
        #expect(film.id == g.film)
        #expect(film.title == "Awaara" && film.year == 1951)
        #expect(film.linkStatus == .verified && !film.isInferredLink)
        #expect(h.makers.first?.person.name == "Shankar-Jaikishan")
        #expect(h.makers.first?.role == .musicDirector)
        #expect(h.eraName == "1950s" && h.languageID == g.hindi)
    }

    @Test func providerEditionOpensWithTheSameFilmThroughItsAlbum() async throws {
        let g = try await SoundtrackFixtureGraph.build()
        let h = try #require(await MusicSoundtrackBuild.header(MusicSoundtrackReader(g.graph), id: g.release))
        #expect(h.film?.id == g.film)          // the release is an edition of the album, which carries the verified link
        #expect(h.makers.first?.person.name == "Shankar-Jaikishan")
    }

    // MARK: B songs

    @Test func songRowsFollowTheProviderTracklistAndTieToRecordings() async throws {
        let g = try await SoundtrackFixtureGraph.build()
        #expect(g.providerTracks.count == 3)   // the recorded JioSaavn reply lists three songs
        let rows = MusicSoundtrackSongs.rows(provider: g.providerTracks, recordings: [], singers: [:])
        #expect(rows.count == 3)
        #expect(rows.map(\.number) == [1, 2, 3])
        #expect(rows.allSatisfy { $0.isPlayable && $0.id.kind == .recording })
        #expect(rows.first?.id == MusicEntityID.provisional(kind: .recording, providerUID: g.providerTracks[0].uid))
        // the graph refines the singer line in place
        let refined = MusicSoundtrackSongs.rows(provider: g.providerTracks, recordings: [], singers: [rows[0].id: ["Shamshad Begum"]])
        #expect(refined[0].singerLine == "Shamshad Begum")
    }

    @Test func graphRecordingsAreTheFallbackListAndAreNotPlayable() async throws {
        let g = try await SoundtrackFixtureGraph.build()
        let r = MusicSoundtrackReader(g.graph)
        let recs = await r.recordings(await r.family(of: g.album))
        #expect(recs.count == 10)
        #expect(recs.map(\.title).first == "Ek Do Teen")
        #expect(recs.map(\.position) == Array(1...10).map { Optional($0) })
        let rows = MusicSoundtrackSongs.rows(provider: [], recordings: recs, singers: [:])
        #expect(rows.count == 10 && rows.allSatisfy { !$0.isPlayable })
        let singers = await MusicSoundtrackBuild.singerLines(r, recordings: recs.map(\.id))
        #expect(singers[g.recordings["Awaara Hoon"]!] == ["Mukesh"])
        #expect(Set(singers[g.recordings["Tere Bina Aag Yeh Chandni"]!] ?? []) == ["Manna Dey", "Lata Mangeshkar"])
    }

    @Test func providerAlbumReferenceComesFromTheProviderExternalId() async throws {
        let g = try await SoundtrackFixtureGraph.build()
        let r = MusicSoundtrackReader(g.graph)
        let fromRelease = await MusicSoundtrackSongs.providerAlbum(r, family: await r.family(of: g.release))
        #expect(fromRelease?.provider == "jiosaavn" && fromRelease?.id == "1064999")
        // the album concept finds its provider edition
        let fromAlbum = await MusicSoundtrackSongs.providerAlbum(r, family: await r.family(of: g.album))
        #expect(fromAlbum?.id == "1064999")
        #expect(MusicSoundtrackSongs.parse(uid: "ytmusic:MPREb:xyz")?.id == "MPREb:xyz")
        #expect(MusicSoundtrackSongs.parse(uid: "nocolon") == nil)
    }

    // MARK: C credits

    @Test func creditsGroupSingersComposersAndLyricistsWithRoles() async throws {
        let g = try await SoundtrackFixtureGraph.build()
        let c = await MusicSoundtrackBuild.credits(MusicSoundtrackReader(g.graph), id: g.album)
        #expect(c.film?.id == g.film)
        #expect(c.people(.musicDirector).map(\.person.name) == ["Shankar-Jaikishan"])
        #expect(c.people(.musicDirector).first?.isFilmCredit == false)
        // the film-level composer credit of the same person is not repeated
        #expect(c.people(.composer).isEmpty)
        #expect(c.people(.lyricist).map(\.person.name) == ["Shailendra"])
        #expect(c.people(.lyricist).first?.songCount == 1)
        let singers = c.people(.singer)
        #expect(singers.first?.person.name == "Lata Mangeshkar" && singers.first?.songCount == 6)
        #expect(singers.dropFirst().first?.person.name == "Mukesh" && singers.dropFirst().first?.songCount == 3)
        #expect(Set(singers.map(\.person.name)).isSuperset(of: ["Shamshad Begum", "Manna Dey", "Mohammed Rafi"]))
        #expect(singers.allSatisfy { $0.role == .singer })
        // director and producer are other contributors, and carry the film-credit level
        let other = c.people(.other)
        #expect(other.contains { $0.role == .director && $0.isFilmCredit })
        #expect(other.contains { $0.role == .producer && $0.isFilmCredit })
        #expect(MusicSoundtrackCreditKind.singer.routeRole == .singer && MusicSoundtrackCreditKind.musicDirector.routeRole == .musicDirector)
    }

    @Test func twoPeopleNamedRajKapoorStayTwoCreditsWithDisambiguators() async throws {
        let g = try await SoundtrackFixtureGraph.build()
        #expect(g.secondRajKapoor != g.people["Raj Kapoor"])
        let c = await MusicSoundtrackBuild.credits(MusicSoundtrackReader(g.graph), id: g.album)
        let all = c.groups.flatMap(\.credits).filter { $0.person.name == "Raj Kapoor" }
        #expect(Set(all.map(\.person.id)) == [g.secondRajKapoor, g.people["Raj Kapoor"]!])
        let byID = Dictionary(all.map { ($0.person.id, $0.person.detail) }, uniquingKeysWith: { a, _ in a })
        #expect(byID[g.secondRajKapoor] == "playback singer")
        #expect(byID[g.people["Raj Kapoor"]!] == "1924")
        // a unique name gets no disambiguator
        #expect(c.groups.flatMap(\.credits).first { $0.person.name == "Mukesh" }?.person.detail == nil)
    }

    // MARK: D cast

    @Test func castIsVerifiedBilledAndCarriesCharactersAndAttribution() async throws {
        let g = try await SoundtrackFixtureGraph.build()
        let c = await MusicSoundtrackBuild.cast(MusicSoundtrackReader(g.graph), id: g.album)
        #expect(c.film?.id == g.film)
        #expect(c.cast.map(\.person.name) == ["Raj Kapoor", "Nargis", "Prithviraj Kapoor", "Leela Chitnis", "Shashi Kapoor", "K. N. Singh", "Cuckoo Moray", "Brij Mohan Vyas", "Leela Mishra"])
        #expect(c.cast.map(\.billing) == Array(0..<9))
        #expect(c.cast[0].character == "Raj" && c.cast[1].character == "Rita" && c.cast[3].character == nil)
        #expect(c.cast.allSatisfy { $0.status == .verified })
        let line = try #require(MusicSoundtrackAttribution.line(sources: c.sources))
        #expect(line.contains("TMDB"))
    }

    // MARK: E more films featuring the cast

    @Test func moreFilmsAreRelevanceOrderedAndNeverIncludeTheFilmOrTheOtherAwaara() async throws {
        let g = try await SoundtrackFixtureGraph.build()
        let r = MusicSoundtrackReader(g.graph)
        let out = await MusicSoundtrackBuild.moreFilms(r, id: g.album)
        #expect(out.film?.id == g.film)
        let titles = out.items.map(\.film.title)
        #expect(titles.first == "Barsaat")                       // two shared actors, nearer in time than Shree 420
        #expect(Array(titles.prefix(2)) == ["Barsaat", "Shree 420"])
        #expect(Set(titles) == ["Barsaat", "Shree 420", "Jagte Raho", "Mother India", "Mughal-e-Azam"])
        #expect(!titles.contains("Awaara") && !titles.contains("Awaara (2010)"))
        let barsaat = try #require(out.items.first)
        #expect(barsaat.actors.map(\.name) == ["Raj Kapoor", "Nargis"])
        #expect(english(barsaat.reason) == "With Raj Kapoor and Nargis")
        // selected-actor filter
        let nargisOnly = MusicSoundtrackFilmFilter.apply(out.items, actor: g.people["Nargis"])
        #expect(Set(nargisOnly.map(\.film.title)) == ["Barsaat", "Shree 420", "Mother India"])
        #expect(MusicSoundtrackFilmFilter.apply(out.items, actor: nil).count == out.items.count)
    }

    // MARK: F soundtracks from those films

    @Test func soundtracksOfCastShowOnlyFilmsThatHaveAMatchedSoundtrack() async throws {
        let g = try await SoundtrackFixtureGraph.build()
        let r = MusicSoundtrackReader(g.graph)
        let films = await MusicSoundtrackBuild.moreFilms(r, id: g.album).items
        let albums = await MusicSoundtrackBuild.soundtracksOfCast(r, films: films)
        #expect(Set(albums.map(\.title)) == ["Barsaat", "Shree 420", "Mother India", "Mughal-e-Azam"])
        #expect(!albums.map(\.title).contains("Jagte Raho"))          // a film with no soundtrack release is never shown as an album
        #expect(albums.allSatisfy { $0.film != nil && $0.id.kind == .album })
        let shree = try #require(albums.first { $0.title == "Shree 420" })
        #expect(english(shree.reason) == "Soundtrack of Shree 420, with Raj Kapoor and Nargis")
        #expect(shree.film?.isInferredLink == false)
    }

    @Test func aProviderAlbumIsAcceptedOnlyForAStrictMatchAndWrittenBackAsInferred() async throws {
        let g = try await SoundtrackFixtureGraph.build()
        let r = MusicSoundtrackReader(g.graph)
        let films = await MusicSoundtrackBuild.moreFilms(r, id: g.album).items
        let jagteID = MusicEntityID.provisional(kind: .release, providerUID: "jiosaavn:jagte")
        let wrongID = MusicEntityID.provisional(kind: .release, providerUID: "jiosaavn:wrong")
        let persisted = SoundtrackBox<[String]>([])
        var hooks = MusicSoundtrackHooks()
        hooks.providerAlbums = { film in
            guard film.title == "Jagte Raho" else { return [] }
            return [MusicSoundtrackProviderAlbum(id: wrongID, title: "Jagte Raho (2003)", year: 2003, imageRef: nil, artistLine: "Various"),
                    MusicSoundtrackProviderAlbum(id: jagteID, title: "Jagte Raho (Original Motion Picture Soundtrack)", year: 1956, imageRef: nil, artistLine: "Salil Chowdhury")]
        }
        hooks.persistInferred = { album, _ in persisted.mutate { $0.append(album.id.rawValue) }; return album.id }
        let albums = await MusicSoundtrackBuild.soundtracksOfCast(r, films: films, hooks: hooks, useProvider: true)
        let jagte = try #require(albums.first { $0.film?.title == "Jagte Raho" })
        #expect(jagte.id == jagteID)
        #expect(jagte.isInferredFilmLink && jagte.film?.linkStatus == .inferred)
        #expect(persisted.value == [jagteID.rawValue])
        #expect(!albums.contains { $0.id == wrongID })
        // without provider permission the film stays out
        let without = await MusicSoundtrackBuild.soundtracksOfCast(r, films: films, hooks: hooks, useProvider: false)
        #expect(!without.contains { $0.film?.title == "Jagte Raho" })
    }

    // MARK: G and H

    @Test func moreByComposersListsOtherSoundtracksAndCompositionsOfShankarJaikishan() async throws {
        let g = try await SoundtrackFixtureGraph.build()
        let entries = await MusicSoundtrackBuild.moreByComposers(MusicSoundtrackReader(g.graph), id: g.album)
        let albums = entries.compactMap { e -> MusicSoundtrackAlbum? in if case .album(let a) = e { a } else { nil } }
        let songs = entries.compactMap { e -> MusicSoundtrackSong? in if case .song(let s) = e { s } else { nil } }
        #expect(Set(albums.map(\.title)) == ["Shree 420", "Barsaat", "Sangam"])
        #expect(!albums.contains { $0.id == g.album || $0.id == g.release })
        #expect(albums.allSatisfy { english($0.reason) == "Same music director: Shankar-Jaikishan" })
        #expect(Set(songs.map(\.title)) == ["Mera Joota Hai Japani", "Pyar Hua Ikrar Hua"])
        #expect(songs.first { $0.title == "Mera Joota Hai Japani" }?.singers == ["Mukesh"])
        #expect(songs.first { $0.title == "Mera Joota Hai Japani" }?.albumTitle == "Shree 420")
        #expect(!songs.contains { $0.title == "Awaara Hoon" })
    }

    @Test func moreBySingersExcludesThisAlbumVersionsAndRanksSharedSingers() async throws {
        let g = try await SoundtrackFixtureGraph.build()
        let songs = await MusicSoundtrackBuild.moreBySingers(MusicSoundtrackReader(g.graph), id: g.album)
        let titles = songs.map(\.title)
        #expect(!titles.contains("Awaara Hoon") && !titles.contains("Awaara Hoon (Karaoke)"))
        #expect(titles.first == "Pyar Hua Ikrar Hua")             // two of this page's singers
        #expect(Set(titles).isSuperset(of: ["Mera Joota Hai Japani", "Kabhi Kabhie Mere Dil Mein"]))
        #expect(english(songs[0].reason).hasPrefix("Sung by "))
    }

    // MARK: I related soundtracks

    @Test func relatedSoundtracksCarryTheirReasonAndNeverTheOtherAwaara() async throws {
        let g = try await SoundtrackFixtureGraph.build()
        let related = await MusicSoundtrackBuild.related(MusicSoundtrackReader(g.graph), id: g.album)
        let by = Dictionary(related.map { ($0.title, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(by["Awaara (2010)"] == nil)                       // same title, other film: never linked
        #expect(!related.contains { $0.id == g.album || $0.id == g.release })
        let shree = try #require(by["Shree 420"])
        #expect(shree.band == 2)
        #expect(english(shree.reason) == "Same music by Shankar-Jaikishan, sung by Lata Mangeshkar" || english(shree.reason) == "Same music by Shankar-Jaikishan, sung by Mukesh")
        let mother = try #require(by["Mother India"])
        #expect(mother.band == 3 && english(mother.reason) == "Shares cast: Nargis")
        #expect(by["Mughal-e-Azam"].map { english($0.reason) } == "Shares cast: Prithviraj Kapoor")
        // stronger signals come first
        #expect(related.map(\.band) == related.map(\.band).sorted())
        #expect(related.allSatisfy { !english($0.reason).isEmpty })
    }

    // MARK: J classic cinema

    @Test func classicCinemaIsSameLanguageWithinTenYearsAndExplainsWhy() async throws {
        let g = try await SoundtrackFixtureGraph.build()
        let classic = await MusicSoundtrackBuild.classic(MusicSoundtrackReader(g.graph), id: g.album)
        let titles = classic.map(\.title)
        #expect(Set(titles) == ["Barsaat", "Shree 420", "Mother India", "Mughal-e-Azam"])
        #expect(!titles.contains("Sholay") && !titles.contains("Sangam"))     // 1975 and 1964 are outside 1941 to 1961
        #expect(!titles.contains("Devadasu") && !titles.contains("Awaara (2010)"))   // Telugu
        #expect(titles.first == "Barsaat" || titles.first == "Shree 420")
        #expect(english(classic[0].reason) == "Hindi film music, 1941 to 1961")
    }

    // MARK: K continue exploring

    @Test func continueExploringLinksCreditsFilmLanguageEraAndRadio() async throws {
        let g = try await SoundtrackFixtureGraph.build()
        let r = MusicSoundtrackReader(g.graph)
        let header = try #require(await MusicSoundtrackBuild.header(r, id: g.album))
        let credits = await MusicSoundtrackBuild.credits(r, id: g.album)
        let cast = await MusicSoundtrackBuild.cast(r, id: g.album)
        let links = MusicSoundtrackBuild.explore(header: header, credits: credits, cast: cast)
        let targets = links.map(\.target)
        #expect(targets.contains(.person(g.people["Shankar-Jaikishan"]!, .musicDirector)))
        #expect(targets.contains(.person(g.people["Lata Mangeshkar"]!, .singer)))
        #expect(targets.contains(.person(g.people["Shailendra"]!, .lyricist)))
        #expect(targets.contains(.film(g.film)))
        #expect(targets.contains(.person(g.people["Raj Kapoor"]!, .actor)))
        #expect(targets.contains(.language(g.hindi)) && targets.contains(.era(g.era)) && targets.contains(.radio))
        #expect(links.first { $0.target == .film(g.film) }.map { english($0.reason) } == "The film of this soundtrack")
    }

    // MARK: cross-section de-duplication

    @Test func laterShelvesDropWhatEarlierOnesShowedAndNeverShowTheOpenedAlbum() async throws {
        let g = try await SoundtrackFixtureGraph.build()
        let r = MusicSoundtrackReader(g.graph)
        let films = await MusicSoundtrackBuild.moreFilms(r, id: g.album).items
        let f = await MusicSoundtrackBuild.soundtracksOfCast(r, films: films)
        let gEntries = await MusicSoundtrackBuild.moreByComposers(r, id: g.album)
        let gAlbums = gEntries.compactMap { e -> MusicSoundtrackAlbum? in if case .album(let a) = e { a } else { nil } }
        let i = await MusicSoundtrackBuild.related(r, id: g.album)
        let j = await MusicSoundtrackBuild.classic(r, id: g.album)
        let seed = MusicSoundtrackCluster.key(id: g.album, title: "Awaara", year: 1951, film: g.film)
        let out = MusicSoundtrackDedupe.apply([f, gAlbums, i, j], excluding: [seed])
        let all = out.flatMap { $0 }.map(\.cluster)
        #expect(Set(all).count == all.count)
        #expect(!all.contains(seed))
        #expect(out[0].count == f.count)       // the first shelf keeps everything
    }
}

/// A tiny lock for values a `@Sendable` hook writes.
final class SoundtrackBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ v: Value) { stored = v }
    var value: Value { lock.withLock { stored } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}
