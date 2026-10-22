import Testing
import Foundation
@testable import REDDY

@MainActor @Suite struct AskLibraryTests {
    /// A tiny library: four Telugu films (two with Mahesh Babu, one with Nani, one with nobody known), one English film, and the cast index for them.
    private func library() throws -> (c: AppContainer, lib: AskLibrary, index: PeopleIndex, ids: [String: String]) {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-ask-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let sid = UUID().uuidString.lowercased()
        var ids: [String: String] = [:]
        try c.db.write { db in
            try db.execute("INSERT INTO sources(id, name, type, base_url, enabled, created_at, sort_order) VALUES(?, 'S', 'm3uRemote', 'x', 1, 0, 0)", [sid])
            let films: [(String, String, Int, String, String)] = [("pokiri", "Pokiri (Telugu)", 2006, "8.1", "Action"), ("srimanthudu", "Srimanthudu (Telugu)", 2015, "7.5", "Drama"),
                                                                 ("jersey", "Jersey (Telugu)", 2019, "8.4", "Drama"), ("misc", "Some Telugu Film (Telugu)", 2020, "5.0", "Comedy"), ("inception", "Inception (English)", 2010, "8.8", "Thriller")]
            for (k, title, year, rating, genre) in films {
                let id = "\(sid)|movie|\(k)"; ids[k] = id
                try db.execute("INSERT INTO movies(id, source_id, provider_id, title, normalized_title, release_year, rating, genre, category_id, category_name, stream_ref, created_at, updated_at, last_seen_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?, 'c', ?, 'r', 0, 0, 0)",
                               [id, sid, k, title, MetadataNormalizer.normalize(title), year, rating, genre, genre])
            }
        }
        let index = PeopleIndex(db: c.db), source = UUID(uuidString: sid)!
        try index.save(itemID: ids["pokiri"]!, kind: .movie, sourceID: source, names: ["Mahesh Babu", "Ileana"])
        try index.save(itemID: ids["srimanthudu"]!, kind: .movie, sourceID: source, names: ["Mahesh Babu", "Shruti Haasan"])
        try index.save(itemID: ids["jersey"]!, kind: .movie, sourceID: source, names: ["Nani"])
        let lib = AskLibrary(catalog: c.catalog, people: index, history: c.historyRepo)
        return (c, lib, index, ids)
    }

    @Test func aPersonIsFoundInTheCastIndexAndOnlyTheirFilmsComeBack() async throws {
        let l = try library()
        let a = await l.lib.answer(WatchIntent(people: ["Mahesh Babu"]))
        #expect(Set(a.results.map(\.item.id)) == [l.ids["pokiri"]!, l.ids["srimanthudu"]!], "Jersey is a Nani film and must not appear")
        #expect(a.results.allSatisfy { $0.reasons.contains("With Mahesh Babu") })
    }

    @Test func theWordsAloneAreEnoughToFindThePersonWithNoAI() throws {
        let l = try library()
        let intent = LocalIntent.parse("telugu movies with actor mahesh babu") { l.index.canonicalName(for: $0) }
        #expect(intent.people == ["Mahesh Babu"])
        #expect(intent.languages == ["Telugu"])
        #expect(intent.kind == .movie)
    }

    @Test func aWordThatIsNotAPersonIsNotTakenForOne() throws {
        let l = try library()
        let intent = LocalIntent.parse("a tense thriller from the 2010s") { l.index.canonicalName(for: $0) }
        #expect(intent.people.isEmpty && intent.genres == ["Thriller"] && intent.decade == 2010)
    }

    @Test func aPersonAndAYearAreBothApplied() async throws {
        let l = try library()
        let a = await l.lib.answer(WatchIntent(people: ["Mahesh Babu"], year: 2015))
        #expect(a.results.map(\.item.id) == [l.ids["srimanthudu"]!])
    }

    @Test func aPersonNobodyKnowsGivesNothingNotTheWholeLibrary() async throws {
        let l = try library()
        let a = await l.lib.answer(WatchIntent(people: ["Somebody Unknown"], genres: ["Drama"], languages: ["Hindi"], keywords: ["family"]))
        #expect(a.results.isEmpty)
    }

