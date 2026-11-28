import Foundation
import Testing
@testable import REDDY

@Suite("Film page gaps") struct FilmPageGapsTests {
    private func reply(_ json: String) -> Data { Data(json.utf8) }

    private func song(_ title: String, album: String = "A", dub: String? = nil, durationMs: Int? = nil, singers: [MusicFilmSingerRef] = []) -> MusicFilmSongItem {
        MusicFilmSongItem(recording: MusicEntityID(kind: .recording, token: "R" + title), title: title, durationMs: durationMs, imageRef: nil,
                          album: MusicEntityID(kind: .album, token: "A" + album), albumName: album, dubLanguage: dub, disc: nil, position: nil, singers: singers,
                          providerUID: nil, releaseProviderUID: nil, status: .verified)
    }

    private func person(_ name: String, _ token: String, role: MusicRole = .producer, job: String? = nil) -> MusicFilmPersonItem {
        MusicFilmPersonItem(person: MusicEntityID(kind: .person, token: token), name: name, imageRef: nil, role: role, character: nil, order: nil, status: .verified,
                            creditLevel: .film, nameOnly: false, attribution: nil, birthYear: nil, job: job)
    }

    // MARK: TMDB About facts

    @Test func theAboutFactsComeFromTheSameReplyAndZeroMeansUnknown() {
        let d = reply("""
        {"id":1,"title":"T","budget":0,"revenue":25000000,"status":"Released",
         "production_companies":[{"name":"Studio One"},{"name":"Studio Two"},{"name":"Bad|Name"}],
         "production_countries":[{"iso_3166_1":"GB","name":"United Kingdom"},{"iso_3166_1":"FR","name":"France"}],
         "spoken_languages":[{"iso_639_1":"hi","english_name":"Hindi"},{"iso_639_1":"en","english_name":"English"}]}
        """)
        let f = TMDBGraphSource.facts(d)
        #expect(f["budget"] == nil, "a budget of 0 is TMDB's 'unknown' and is not stored")
        #expect(f["revenue"] == "25000000" && f["status"] == "Released")
        #expect(MusicFilmAboutFacts.list(f["companies"]) == ["Studio One", "Studio Two"])
        #expect(MusicFilmAboutFacts.list(f["countryNames"]) == ["United Kingdom", "France"])
        #expect(MusicFilmAboutFacts.list(f["spokenLanguages"]) == ["Hindi", "English"])
        #expect(MusicFilmAboutFacts.money("0") == nil && MusicFilmAboutFacts.money(nil) == nil && MusicFilmAboutFacts.money("500") == 500)
    }

    @Test func aFilmMadeOutsideIndiaIsNotPlacedInAnIndianIndustryByItsLanguage() {
        #expect(MusicFilmAboutFacts.industryCountry(["GB", "FR"]) == "GB")
        #expect(MusicFilmAboutFacts.industryCountry(["GB", "IN"]) == "IN")
        #expect(MusicFilmAboutFacts.industryCountry([]) == nil)
        #expect(MusicFilmIndustry.classify(language: "hi", country: MusicFilmAboutFacts.industryCountry(["GB", "FR"])) == nil)
        #expect(MusicFilmIndustry.classify(language: "hi", country: MusicFilmAboutFacts.industryCountry(["IN", "US"]))?.name == "Bollywood")
    }

    // MARK: crew departments

    @Test func tmdbJobsMapToDepartmentsAndTheListIsBoundedAndDeduped() {
        #expect(MusicFilmDepartment.of(job: "Director of Photography") == .camera)
        #expect(MusicFilmDepartment.of(job: "Editor") == .editing)
        #expect(MusicFilmDepartment.of(job: "Supervising Sound Editor") == .sound, "a sound editor is sound, not editing")
        #expect(MusicFilmDepartment.of(job: "Costume Design") == .costume && MusicFilmDepartment.of(job: "Choreographer") == .choreography)
        #expect(MusicFilmDepartment.of(job: "Screenplay") == .writing && MusicFilmDepartment.of(job: "Production Design") == .productionDesign)
        #expect(MusicFilmDepartment.of(job: "Visual Effects Supervisor") == .visualEffects)
        #expect(MusicFilmDepartment.of(job: "Director") == nil && MusicFilmDepartment.of(job: "Producer") == nil && MusicFilmDepartment.of(job: "Original Music Composer") == nil)
        var crew: [[String: Any]] = (0..<10).map { ["id": $0, "name": "Cam \($0)", "job": "Director of Photography"] }
        crew.append(["id": 3, "name": "Cam 3", "job": "Cinematography"])
        crew.append(["id": 3, "name": "Cam 3", "job": "Editor"])
        crew.append(["id": 99, "name": "", "job": "Editor"])
        let out = MusicFilmExtraCrew.credits(fromCrew: crew)
        #expect(out.filter { $0.department == .camera }.count == MusicFilmExtraCrew.perDepartment)
        #expect(out.filter { $0.department == .editing }.map(\.tmdb) == [3], "one person may hold two departments; a blank name is dropped")
        let text = MusicFilmExtraCrew.encode(out)
        #expect(MusicFilmExtraCrew.decode(text) == out && MusicFilmExtraCrew.decode(nil).isEmpty && MusicFilmExtraCrew.decode("not json").isEmpty)
    }

