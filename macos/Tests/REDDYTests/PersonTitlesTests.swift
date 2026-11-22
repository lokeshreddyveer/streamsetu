import Testing
import Foundation
@testable import REDDY

@Suite("Person titles", .serialized) @MainActor struct PersonTitlesTests {
    @Test func eachTitleOnceWithItsOtherLanguagesAndNothingRestricted() async throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-pt-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let s = try TestSupport.makeSource(c.db, name: "People")
        let open = CatalogCategory(id: "open", sourceID: s.id, kind: .movie, providerID: "open", name: "ENGLISH", sortOrder: 0)
        let hin = CatalogCategory(id: "hin", sourceID: s.id, kind: .movie, providerID: "hin", name: "HINDI DUBBED", sortOrder: 1)
        let adult = CatalogCategory(id: "adult", sourceID: s.id, kind: .movie, providerID: "adult", name: "ADULT", sortOrder: 2)
        func mv(_ pid: String, _ t: String, _ cat: CatalogCategory) -> Movie { var m = TestSupport.movie(s, pid, t, year: 2020); m.categoryID = cat.id; m.categoryName = cat.name; return m }
        let a = mv("a", "Big Film (2020)", open), b = mv("b", "Big Film (2020) Hindi", hin), x = mv("x", "Quiet Night (2020)", open), y = mv("y", "Quiet Night (2020)", adult), z = mv("z", "Solo (2021)", open)
        _ = try CatalogIndexer(db: c.db).commitMovies(source: s, categories: [open, hin, adult], movies: [a, b, x, y, z])
        _ = try IdentityStore(db: c.db).backfill()
        for m in [a, b, x, y, z] { try PeopleIndex(db: c.db).save(itemID: m.id, kind: .movie, sourceID: s.id, names: ["Ravi Kumar"]) }
        try c.catalog.setCategoryLocked("adult", true, family: false)
        let list = await PersonTitles.load(name: "Ravi Kumar", container: c)
        #expect(Set(list.map { IdentityKey.make($0.item.title) }) == ["big film", "solo"], "Quiet Night has a copy in a locked folder, so it is not listed")
        #expect(list.count == 2, "each title once")
        #expect(list.first { IdentityKey.make($0.item.title) == "big film" }?.otherLanguages.count == 1, "the other version is folded into the one entry")
    }

    @Test func aPersonPageNeedsTheWholeName() async throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-pt-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let s = try TestSupport.makeSource(c.db, name: "People")
        let cat = CatalogCategory(id: "open", sourceID: s.id, kind: .movie, providerID: "open", name: "ENGLISH", sortOrder: 0)
        var m = TestSupport.movie(s, "r", "Ramesh Story (2020)", year: 2020); m.categoryID = cat.id; m.categoryName = cat.name
        _ = try CatalogIndexer(db: c.db).commitMovies(source: s, categories: [cat], movies: [m])
        _ = try IdentityStore(db: c.db).backfill()
        try PeopleIndex(db: c.db).save(itemID: m.id, kind: .movie, sourceID: s.id, names: ["Ramesh Babu"])
        #expect(await PersonTitles.load(name: "Ram", container: c).isEmpty, "a prefix of a first name never brings another person's titles")
        #expect(await PersonTitles.load(name: "Ramesh Babu", container: c).count == 1)
    }

    @Test func castRowNeverShowsAnotherTitlesCast() async {
        let model = CastModel()
        let p = TitleDetails.Person(name: "A B", role: nil, photoPath: nil)
        await model.load(itemID: "one") { ([p], true) }
        #expect(model.people.count == 1)
        await model.load(itemID: "two") { ([], false) }
        #expect(model.people.isEmpty && model.itemID == "two", "the row is emptied when the title changes")
    }
}