    @Test func filtersAloneAnswerFromTheWholeLibraryBestRatedFirst() async throws {
        let l = try library()
        let a = await l.lib.answer(WatchIntent(languages: ["Telugu"], minRating: 7))
        #expect(a.results.map(\.item.id) == [l.ids["jersey"]!, l.ids["pokiri"]!, l.ids["srimanthudu"]!])
    }

    @Test func aGenreNarrowsTheAnswerButNeverEmptiesItWhenNothingMatches() async throws {
        let l = try library()
        #expect(Set(await l.lib.answer(WatchIntent(people: ["Mahesh Babu"], genres: ["Action"])).results.map(\.item.id)) == [l.ids["pokiri"]!])
        let none = await l.lib.answer(WatchIntent(people: ["Mahesh Babu"], genres: ["Horror"]))
        #expect(none.results.count == 2, "no title is a horror film, so the genre is left out instead of showing nothing")
    }

    @Test func watchedTitlesAreMarkedAndCanBeLeftOut() async throws {
        let l = try library()
        try l.c.db.write { try $0.execute("INSERT INTO watch_history(item_id, kind, title, played_at) VALUES(?, 'movie', 'Pokiri', 1)", [l.ids["pokiri"]!]) }
        let all = await l.lib.answer(WatchIntent(people: ["Mahesh Babu"]))
        #expect(all.results.first { $0.item.id == l.ids["pokiri"]! }?.watched == true)
        #expect(all.results.first?.item.id == l.ids["srimanthudu"]!, "the one not yet watched comes first")
        let fresh = await l.lib.answer(WatchIntent(people: ["Mahesh Babu"], unwatchedOnly: true))
        #expect(fresh.results.map(\.item.id) == [l.ids["srimanthudu"]!])
    }

    @Test func tmdbAddsRealFilmographyTitlesAndNamesTheOnesNotInTheLibrary() async throws {
        var l = try library()
        l.lib.filmography = { _ in AskLibrary.TMDBFilmography(name: "Mahesh Babu", credits: [("Pokiri", 2006, false), ("Businessman", 2012, false), ("Sarkaru Vaari Paata", 2022, false)]) }
        let a = await l.lib.answer(WatchIntent(people: ["Mahesh Babu"]))
        #expect(a.usedTMDB && a.elsewhere == ["Businessman (2012)", "Sarkaru Vaari Paata (2022)"])
        #expect(a.results.count == 2)
    }

    @Test func theNoteSaysWhatWasFoundAndWhenTheCastIsOnlyPartlyRead() async throws {
        let l = try library()
        let a = await l.lib.answer(WatchIntent(people: ["Mahesh Babu"]))
        #expect(a.note.contains("2 titles in your library with Mahesh Babu"))
        let nobody = await l.lib.answer(WatchIntent(people: ["Nobody Known"]))
        #expect(nobody.results.isEmpty && nobody.note.hasPrefix("Nothing found yet"))
    }

    @Test func theAIsAnswerIsReadIntoPartsEvenInsideACodeBlock() {
        let a = "```json\n{\"people\":[\"Mahesh Babu\"],\"genres\":[\"Action\"],\"languages\":[\"Telugu\"],\"year\":null,\"decade\":2010,\"keywords\":[],\"like\":[],\"kind\":\"movie\",\"maxMinutes\":120,\"minRating\":null,\"unwatched\":true}\n```"
        let i = IntentAdvisor.parse(a)
        #expect(i == WatchIntent(people: ["Mahesh Babu"], genres: ["Action"], languages: ["Telugu"], decade: 2010, kind: .movie, maxMinutes: 120, unwatchedOnly: true))
        #expect(IntentAdvisor.parse("no json here") == nil)
        #expect(IntentAdvisor.parse("{\"year\":1500,\"people\":[],\"genres\":[],\"languages\":[],\"keywords\":[],\"like\":[],\"kind\":\"any\"}") == nil, "a nonsense year is dropped, leaving nothing")
    }