    @Test func theFactsKeepTheCrewDepartmentsAndTheVideosOfTheSameReply() {
        let d = reply("""
        {"id":1,"title":"T","original_language":"hi",
         "credits":{"crew":[{"id":7,"name":"Ravi","job":"Director of Photography"},{"id":8,"name":"Sita","job":"Editor"},{"id":9,"name":"Dev","job":"Director"}]},
         "videos":{"results":[{"site":"YouTube","key":"abc","type":"Teaser","name":"Teaser","official":true,"iso_639_1":"hi"},
                              {"site":"Vimeo","key":"zzz","type":"Trailer","name":"Not listed"},
                              {"site":"YouTube","key":"def","type":"Trailer","name":"Trailer","official":true,"iso_639_1":"hi"}]}}
        """)
        let f = TMDBGraphSource.facts(d)
        #expect(MusicFilmExtraCrew.decode(f["crewExtra"]).map(\.name) == ["Ravi", "Sita"])
        #expect(MusicFilmVideos.decode(f["videos"]).map(\.key) == ["def", "abc"], "trailers before teasers, and only YouTube links")
    }

    @Test func theVideosAreLinksByKindOfficialFirstAndNeverMoreThanTheCap() {
        let rows: [[String: Any]] = [
            ["site": "YouTube", "key": "a", "type": "Clip", "official": false, "iso_639_1": "en"],
            ["site": "YouTube", "key": "b", "type": "Clip", "official": true, "iso_639_1": "en"],
            ["site": "YouTube", "key": "c", "type": "Featurette", "official": true, "iso_639_1": "hi"],
            ["site": "YouTube", "key": "d", "type": "Behind the Scenes", "official": true, "iso_639_1": "hi"],
            ["site": "YouTube", "key": "e", "type": "Bloopers", "official": true],
            ["site": "YouTube", "key": "b", "type": "Clip", "official": true]]
        let v = MusicFilmVideos.parse(results: rows, originalLanguage: "hi")
        #expect(v.map(\.key) == ["b", "a", "c", "d"] && v[0].url?.absoluteString == "https://www.youtube.com/watch?v=b")
        #expect(MusicFilmVideos.of(.clip, in: v).count == 2)
        let many: [[String: Any]] = (0..<60).map { ["site": "YouTube", "key": "k\($0)", "type": "Clip"] }
        #expect(MusicFilmVideos.parse(results: many, originalLanguage: nil).count == MusicFilmVideos.cap)
    }

    @Test func theCrewIsSearchableByRoleNameOrJobAndGroupedUnderHeadings() {
        let dp = MusicFilmCrewItem(role: .cinematographer, people: [person("Ravi Varman", "T1", role: .cinematographer, job: "Director of Photography")], department: .camera)
        let costume = MusicFilmCrewItem(role: .producer, people: [person("Sita Rao", "T2", job: "Costume Design"), person("Dev Kumar", "T3", job: "Costume Design")], department: .costume)
        let director = MusicFilmCrewItem(role: .director, people: [person("Ravi Shankar", "T4", role: .director)])
        let all = [dp, costume, director]
        let title: (MusicFilmCrewItem) -> String = { g in g.department?.rawValue ?? g.role.rawValue }
        #expect(MusicFilmCrewSearch.filter(all, query: "  ", label: title) == all)
        #expect(MusicFilmCrewSearch.filter(all, query: "ravi", label: title).map(\.id) == [dp.id, director.id])
        #expect(MusicFilmCrewSearch.filter(all, query: "costume", label: title).first?.people.count == 2, "a matching label keeps the whole group")
        #expect(MusicFilmCrewSearch.filter(all, query: "dev", label: title).first?.people.map(\.name) == ["Dev Kumar"])
        #expect(MusicFilmCrewSearch.filter(all, query: "zzz", label: title).isEmpty)
        #expect(MusicFilmCrewHeading.ordered(all).map(\.id) == [director.id, dp.id, costume.id])
        #expect(dp.id != MusicFilmCrewItem(role: .cinematographer, people: []).id, "a TMDB department never shares an id with the graph's own role group")
    }

