import Testing
import Foundation
@testable import REDDY

@Suite("Folder rows", .serialized) @MainActor struct FolderRowsTests {
    let c: AppContainer
    let s: PlaylistSource
    var ids: [String] = []

    init() throws {
        c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-fr-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        s = try TestSupport.makeSource(c.db, name: "Folders")
        var cats: [CatalogCategory] = [], movies: [Movie] = []
        let now = Date().timeIntervalSince1970
        for f in 0..<45 {
            let cat = CatalogCategory(id: "f\(f)", sourceID: s.id, kind: .movie, providerID: "f\(f)", name: f == 3 ? "HINDI | BOLLYWOOD" : f == 40 ? "ADULT | LOCKED" : "EN | FOLDER \(f)", sortOrder: f)
            cats.append(cat)
            for i in 0..<(f == 44 ? 0 : 15) {
                var m = TestSupport.movie(s, "m\(f)-\(i)", "Title \(f) \(i) (202\(i % 5))", year: 2020 + i % 5)
                m.categoryID = cat.id; m.categoryName = cat.name; m.posterURL = "https://img.example/\(f)-\(i).jpg"; m.addedAt = Date(timeIntervalSince1970: now - Double(i) * 86400); m.rating = "7.0"
                movies.append(m)
            }
        }
        _ = try CatalogIndexer(db: c.db).commitMovies(source: s, categories: cats, movies: movies)
        _ = try IdentityStore(db: c.db).backfill()
    }

    @Test func namesAreCleanedButNeverChangedInTheData() {
        #expect(FolderNaming.clean("EN | ACTION MOVIES") == "Action Movies")
        #expect(FolderNaming.clean("Hindi | Bollywood") == "Hindi · Bollywood")
        #expect(FolderNaming.clean("Kids") == "Kids")
        #expect(FolderNaming.clean("|||") == "|||")
    }

    @Test func theListIsPagedTwentyAtATimeAndEmptyFoldersAreLeftOut() async throws {
        let m = FolderRowsModel(kind: .movie)
        await m.reload(c, sourceID: nil, profile: "main")
        #expect(m.rows.count == 44 && m.visible.count == 20 && m.hasMore)
        m.more(); m.more()
        #expect(m.visible.count == 44 && !m.hasMore)
    }

    @Test func aLockedFolderShowsNoCountAndNoTilesAndHiddenOnesAreAbsent() async throws {
        try c.catalog.setCategoryLocked("f40", true, family: false)
        try c.favoritesRepo.hide("f5", kind: "category")
        c.catalog.restriction.isActive = true
        let m = FolderRowsModel(kind: .movie)
        await m.reload(c, sourceID: nil, profile: "main")
        let locked = try #require(m.rows.first { $0.id == "f40" })
        #expect(locked.locked && locked.count == 0)
        #expect(!m.rows.contains { $0.id == "f5" })
        await m.ensureTiles(locked, c, sourceID: nil, profile: "main")
        #expect(m.tiles["f40"] == nil)
    }

    @Test func preferredLanguageAndRecentFoldersComeFirst() async throws {
        c.settings.preferredAudioLanguage = "Hindi"
        await c.smartMix.noteFolderOpened(profile: "main", categoryID: "f9").value
        let m = FolderRowsModel(kind: .movie)
        await m.reload(c, sourceID: nil, profile: "main")
        #expect(m.rows.first?.id == "f9", "recently opened first")
        #expect(m.rows[1].id == "f3", "then the folder named for the preferred language")
    }

    @Test func tilesComeFromTheEngineAreStableAndNeverExceedTwelve() async throws {
        let m = FolderRowsModel(kind: .movie)
        await m.reload(c, sourceID: nil, profile: "main")
        let row = try #require(m.rows.first)
        await m.ensureTiles(row, c, sourceID: nil, profile: "main")
        let first = try #require(m.tiles[row.id]).map(\.id)
        #expect(first.count == 12 && Set(first).count == 12)
        let again = await c.smartMix.folderItems(profile: "main", sourceID: nil, kind: .movie, folderName: row.name, preferredLanguage: c.settings.preferredAudioLanguage).map(\.id)
        #expect(again == first, "same session, same tiles")
    }

    @Test func theViewChoiceIsRememberedPerProfile() {
        let d = UserDefaults(suiteName: "fr-\(UUID().uuidString)")!
        #expect(FolderViewMode.load(.movie, profile: "a", defaults: d) == .folders)
        FolderViewMode.save(.grid, .movie, profile: "a", defaults: d)
        #expect(FolderViewMode.load(.movie, profile: "a", defaults: d) == .grid)
        #expect(FolderViewMode.load(.movie, profile: "b", defaults: d) == .folders)
        #expect(FolderViewMode.load(.series, profile: "a", defaults: d) == .folders)
    }
}