    @Test func aFollowUpChangesOnlyWhatItSays() {
        let first = WatchIntent(people: ["Mahesh Babu"], languages: ["Telugu"])
        let next = first.refined(by: WatchIntent(maxMinutes: 120, unwatchedOnly: true))
        #expect(next.people == ["Mahesh Babu"] && next.languages == ["Telugu"] && next.maxMinutes == 120 && next.unwatchedOnly)
        #expect(first.refined(by: WatchIntent(people: ["Nani"])).people == ["Nani"])
    }

    @Test func theAIsNamesAndLocalReadingAreMergedWithTheAIWinning() {
        let local = WatchIntent(languages: ["Telugu"], keywords: ["thing"])
        let merged = local.merged(with: WatchIntent(people: ["Nani"], genres: ["Drama"]))
        #expect(merged.people == ["Nani"] && merged.genres == ["Drama"] && merged.languages == ["Telugu"] && merged.keywords.isEmpty)
    }

    @Test func theAIPromptNeverCarriesLibraryDetailsOrAskForTitles() {
        let p = IntentAdvisor.prompt("something light", previous: nil)
        #expect(p == "Request: something light")
        #expect(IntentAdvisor.system.contains("Never add a film or series of your own"))
    }

    // MARK: the smarter parts

    /// A second small library for meaning, taste and variety.
    private func moods() throws -> (c: AppContainer, lib: AskLibrary, ids: [String: String]) {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-brain-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let sid = UUID().uuidString.lowercased()
        var ids: [String: String] = [:]
        try c.db.write { db in
            try db.execute("INSERT INTO sources(id, name, type, base_url, enabled, created_at, sort_order) VALUES(?, 'S', 'm3uRemote', 'x', 1, 0, 0)", [sid])
            let films: [(String, String, Int, String, String, String)] = [
                ("heist", "The Perfect Score", 2012, "7.9", "Crime", "A crew of thieves plans an elaborate robbery of a vault and must outsmart the guards and each other."),
                ("love", "Letters to Her", 2014, "7.5", "Romance", "Two strangers fall in love through handwritten letters across a quiet seaside town."),
                ("scary", "The Hollow House", 2016, "7.1", "Horror", "A family is haunted by ghosts in an old house and must escape the nightmare."),
                ("dune1", "Star Quest 1", 2015, "7.0", "Sci-Fi", "Space travellers explore a distant planet."), ("dune2", "Star Quest 2", 2016, "7.1", "Sci-Fi", "The space travellers return."),
                ("dune3", "Star Quest 3", 2017, "7.2", "Sci-Fi", "The final space voyage."), ("dune4", "Star Quest 4", 2018, "7.3", "Sci-Fi", "A new space crew.")]
            for (k, title, year, rating, genre, plot) in films {
                let id = "\(sid)|movie|\(k)"; ids[k] = id
                try db.execute("INSERT INTO movies(id, source_id, provider_id, title, normalized_title, release_year, rating, genre, overview, category_id, category_name, stream_ref, created_at, updated_at, last_seen_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, 'c', ?, 'r', 0, 0, 0)",
                               [id, sid, k, title, MetadataNormalizer.normalize(title), year, rating, genre, plot, genre])
            }
        }
        return (c, AskLibrary(catalog: c.catalog, people: PeopleIndex(db: c.db), history: c.historyRepo), ids)
    }

    @Test func notHorrorLeavesHorrorOut() async throws {
        let m = try moods()
        let intent = LocalIntent.parse("surprise me but no horror") { _ in nil }
        #expect(intent.excludeGenres == ["Horror"] && intent.surprise && !intent.genres.contains("Horror"))
        let a = await m.lib.answer(intent)
        #expect(!a.results.isEmpty && !a.results.contains { $0.item.id == m.ids["scary"]! })
    }

    @Test func aMoodIsMatchedByMeaningNotJustByTitleWords() async throws {
        let m = try moods()
        guard SemanticMatcher().isAvailable else { return }          // the on-device language model is not on every machine
        let a = await m.lib.answer(WatchIntent(keywords: ["robbery", "thieves"]))
        #expect(a.results.first?.item.id == m.ids["heist"]!, "a film about thieves and a vault fits, though its title has neither word")
    }