    @Test func extraCrewIsFoundByTheirTMDBIdAndNeverListedTwice() async throws {
        let g = G8Graph()
        let ravi = try await g.put(.person, "Ravi Varman", ids: [ExternalID(.tmdbPerson, "7")])
        let credits = [MusicFilmExtraCredit(department: .camera, job: "Director of Photography", tmdb: 7, name: "Ravi Varman"),
                       MusicFilmExtraCredit(department: .editing, job: "Editor", tmdb: 8, name: "Unknown to the graph")]
        let film = try await g.put(.film, "Dept", year: 2020, lang: "hi", ids: [ExternalID(.tmdbMovie, "5")], attrs: ["crewExtra": MusicFilmExtraCrew.encode(credits) ?? ""])
        let groups = try await g8Run(MusicFilmCrewLoader(), film, g.store, as: MusicFilmCrewItem.self)
        #expect(groups.map(\.department) == [.camera], "a person the graph does not hold is skipped, never invented")
        #expect(groups.first?.people.map(\.person) == [ravi] && groups.first?.people.first?.job == "Director of Photography")
        // The same person credited as cinematographer by another source: one line.
        try await g.edge(film, .producedBy, ravi, role: .cinematographer)
        let again = try await g8Run(MusicFilmCrewLoader(), film, g.store, as: MusicFilmCrewItem.self)
        #expect(again.flatMap(\.people).filter { $0.person == ravi }.count == 1)
    }

    // MARK: language switcher and singers

    @Test func theLanguageSwitcherExistsOnlyWhenTheFilmHasADubAndFiltersByIt() {
        #expect(MusicFilmLanguageFilter.options(dubLanguages: [nil, nil]).isEmpty)
        let options = MusicFilmLanguageFilter.options(dubLanguages: [nil, "ta", "TA", "te", ""])
        #expect(options == [.all, .original, .dub("ta"), .dub("te")])
        #expect(MusicFilmLanguageFilter.all.matches(dubLanguage: nil) && MusicFilmLanguageFilter.all.matches(dubLanguage: "ta"))
        #expect(MusicFilmLanguageFilter.original.matches(dubLanguage: nil) && !MusicFilmLanguageFilter.original.matches(dubLanguage: "ta"))
        #expect(MusicFilmLanguageFilter.dub("ta").matches(dubLanguage: "TA") && !MusicFilmLanguageFilter.dub("ta").matches(dubLanguage: nil))
    }

    @Test func singersOfADubAreNotCountedAsSingersOfTheFilm() {
        let lata = MusicFilmSingerRef(person: MusicEntityID(kind: .person, token: "LATA"), name: "Lata")
        let telugu = MusicFilmSingerRef(person: MusicEntityID(kind: .person, token: "SPB"), name: "SPB")
        let songs = [song("One", singers: [lata]), song("One", album: "B", dub: "te", singers: [telugu])]
        #expect(MusicFilmPageBuilders.singers(from: songs.filter { $0.dubLanguage == nil }).map(\.name) == ["Lata"])
        #expect(MusicFilmPageBuilders.singers(from: songs.filter { MusicFilmLanguageFilter.dub("te").matches(dubLanguage: $0.dubLanguage) }).map(\.name) == ["SPB"])
    }

    // MARK: summary and provider choice

    @Test func theSoundtrackSummaryCountsTheFilmsOwnMusicOnly() {
        #expect(MusicFilmSoundtrackSummary.make(songs: [], albums: []) == nil)
        let songs = [song("a", durationMs: 120_000), song("b", durationMs: 180_000), song("c", album: "D", dub: "ta", durationMs: 999_000)]
        func album(_ n: String, dub: String?) -> MusicFilmAlbumItem {
            MusicFilmAlbumItem(album: MusicEntityID(kind: .album, token: "A" + n), name: n, year: nil, imageRef: nil, lang: nil, dubLanguage: dub, status: .verified, confidence: 1, matchEvidence: [], via: nil, film: nil, filmName: nil)
        }
        let s = MusicFilmSoundtrackSummary.make(songs: songs, albums: [album("A", dub: nil), album("D", dub: "ta")])
        #expect(s == MusicFilmSoundtrackSummary(songs: 2, albums: 1, durationMs: 300_000) && s?.minutes == 5)
    }

    @Test func aRecordingKnownOnTwoProvidersAlwaysPlaysFromTheSameCopyPreferringItsReleaseProvider() {
        let ids = [ExternalID(.provider, "ytmusic:y1"), ExternalID(.provider, "jiosaavn:j1"), ExternalID(.provider, "broken"), ExternalID(.isrc, "X")]
        #expect(MusicFilmSongRules.pickProviderUID(ids, preferring: nil) == "jiosaavn:j1")
        #expect(MusicFilmSongRules.pickProviderUID(Array(ids.reversed()), preferring: nil) == "jiosaavn:j1")
        #expect(MusicFilmSongRules.pickProviderUID(ids, preferring: "ytmusic") == "ytmusic:y1")
        #expect(MusicFilmSongRules.pickProviderUID([ExternalID(.provider, "broken")], preferring: nil) == nil)
    }

