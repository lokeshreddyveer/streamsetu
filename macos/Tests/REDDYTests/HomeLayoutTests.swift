import Testing
import Foundation
@testable import REDDY

/// Home v2 (docs/SMART-MIX.md section 10): placement, composition, franchises, default view, names, and graceful degradation on synthetic personas
/// (none of them is anyone's real library). Expected values of the fixture come from smartmix/tools/make_home_fixtures.py.
@Suite("Home layout")
struct HomeLayoutTests {
    private func fixture() throws -> [String: Any] { try SMFixtures.json("home-layout") }

    @Test func placementMatchesTheFixture() throws {
        for c in try fixture()["layout"] as! [[String: Any]] {
            let ctx = SMDayContext(weekday: c["weekday"] as! Int, hour: c["hour"] as! Int)
            let got = SMPlacement.layout(present: Set(c["present"] as! [String]), genres: c["genres"] as! [String], moods: c["moods"] as! [String], context: ctx, kids: c["kids"] as! Bool)
            #expect(got == (c["expect"] as! [String]), "\(c["name"] as! String)")
        }
    }

    @Test func noTwoRowsOfTheSameKindSitNextToEachOtherWhenThePageIsFull() throws {
        for c in try fixture()["layout"] as! [[String: Any]] {
            let got = SMPlacement.layout(present: Set(c["present"] as! [String]), genres: c["genres"] as! [String], moods: c["moods"] as! [String],
                                         context: SMDayContext(weekday: c["weekday"] as! Int, hour: c["hour"] as! Int), kids: c["kids"] as! Bool)
            #expect(got.count <= SMPlacement.maxRows)
            guard got.count > SMPlacement.minRows else { continue }
            for (a, b) in zip(got, got.dropFirst()) { #expect(SMPlacement.kind(a) != SMPlacement.kind(b), "\(a) next to \(b)") }
        }
    }

    @Test func dayContextReadsWeekdayAndHour() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let fri = cal.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 21))!      // a Friday
        let ctx = SMDayContext(date: fri, calendar: cal)
        #expect(ctx.weekday == 5 && ctx.hour == 21 && ctx.movieNight && !ctx.weekend)
        let sun = cal.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 9))!
        let c2 = SMDayContext(date: sun, calendar: cal)
        #expect(c2.weekday == 7 && c2.weekend && c2.morning && !c2.movieNight)
    }

    private func picks(_ rows: [[String: Any]]) -> [SMPick] {
        rows.map { d in
            var p = SMPick(id: d["id"] as! String, key: d["id"] as! String, year: d["year"] as? Int, kind: (d["kind"] as? String) == "series" ? .series : .movie, hasBackdrop: false)
            p.genre = d["genre"] as? String; p.genres = d["genres"] as? [String] ?? []; p.lang = d["lang"] as? String; p.franchise = d["franchise"] as? String
            return p
        }
    }

    @Test func compositionMatchesTheFixture() throws {
        for c in try fixture()["compose"] as! [[String: Any]] {
            var results: [SMShelfResult] = []
            for r in c["results"] as! [[String: Any]] {
                var res = SMShelfResult(shelfId: r["id"] as! String, picks: picks(r["picks"] as! [[String: Any]]), diag: SMDiagnostics())
                if r["ordered"] as? Bool == true { res.diag.caption = .trendingTMDB }
                results.append(res)
            }
            let a = c["affinity"] as! [String: Any]
            let aff = SMAffinity(topLangs: a["topLangs"] as! [String], genreKeys: a["genreKeys"] as! [String])
            let rows = SMCompose.compose(results: results, affinity: aff, context: SMDayContext(weekday: c["weekday"] as! Int, hour: c["hour"] as! Int), kids: c["kids"] as! Bool)
            let expect = c["expect"] as! [[String: Any]]
            #expect(rows.map(\.shelfId) == expect.map { $0["row"] as! String }, "\(c["name"] as! String)")
            #expect(rows.map { $0.picks.map(\.id) } == expect.map { $0["ids"] as! [String] }, "\(c["name"] as! String)")
            let all = rows.filter { $0.shelfId != SMShelf.collections }.flatMap { $0.picks.map(\.id) }
            #expect(all.count == Set(all).count, "a title appears twice on one screen")
        }
    }

    @Test func franchiseKeysMatchTheFixture() throws {
        for c in try fixture()["franchise"] as! [[String: Any]] { #expect(SMFranchise.key(identityKey: c["key"] as! String) == c["expect"] as? String, "\(c["key"] as! String)") }
        #expect(SMFranchise.name(titles: ["Harry Potter and the Chamber of Secrets", "Harry Potter and the Goblet of Fire", "Harry Potter and the Prisoner of Azkaban"], key: "harry potter") == "Harry Potter")
        #expect(SMFranchise.name(titles: ["Zed One", "Other Name", "Third"], key: "zed one") == "Zed One")
    }

    @Test func defaultViewMatchesTheFixture() throws {
        for c in try fixture()["modeDefault"] as! [[String: Any]] {
            let r = SMModeDefault.choose(chosen: (c["chosen"] as? String).flatMap(SMShelfMode.init(rawValue:)), weeklyOrdered: c["weeklyOrdered"] as! Bool, allTimeOrdered: c["allTimeOrdered"] as! Bool)
            #expect(r.mode.rawValue == c["mode"] as! String && r.auto == c["auto"] as! Bool)
        }
    }

    @Test func aTapChoosesAndTheChoiceIsRemembered() {
        let d = UserDefaults(suiteName: "homelayout.\(UUID().uuidString)")!
        #expect(SMShelfModes.chosen(d, profile: "p", shelf: "genre:drama") == nil)
        SMShelfModes.markChosen(d, profile: "p", shelf: "genre:drama"); SMShelfModes.set(d, .weekly, profile: "p", shelf: "genre:drama")
        #expect(SMShelfModes.chosen(d, profile: "p", shelf: "genre:drama") == .weekly)
        SMShelfModes.set(d, .allTime, profile: "q", shelf: "genre:drama")                       // an older version's stored choice counts as chosen
        #expect(SMShelfModes.chosen(d, profile: "q", shelf: "genre:drama") == .allTime)
    }

    @Test func rowNamesAreUniqueAndComplete() throws {
        let titles = SMNaming.allTitles
        #expect(titles.count == Set(titles).count, "two rows share a title")
        #expect(SMGenres.table.allSatisfy { SMNaming.genreTitles[$0.key] != nil })
        let f = (try fixture()["titles"] as! [String: Any])
        #expect(Set(f["rows"] as! [String]).isSubset(of: Set(titles)))
        #expect((f["genres"] as! [String: String]) == SMNaming.genreTitles)
    }

    @Test func everyRowNameHasHindiAndTeluguText() throws {
        var root = URL(fileURLWithPath: #filePath); for _ in 0..<3 { root.deleteLastPathComponent() }
        let keys = SMNaming.allTitles + [SMNaming.becauseYouWatched, SMNaming.languageRow, SMNaming.quietWeek, SMNaming.continueWatching.subtitle, SMNaming.topWeek.subtitle, SMNaming.topWeekLocal.subtitle,
                                         SMNaming.forYou.subtitle, SMNaming.rediscover.subtitle, SMNaming.fresh.subtitle, SMNaming.movieNight.subtitle, SMNaming.binge.subtitle, SMNaming.collections.subtitle]
            + SMMoods.table.map(\.subtitle)
        for lang in ["hi", "te"] {
            let url = root.appendingPathComponent("Resources/Localization/\(lang).lproj/Localizable.strings")
            let table = NSDictionary(contentsOf: url) as? [String: String] ?? [:]
            for k in keys { #expect((table[k] ?? "").isEmpty == false, "\(lang): \(k)") }
        }
    }

    // MARK: personas (synthetic libraries; nothing here is a real person's)

    private func library(_ n: Int, kinds: (Int) -> SMKind = { $0 % 3 == 0 ? .series : .movie }, genre: ((Int) -> String?)? = nil, rated: Bool = true, art: Bool = true, added: Bool = true,
                         lang: ((Int) -> String?)? = nil, franchiseOf: ((Int) -> String?)? = nil) -> [SMCandidate] {
        (0..<n).map { i in
            var c = SMCandidate(id: String(format: "x%06d", i))
            c.kind = kinds(i); c.key = "title \(i)"; c.year = 1995 + i % 30
            c.rating = rated ? "\(5 + i % 5).\(i % 10)" : nil
            c.poster = art; c.added = added ? i % 200 : nil
            if let g = genre?(i) { c.genres = SMGenres.tokens(g); c.genre = c.genres.first }
            c.lang = lang?(i); c.franchise = franchiseOf?(i)
            return c
        }
    }

    private func ctx(kids: Bool = false, oversample: Int = 0) -> SMContext {
        var c = SMContext(profile: "persona", dayKey: "2026-11-22", preferredLang: nil); c.kids = kids; c.oversample = oversample; return c
    }

    private func build(_ id: String, _ lib: [SMCandidate], _ c: SMContext) -> SMShelfResult {
        SmartMixEngine.build(shelfId: id, prepared: SmartMixEngine.prepare(lib, preferredLang: nil), ctx: c)
    }

    @Test func oversamplingOnlyExtendsTheDraw() {
        let lib = library(300, genre: { ["Action", "Drama", "Comedy", "Thriller"][$0 % 4] }, lang: { ["English", "Hindi"][$0 % 2] })
        for id in [SMShelf.topWeek, SMShelf.forYou, SMShelf.rediscover] {
            let a = build(id, lib, ctx()), b = build(id, lib, ctx(oversample: 10))
            #expect(Array(b.ids.prefix(a.ids.count)) == a.ids, Comment(rawValue: id))
            #expect(b.ids.count >= a.ids.count)
        }
    }

    @Test func aLibraryWithNothingButTitlesStillBehaves() {
        // no genres, no ratings, no dates, no artwork flags beyond the poster: new rows hide or fill, none crashes or shows an empty shelf
        let lib = library(80, rated: false, added: false)
        for id in SMShelf.contextual {
            let r = build(id, lib, ctx())
            #expect(r.diag.hidden || r.picks.count >= 3, Comment(rawValue: id))
            if id == SMShelf.fresh { #expect(r.diag.hidden, "no dates, nothing is fresh") }
            if SMShelf.isMood(id) { #expect(r.diag.hidden, "no genres, no mood") }
        }
    }

    @Test func aLibraryWithoutPostersHidesTheNewRowsInsteadOfShowingGaps() {
        let lib = library(120, genre: { _ in "Comedy" }, art: false)
        for id in [SMShelf.fresh, SMShelf.movieNight, SMShelf.binge, SMShelf.mood("feelGood")] { #expect(build(id, lib, ctx()).diag.hidden, Comment(rawValue: id)) }
    }

    @Test func moodsAdaptToLibrarySizeAndKids() {
        let small = library(80, genre: { $0 % 2 == 0 ? "Family, Animation" : "Thriller" })
        #expect(build(SMShelf.mood("withKids"), small, ctx(kids: true)).diag.hidden == false)
        #expect(build(SMShelf.mood("edge"), small, ctx(kids: true)).diag.hidden, "Kids profiles have no tense mood")
        #expect(build(SMShelf.mood("edge"), small, ctx()).diag.hidden == false)
        // a 6,000 title library needs 90 matching titles (1.5 %): 40 family titles are not a mood there
        let big = library(6000, genre: { $0 < 40 ? "Family" : "Documentary" })
        #expect(build(SMShelf.mood("withKids"), big, ctx()).diag.hidden)
    }

    @Test func collectionsNeedThreeTitlesAndSkipRestrictedOnes() {
        var lib = library(60, franchiseOf: { $0 < 4 ? "alpha one" : ($0 < 6 ? "beta two" : nil) })
        let r = build(SMShelf.collections, lib, ctx())
        #expect(r.diag.hidden, "one franchise with 4 titles and one with 2 are fewer than 3 collections")
        lib = library(60, franchiseOf: { $0 < 4 ? "alpha one" : ($0 < 8 ? "beta two" : ($0 < 12 ? "gamma three" : nil)) })
        lib[1].restricted = true; lib[2].restricted = true; lib[9].poster = false; lib[10].poster = false
        #expect(build(SMShelf.collections, lib, ctx()).diag.hidden, "alpha and gamma each lost two titles (restricted, no poster): one collection is left")
        lib[1].restricted = false; lib[2].restricted = false; lib[9].poster = true; lib[10].poster = true
        let r3 = build(SMShelf.collections, lib, ctx())
        #expect(r3.diag.hidden == false && r3.collections.count == 3 && r3.collections.allSatisfy { $0.memberIds.count >= 3 })
    }

    @Test func composedHomeShowsEachTitleOnceOnEveryPersona() {
        let personas: [(String, [SMCandidate])] = [
            ("english only, 80 titles", library(80, genre: { ["Action", "Comedy", "Drama"][$0 % 3] }, lang: { _ in "English" })),
            ("hindi and telugu heavy", library(400, genre: { ["Action", "Drama", "Romance", "Comedy"][$0 % 4] }, lang: { ["Hindi", "Telugu", "English"][$0 % 3] })),
            ("series only", library(200, kinds: { _ in .series }, genre: { ["Drama", "Crime", "Reality"][$0 % 3] })),
            ("movies only, no genres", library(150, kinds: { _ in .movie })),
            ("kids household", library(300, genre: { ["Family", "Animation", "Kids", "Comedy"][$0 % 4] })),
            ("huge, hundreds of folders", library(20000, genre: { ["Action", "Drama", "Comedy", "Horror", "Anime"][$0 % 5] }, lang: { ["English", "Korean", "Turkish", "Arabic"][$0 % 4] })),
        ]
        for (name, lib) in personas {
            let prepared = SmartMixEngine.prepare(lib, preferredLang: nil)
            let c = ctx(kids: name.hasPrefix("kids"), oversample: 10)
            var results: [SMShelfResult] = []
            for id in SMShelf.all + SMShelf.contextual { results.append(SmartMixEngine.build(shelfId: id, prepared: prepared, ctx: c)) }
            for g in SMGenres.select(counts: SmartMixEngine.genreCounts(prepared), ctx: c) { results.append(SmartMixEngine.build(shelfId: SMGenres.shelfId(g), prepared: prepared, ctx: c)) }
            let rows = SMCompose.compose(results: results, affinity: SMAffinity(), context: SMDayContext(weekday: 5, hour: 20), kids: c.kids)
            let ids = rows.filter { $0.shelfId != SMShelf.collections }.flatMap { $0.picks.map(\.id) }
            #expect(ids.count == Set(ids).count, Comment(rawValue: name))
            #expect(rows.allSatisfy { !$0.picks.isEmpty }, "\(name): an empty row")
            #expect(rows.count <= SMPlacement.maxRows, Comment(rawValue: name))
        }
    }
}