    @Test func whatYouUsuallyWatchRanksAndExplainsItself() async throws {
        var m = try moods()
        var taste = TasteProfile(); taste.titlesSeen = 12; taste.genres = ["Romance": 1.0]
        m.lib.taste = taste
        let a = await m.lib.answer(WatchIntent(surprise: true))
        #expect(a.results.first?.item.id == m.ids["love"]!)
        #expect(a.results.first?.reasons.contains("You often watch Romance") == true)
    }

    @Test func aThinHistoryDoesNotSteerAnything() {
        var t = TasteProfile(); t.titlesSeen = 2; t.genres = ["Drama": 1]
        #expect(!t.isUsable)
    }

    @Test func tasteIsLearnedFromTheHistoryOnTheDevice() throws {
        let m = try moods()
        try m.c.db.write { db in
            for (i, k) in ["love", "love", "heist", "dune1", "dune2", "dune3"].enumerated() {
                try db.execute("INSERT INTO watch_history(item_id, kind, title, played_at) VALUES(?, 'movie', 't', ?)", [m.ids[k]!, i])
            }
        }
        let t = TasteProfile.learn(history: m.c.historyRepo, catalog: m.c.catalog, people: PeopleIndex(db: m.c.db))
        #expect(t.titlesSeen == 5 && t.genres["Sci-Fi"] == 1 && t.genres["Romance"] != nil)
    }

    @Test func aFranchiseDoesNotFillThePage() async throws {
        let m = try moods()
        let a = await m.lib.answer(WatchIntent(surprise: true))
        let first = a.results.prefix(5).filter { $0.item.title.hasPrefix("Star Quest") }
        #expect(first.count <= 2, "four sequels of one series must not crowd out the other films")
        #expect(a.results.count == 7, "the sequels still follow after the other films")
    }

    @Test func theAIJudgePicksAndExplainsButCannotAddATitle() async throws {
        var m = try moods()
        m.lib.request = "something clever"
        m.lib.judge = { _, prompt in
            #expect(prompt.contains("The list:") && prompt.contains("The Perfect Score"))
            return "[{\"n\": 999, \"why\": \"not in the list\"}, {\"n\": 2, \"why\": \"a clever plan\"}]"          // 999 is made up and must be ignored
        }
        let a = await m.lib.answer(WatchIntent(surprise: true))
        #expect(a.judged && a.results.first?.reasons.first == "AI: a clever plan")
        #expect(a.results.count >= 4, "the rest of the list still follows the AI's pick")
    }

    @Test func aJudgeThatFailsOrRamblesChangesNothing() async throws {
        var m = try moods()
        m.lib.request = "x"
        let plain = await m.lib.answer(WatchIntent(surprise: true))
        m.lib.judge = { _, _ in nil }
        #expect(await m.lib.answer(WatchIntent(surprise: true)).results.map(\.id) == plain.results.map(\.id))
        m.lib.judge = { _, _ in "I think you would love the first one!" }
        let rambled = await m.lib.answer(WatchIntent(surprise: true))
        #expect(!rambled.judged && rambled.results.map(\.id) == plain.results.map(\.id))
    }

    @Test func theJudgeAnswerIsReadAndOnlyKnownNumbersKept() {
        let r = JudgeAdvisor.parse("Here:\n[{\"n\":2,\"why\":\"fits\"},{\"n\":2,\"why\":\"dup\"},{\"n\":7,\"why\":\"x\"}]", valid: [1, 2, 3])
        #expect(r.count == 1 && r[0].n == 2 && r[0].why == "fits")
    }

    @Test func noLibraryDetailsLeaveBeyondTheShortListTheJudgeNeeds() {
        let p = JudgeAdvisor.prompt(request: "a thriller", taste: "Drama", candidates: [JudgeAdvisor.Candidate(n: 1, title: "A", year: 2020, genre: "Drama", rating: "7.0", overview: String(repeating: "x", count: 400))])
        #expect(p.contains("1. A (2020) · Drama · rated 7.0") && p.count < 400, "the plot is cut short and nothing like an address or id is included")
        #expect(!p.contains("http") && !p.contains("|movie|"))
    }
}