    // MARK: franchise and the model

    @Test func aFranchiseListsLiveFilmsOnly() async throws {
        let g = G8Graph()
        let a = try await g.film("Part One", 2001), b = try await g.film("Part Two", 2005), gone = try await g.film("Part Three", 2009)
        let fr = try await g.put(.series, "The Saga", year: 2001)
        for f in [a, b, gone] { try await g.edge(f, .inFranchise, fr) }
        _ = try await g.store.mergeEntities(winner: b, loser: gone, byUser: true)
        let loaded = try #require(await MusicFranchise.load(for: a, store: g.store))
        #expect(loaded.films.map(\.name) == ["Part One", "Part Two"] && loaded.films.first?.current == true)
    }

    @Test @MainActor func theMatchedTwinsSurviveLeavingAndComingBackToThePage() async throws {
        let g = G8Graph()
        let film = try await g.film("Back", 1999)
        let ost = try await g.put(.album, "Back OST", year: 1999, subkind: "soundtrack")
        try await g.edge(ost, .soundtrackOf, film, prov: G8Graph.matcher)
        let r = try await g.put(.recording, "Only Song")
        try await g.edge(r, .trackOn, ost, attrs: { var a = EdgeAttributes(); a.position = 1; return a }())
        let center = g8Center(g.store)
        let model = MusicFilmGraphModel(center: center, watch: MusicFilmWatchLogic(isInLibrary: { _ in false }, open: { _ in false }), matcher: { rows in
            rows.map { r -> MusicTrack? in MusicTrack(id: "m", providerID: "ytmusic", title: r.title, durationMs: 1, artists: []) }
        })
        model.open(film)
        await g8Wait { model.section(MusicFilmSectionKey.songs).phase == .loaded }
        model.resolveUnplayable()
        await g8Wait { !model.resolvingSongs && !model.matched.isEmpty }
        #expect(model.matched.count == 1)
        model.close()
        #expect(model.matched.count == 1, "going Back onto the page must not lose the playable copies already found")
        model.open(film)
        await g8Wait { model.section(MusicFilmSectionKey.songs).phase == .loaded }
        #expect(model.playableOriginals.count == 1)
        model.close()
    }

    @Test @MainActor func aRememberedPillWaitsForTheSectionsThatDecideIt() {
        typealias Tab = MusicFilmPage.Tab
        #expect(Set(Tab.videos.decidingSections) == [MusicFilmSectionKey.overview, MusicFilmSectionKey.songs], "music videos come from the songs, so Videos waits for them too")
        #expect(Tab.gallery.decidingSections == [MusicFilmSectionKey.overview])
        #expect(Set(Tab.score.decidingSections) == [MusicFilmSectionKey.soundtracks, MusicFilmSectionKey.songs])
        #expect(Tab.overview.decidingSections.isEmpty)
        for t in Tab.allCases { #expect(Tab(memoryName: t.memoryName) == t) }
    }

    @Test @MainActor func aSongOnTwoAlbumsIsCountedOnceAsMissingNotTwice() async throws {
        let g = G8Graph()
        let film = try await g.film("Twice", 1999)
        let original = try await g.put(.album, "Twice OST", year: 1999, subkind: "soundtrack")
        let deluxe = try await g.put(.album, "Twice OST (Deluxe)", year: 2005, subkind: "soundtrack")
        for a in [original, deluxe] { try await g.edge(a, .soundtrackOf, film, prov: G8Graph.matcher) }
        let r = try await g.put(.recording, "Shared Song")
        for a in [original, deluxe] { try await g.edge(r, .trackOn, a, attrs: { var x = EdgeAttributes(); x.position = 1; return x }()) }
        let model = MusicFilmGraphModel(center: g8Center(g.store), watch: MusicFilmWatchLogic(isInLibrary: { _ in false }, open: { _ in false }))
        model.open(film)
        await g8Wait { model.section(MusicFilmSectionKey.songs).phase == .loaded }
        #expect(model.unplayableCount(for: .all) == 1, "one recording is one missing song")
        #expect(model.unplayableCount(for: .all) <= model.unplayableCount)
        model.close()
    }

    @Test func theLanguageChipSurvivesBack() {
        for f in [MusicFilmLanguageFilter.original, .dub("te"), .dub("hi")] {
            #expect(f.memoryName.flatMap(MusicFilmLanguageFilter.init(memoryName:)) == f)
        }
        #expect(MusicFilmLanguageFilter.all.memoryName == nil)
        #expect(MusicFilmLanguageFilter(memoryName: "dub:") == nil && MusicFilmLanguageFilter(memoryName: "junk") == nil)
    }
}