@MainActor @Suite struct RequestSearchTests {
    @Test func sentencesThatReadLikeRequestsGetSmartPicksAndPlainTitlesDoNot() throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-ss-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        #expect(c.looksLikeARequest("telugu movies from 2015"))
        #expect(c.looksLikeARequest("a tense thriller not horror"))
        #expect(c.looksLikeARequest("feel good heist with a twist"), "a mood described in several words")
        #expect(c.looksLikeARequest("surprise me"))
        #expect(!c.looksLikeARequest("inception"), "one word is a title")
        #expect(!c.looksLikeARequest("the dark knight"), "a plain title stays a normal search")
        #expect(!c.looksLikeARequest("ab c"))
    }

    @Test func noSmartPicksInAKidsProfile() throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-ss2-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        c.parental.kidsMode = true
        #expect(!c.looksLikeARequest("telugu movies from 2015") && !c.aiAvailable)
    }
}

@Suite("Moods and occasions") struct MoodTests {
    private func parse(_ s: String) -> WatchIntent { LocalIntent.parse(s, hasPerson: { _ in nil }) }

    @Test func dateNight() { let i = parse("something for date night"); #expect(i.genres.contains("Romance")); #expect(i.genres.contains("Comedy")) }
    @Test func kidsAndShort() {
        #expect(parse("a movie with the kids").genres.contains("Family"))
        let s = parse("something short before bed"); #expect(s.maxMinutes == 100); #expect(s.kind == .movie)
    }
    @Test func bingeIsASeries() { #expect(parse("something to binge this weekend").kind == .series) }
    @Test func ruledOutStaysOut() { #expect(!parse("scary but no horror").genres.contains("Horror")) }
    @Test func spokenGenreWins() { let i = parse("a scary thriller tonight"); #expect(i.genres.contains("Thriller")); #expect(i.genres.contains("Horror")) }
    @Test func plainTitleUntouched() { #expect(parse("Space Jam").genres.isEmpty) }
}

@Suite("Names not read yet") struct GuessedPersonTests {
    private func parse(_ s: String) -> WatchIntent { LocalIntent.parse(s, hasPerson: { _ in nil }) }
    @Test func aNameBeforeMovies() { let i = parse("mahesh babu movies"); #expect(i.people == ["Mahesh Babu"]); #expect(i.guessedPeople == ["Mahesh Babu"]); #expect(i.kind == .movie) }
    @Test func showMeNameFilms() { #expect(parse("show me prabhas films").people == ["Prabhas"]); #expect(parse("scary movies").people.isEmpty); #expect(parse("old movies").people.isEmpty); #expect(parse("show me ram charan films").people == ["Ram Charan"]) }
    @Test func notForGenresOrLanguages() { #expect(parse("telugu action movies").people.isEmpty); #expect(parse("best comedy movies").people.isEmpty); #expect(parse("new hindi movies").people.isEmpty) }
}

@Suite("Known-for answers") struct KnownForTests {
    @Test func readsTheList() {
        let f = KnownForAdvisor.parse("Sure! [{\"title\": \"Pokiri\", \"year\": 2006, \"show\": false}, {\"title\": \"Srimanthudu\", \"year\": 2015}]", name: "Mahesh Babu")
        #expect(f?.credits.count == 2); #expect(f?.credits.first?.title == "Pokiri"); #expect(f?.credits.first?.year == 2006)
    }
    @Test func unknownPersonIsNothing() { #expect(KnownForAdvisor.parse("[]", name: "X Y") == nil); #expect(KnownForAdvisor.parse("I do not know", name: "X Y") == nil) }
}

@Suite("Search ideas work") struct SearchIdeasTests {
    @Test func everyMoodIsUnderstood() {
        for m in SearchIdeas.moods {
            let i = LocalIntent.parse(m.query, hasPerson: { _ in nil })
            #expect(!i.isEmpty || i.surprise, "\(m.label) was not understood")
        }
    }
    @Test func everyExampleDoesSomething() {
        for e in SearchIdeas.examples where e.label != "an actor's films: “Prabhas movies”" {
            let i = LocalIntent.parse(e.query, hasPerson: { _ in nil })
            #expect(!i.isEmpty || !SearchCommands.parse(e.query).isEmpty || NaturalQuery.parse(e.query).isStructured, "\(e.label) does nothing")
        }
    }
}
