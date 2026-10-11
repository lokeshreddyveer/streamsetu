import Testing
import Foundation
@testable import REDDY

@Suite("Categories: provider → parser → database → repository → sidebar") @MainActor struct CategoryTests {
    // MARK: helpers

    func container() throws -> AppContainer {
        try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-cat-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
    }

    func json(_ entries: [Any]) -> Data { try! JSONSerialization.data(withJSONObject: entries) }

    func providerJSON(count: Int, namePrefix: String = "Group") -> Data {
        json((0..<count).map { ["category_id": String($0 + 1), "category_name": "\(namePrefix) \($0 + 1)", "parent_id": 0] as [String: Any] })
    }

    /// One channel per category so every folder holds something.
    func channels(_ src: PlaylistSource, _ cats: [CatalogCategory], perCategory: Int = 1) -> [Channel] {
        var out: [Channel] = []
        for (i, c) in cats.enumerated() {
            for k in 0..<perCategory {
                var ch = TestSupport.channel(src, "\(i)-\(k)", "Channel \(i)-\(k)", cat: nil, order: i)
                ch.categoryID = c.id; ch.categoryName = c.name
                out.append(ch)
            }
        }
        return out
    }

    func fetch(_ src: PlaylistSource, kind: ContentKind = .channel, data: Data) -> CategoryFetch {
        let r = XtreamClient.decodeCategoryList(data, action: "get_live_categories")
        return XtreamMapper(source: src).categoryFetch(r.items, kind: kind, listed: r.listed, rejected: r.rejected)
    }

    // MARK: parsing

    @Test func aHundredAndFiftyCategoriesSurviveEveryStage() throws {
        let c = try container()
        let src = try TestSupport.makeSource(c.db, type: .xtream)
        let f = fetch(src, data: providerJSON(count: 150))
        #expect(f.providerCount == 150 && f.parsedCount == 150 && f.rejected.isEmpty)
        let r = try c.indexer.commitChannels(source: src, categories: f.categories, channels: channels(src, f.categories))
        #expect(r.categories.inserted == 150)
        #expect(try c.catalog.storedCategoryCount(sourceID: src.id, kind: .channel) == 150)
        let returned = try c.catalog.categories(sourceID: src.id, kind: .channel, includeHidden: false)
        #expect(returned.count == 150)
        #expect(SidebarModel.folders(returned, hideEmpty: true).count == 150, "all 150 reach the sidebar")
        #expect(Set(SidebarModel.folders(returned).map(\.id)).count == 150, "no two rows share an identity (SwiftUI ForEach)")
    }

    @Test func oneMalformedEntryNeverCostsTheWholeList() {
        let src = PlaylistSource(name: "S", type: .xtream, baseURL: "x")
        let data = json([NSNull(), "oops", ["category_name": "No id"], ["category_id": 7], ["category_id": "2", "category_name": "Sports"],
                         ["category_id": 2, "category_name": "Sports again"], ["category_id": 9.0, "category_name": "Nine"]])
        let f = fetch(src, data: data)
        #expect(f.providerCount == 7)
        #expect(f.categories.map(\.providerID) == ["7", "2", "9"], "usable entries kept in provider order")
        #expect(f.categories.first?.name == "Category 7", "an id without a name is kept under a neutral name")
        #expect(f.rejected.count == 4, "null, bare string, missing id, repeated id: \(f.rejected)")
        #expect(f.rejected.allSatisfy { !$0.contains("http") && !$0.lowercased().contains("password") }, "reasons never carry addresses or logins")
        #expect(f.parsedCount + f.rejected.count == f.providerCount)
    }

    @Test func emptyAnswersAreEmptyNotErrors() {
        for body in ["false", "null", "{}", "[]"] {
            let r = XtreamClient.decodeCategoryList(Data(body.utf8), action: "x")
            #expect(r.items.isEmpty && r.listed == 0 && r.rejected.isEmpty, "\(body)")
        }
        let keyed = XtreamClient.decodeCategoryList(Data(#"{"1":{"category_id":"1","category_name":"A"},"2":{"category_id":"2","category_name":"B"}}"#.utf8), action: "x")
        #expect(keyed.items.count == 2, "some panels key the list by id")
    }

    // MARK: identity

    @Test func duplicateNamesStayDistinctFolders() throws {
        let c = try container()
        let src = try TestSupport.makeSource(c.db, type: .xtream)
        let f = fetch(src, data: json([["category_id": "1", "category_name": "Sports"], ["category_id": "2", "category_name": "Sports"], ["category_id": "3", "category_name": "SPORTS"]]))
        _ = try c.indexer.commitChannels(source: src, categories: f.categories, channels: channels(src, f.categories))
        let shown = SidebarModel.folders(try c.catalog.categories(sourceID: src.id, kind: .channel, includeHidden: false))
        #expect(shown.count == 3 && Set(shown.map(\.id)).count == 3)
    }

    @Test func sameProviderIDAcrossTypesAndSourcesNeverMerges() throws {
        let c = try container()
        let a = try TestSupport.makeSource(c.db, name: "A", type: .xtream), b = try TestSupport.makeSource(c.db, name: "B", type: .xtream)
        let one = json([["category_id": "5", "category_name": "Same"]])
        var ids = Set<String>()
        for src in [a, b] {
            for kind in [ContentKind.channel, .movie, .series] { ids.insert(fetch(src, kind: kind, data: one).categories[0].id) }
        }
        #expect(ids.count == 6, "3 types × 2 sources, all with provider id 5")
        // and the database agrees
        _ = try c.indexer.commitChannels(source: a, categories: fetch(a, kind: .channel, data: one).categories, channels: [])
        _ = try c.indexer.commitMovies(source: a, categories: fetch(a, kind: .movie, data: one).categories, movies: [])
        #expect(try c.catalog.storedCategoryCount(sourceID: a.id, kind: .channel) == 1)
        #expect(try c.catalog.storedCategoryCount(sourceID: a.id, kind: .movie) == 1)
    }

    @Test func m3uGroupsKeepTheirExactTitle() {
        let src = PlaylistSource(name: "M", type: .m3uRemote, baseURL: "x")
        func cat(_ g: String?) -> String? { M3UProvider.categoryFor(M3UEntry(name: "C", url: "http://x/1.ts", attributes: g.map { ["group-title": $0] } ?? [:]), source: src, kind: .channel)?.id }
        let ids = [cat("News"), cat("NEWS"), cat("UK | Sports"), cat("UK - Sports")]
        #expect(Set(ids.compactMap { $0 }).count == 4, "case and separators are part of a group's identity")
        #expect(cat(nil) == nil, "no group-title means uncategorized, not dropped")
        #expect(cat("News") == cat("News"), "stable between syncs")
    }

    // MARK: persistence & reconciliation

    @Test func emptyCategoriesArePersistedAndShownUnlessHidden() throws {
        let c = try container()
        let src = try TestSupport.makeSource(c.db, type: .xtream)
        let f = fetch(src, data: providerJSON(count: 10))
        _ = try c.indexer.commitChannels(source: src, categories: f.categories, channels: channels(src, Array(f.categories.prefix(6))))
        #expect(try c.catalog.storedCategoryCount(sourceID: src.id, kind: .channel) == 10, "provider-defined folders are never discarded")
        let returned = try c.catalog.categories(sourceID: src.id, kind: .channel, includeHidden: false)
        #expect(SidebarModel.folders(returned, hideEmpty: false).count == 10)
        #expect(SidebarModel.folders(returned, hideEmpty: true).count == 6, "the option hides the 4 empty ones, nothing is deleted")
    }

    @Test func uncategorizedItemsHaveAFolder() throws {
        let c = try container()
        let src = try TestSupport.makeSource(c.db, type: .xtream)
        var loose = TestSupport.channel(src, "x", "Loose Channel", cat: nil); loose.categoryID = nil; loose.categoryName = nil
        _ = try c.indexer.commitChannels(source: src, categories: [], channels: [loose])
        #expect(try c.catalog.uncategorizedCount(sourceID: src.id, kind: .channel) == 1)
        let listed = try c.catalog.channels(ChannelQuery(sourceID: src.id, categoryID: CatalogCategory.uncategorizedID))
        #expect(listed.map(\.name) == ["Loose Channel"])
        let entries = SidebarModel.folders([], hideEmpty: true, uncategorized: 1)
        #expect(entries.map(\.title) == ["Uncategorized"])
        var m = TestSupport.movie(src, "m", "Loose Movie"); m.categoryID = nil
        _ = try c.indexer.commitMovies(source: src, categories: [], movies: [m])
        #expect(try c.catalog.movies(VODQuery(sourceID: src.id, categoryID: CatalogCategory.uncategorizedID)).count == 1)
    }

    @Test func itemsInAnUnlistedCategoryAreNotLost() throws {
        let c = try container()
        let src = try TestSupport.makeSource(c.db, type: .xtream)
        let id = CatalogCategory.makeID(source: src.id, kind: .movie, provider: "77")
        var m = TestSupport.movie(src, "m", "Orphan Movie"); m.categoryID = id; m.categoryName = "Category 77"
        let r = try c.indexer.commitMovies(source: src, categories: [], movies: [m])
        #expect(r.categories.synthesized == 1)
        let cats = try c.catalog.categories(sourceID: src.id, kind: .movie, includeHidden: false)
        #expect(cats.map(\.name) == ["Category 77"] && cats[0].itemCount == 1, "the folder exists, so the movie is reachable")
    }

    @Test func aBadOrEmptyRefreshKeepsTheStoredFolders() throws {
        let c = try container()
        let src = try TestSupport.makeSource(c.db, type: .xtream)
        let full = fetch(src, data: providerJSON(count: 40))
        _ = try c.indexer.commitChannels(source: src, categories: full.categories, channels: channels(src, full.categories))
        let few = channels(src, [full.categories[0]])                          // the refreshed channel list only mentions one folder

        // provider answers with nothing (an error page parsed as an empty list)
        var r = try c.indexer.commitChannels(source: src, categories: [], channels: few)
        #expect(r.categories.synthesized == 1 && r.categories.keptStale == 39 && r.categories.removed == 0 && r.categories.note != nil)
        #expect(try c.catalog.storedCategoryCount(sourceID: src.id, kind: .channel) == 40)

        // provider answers with a fragment (10 of 40)
        r = try c.indexer.commitChannels(source: src, categories: Array(full.categories.prefix(10)), channels: few)
        #expect(r.categories.keptStale == 30 && r.categories.removed == 0)
        #expect(try c.catalog.storedCategoryCount(sourceID: src.id, kind: .channel) == 40)
        #expect(try c.catalog.categories(sourceID: src.id, kind: .channel, includeHidden: false).map(\.name).contains("Group 40"), "folders the bad answer left out are still there")
    }

    @Test func foldersThatItemsStillUseSurviveAnEmptyCategoryList() throws {
        let c = try container()
        let src = try TestSupport.makeSource(c.db, type: .xtream)
        let full = fetch(src, data: providerJSON(count: 40))
        let items = channels(src, full.categories)
        _ = try c.indexer.commitChannels(source: src, categories: full.categories, channels: items)
        let r = try c.indexer.commitChannels(source: src, categories: [], channels: items)
        #expect(r.categories.synthesized == 40 && r.categories.removed == 0, "every channel still has its folder")
        #expect(try c.catalog.storedCategoryCount(sourceID: src.id, kind: .channel) == 40)
    }

    @Test func genuineRemovalsAreApplied() throws {
        let c = try container()
        let src = try TestSupport.makeSource(c.db, type: .xtream)
        let full = fetch(src, data: providerJSON(count: 12))
        _ = try c.indexer.commitChannels(source: src, categories: full.categories, channels: channels(src, full.categories))
        let fewer = Array(full.categories.prefix(10))
        let r = try c.indexer.commitChannels(source: src, categories: fewer, channels: channels(src, fewer))
        #expect(r.categories.removed == 2 && r.categories.keptStale == 0 && r.categories.updated == 10)
        #expect(try c.catalog.storedCategoryCount(sourceID: src.id, kind: .channel) == 10)
    }

    @Test func aFailedSyncChangesNothing() throws {
        let c = try container()
        let src = try TestSupport.makeSource(c.db, type: .xtream)
        let good = fetch(src, data: providerJSON(count: 8))
        _ = try c.indexer.commitChannels(source: src, categories: good.categories, channels: channels(src, good.categories))
        // a list that breaks the (source, type, provider id) identity rule halfway through the transaction
        let clash = [good.categories[0],
                     CatalogCategory(id: "other-id", sourceID: src.id, kind: .channel, providerID: good.categories[1].providerID, name: "Clash", sortOrder: 1)]
        #expect(throws: Error.self) { try c.indexer.commitChannels(source: src, categories: clash, channels: channels(src, clash)) }
        #expect(try c.catalog.storedCategoryCount(sourceID: src.id, kind: .channel) == 8, "the transaction rolled back")
        #expect(try c.catalog.categories(sourceID: src.id, kind: .channel, includeHidden: false).map(\.name).contains("Group 3"))
        // and an empty provider answer for items throws before touching anything
        #expect(throws: Error.self) { try c.indexer.commitChannels(source: src, categories: [], channels: []) }
        #expect(try c.catalog.storedCategoryCount(sourceID: src.id, kind: .channel) == 8)
    }

    @Test func favoritesAndHistorySurviveCategoryReconciliation() throws {
        let c = try container()
        let src = try TestSupport.makeSource(c.db, type: .xtream)
        let full = fetch(src, data: providerJSON(count: 12))
        let items = channels(src, full.categories)
        _ = try c.indexer.commitChannels(source: src, categories: full.categories, channels: items)
        let ch = try #require(try c.catalog.channels(ChannelQuery(sourceID: src.id, collapseVariants: false)).first)
        try c.favoritesRepo.setFavorite(ch.id, kind: .channel, on: true)
        try c.historyRepo.recordPlay(itemID: ch.id, kind: .channel, title: ch.name)
        _ = try c.indexer.commitChannels(source: src, categories: Array(full.categories.dropFirst(2)), channels: items)
        #expect(try c.favoritesRepo.favoriteIDs(kind: .channel).contains(ch.id))
        #expect(try c.historyRepo.recentIDs(kind: .channel, limit: 5).contains(ch.id))
    }

    // MARK: scale

    @Test func largeCatalogsKeepEveryFolder() throws {
        let c = try container()
        let src = try TestSupport.makeSource(c.db, type: .xtream)
        let f = fetch(src, data: providerJSON(count: 2_000))
        let items = channels(src, f.categories, perCategory: 12)               // 24,000 channels
        let started = Date()
        _ = try c.indexer.commitChannels(source: src, categories: f.categories, channels: items)
        let returned = try c.catalog.categories(sourceID: src.id, kind: .channel, includeHidden: false)
        #expect(returned.count == 2_000 && returned.allSatisfy { $0.itemCount == 12 })
        #expect(SidebarModel.folders(returned).count == 2_000)
        #expect(Date().timeIntervalSince(started) < 60, "indexing and listing stay fast")
    }

    // MARK: multiple playlists, hidden folders, filtering

    @Test func twoPlaylistsKeepTheirOwnSports() throws {
        let c = try container()
        let a = try TestSupport.makeSource(c.db, name: "A", type: .xtream), b = try TestSupport.makeSource(c.db, name: "B", type: .xtream)
        let data = json([["category_id": "1", "category_name": "Sports"], ["category_id": "2", "category_name": "Movies"], ["category_id": "3", "category_name": "Entertainment"]])
        for s in [a, b] { let f = fetch(s, data: data); _ = try c.indexer.commitChannels(source: s, categories: f.categories, channels: channels(s, f.categories)) }
        let onlyA = try c.catalog.categories(sourceID: a.id, kind: .channel, includeHidden: false)
        let everything = try c.catalog.categories(sourceID: nil, kind: .channel, includeHidden: false)
        #expect(onlyA.count == 3 && onlyA.allSatisfy { $0.sourceID == a.id })
        #expect(everything.count == 6 && Set(everything.map(\.id)).count == 6, "an all-sources view keeps both sets distinct")
    }

    @Test func hiddenFoldersAreFilteredOnlyWhenAsked() throws {
        let c = try container()
        let src = try TestSupport.makeSource(c.db, type: .xtream)
        let f = fetch(src, data: providerJSON(count: 5))
        _ = try c.indexer.commitChannels(source: src, categories: f.categories, channels: channels(src, f.categories))
        try c.favoritesRepo.hide(f.categories[0].id, kind: "category")
        #expect(try c.catalog.categories(sourceID: src.id, kind: .channel, includeHidden: false).count == 4)
        #expect(try c.catalog.categories(sourceID: src.id, kind: .channel, includeHidden: true).count == 5)
        #expect(try c.catalog.storedCategoryCount(sourceID: src.id, kind: .channel) == 5, "hiding never deletes")
    }

    @Test func sidebarFilteringIgnoresCaseAndAccents() {
        let src = UUID()
        let cats = ["Sports", "SPORTS Extra", "Café Shows", "News"].enumerated().map { CatalogCategory(id: "c\($0.offset)", sourceID: src, kind: .channel, providerID: "\($0.offset)", name: $0.element, sortOrder: $0.offset, itemCount: 1) }
        let folders = SidebarModel.folders(cats)
        #expect(SidebarModel.filter(folders, query: "sports").count == 2)
        #expect(SidebarModel.filter(folders, query: "cafe").map(\.title) == ["Café Shows"])
    }

    // MARK: migration

    @Test func migrationFromV3KeepsCategoriesAndAddsTheIdentityRule() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("reddy-mig-\(UUID().uuidString).sqlite").path
        let conn = try Connection(path: path, readOnly: false)
        for m in DatabaseMigrator.migrations where m.version <= 3 { try conn.exec(m.sql); try conn.exec("PRAGMA user_version = \(m.version)") }
        let sid = UUID().uuidString
        try conn.exec("INSERT INTO sources(id, name, type, base_url, enabled, created_at) VALUES('\(sid)','S','xtream','x',1,0)")
        for (id, pid) in [("a", "1"), ("b", "1"), ("c", "2"), ("d", "3")] {      // a and b break the new rule
            try conn.exec("INSERT INTO categories(id, source_id, kind, provider_id, name, normalized_name, sort_order, last_seen_at) VALUES('\(id)','\(sid)','live','\(pid)','N\(pid)','n\(pid)',0,0)")
        }
        try DatabaseMigrator.migrate(conn)
        #expect(try conn.scalarInt("PRAGMA user_version") == DatabaseMigrator.latestVersion && DatabaseMigrator.latestVersion >= 4)
        #expect(try conn.scalarInt("SELECT COUNT(*) FROM categories") == 3, "the duplicate is collapsed, real folders kept")
        #expect(try conn.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE name='idx_categories_identity'") == 1)
        #expect(try conn.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE name='category_sync_stats'") == 1)
        #expect(throws: Error.self) { try conn.exec("INSERT INTO categories(id, source_id, kind, provider_id, name, normalized_name, sort_order, last_seen_at) VALUES('z','\(sid)','live','2','x','x',0,0)") }
    }

    // MARK: diagnostics

    @Test func diagnosticsAccountForEveryStage() throws {
        let c = try container()
        let src = try TestSupport.makeSource(c.db, type: .xtream)
        let data = json([["category_id": "1", "category_name": "A"], ["category_id": "2", "category_name": "B"], NSNull(), ["category_name": "no id"]])
        let f = fetch(src, data: data)
        let r = try c.indexer.commitChannels(source: src, categories: f.categories, channels: channels(src, [f.categories[0]]))
        try c.catalog.recordCategoryStats(sourceID: src.id, kind: .channel, fetch: f, reconcile: r.categories)
        let live = try #require(try c.categoryDiagnostics.report(sourceID: src.id, hideEmpty: false).first { $0.kind == .channel })
        #expect(live.provider == 4 && live.parsed == 2 && live.rejected == 2)
        #expect(live.stored == 2 && live.returned == 2 && live.displayed == 2)
        #expect(live.parsed! + live.rejected == live.provider!, "every provider entry is either parsed or rejected, none vanish")
        let hidden = try #require(try c.categoryDiagnostics.report(sourceID: src.id, hideEmpty: true).first { $0.kind == .channel })
        #expect(hidden.displayed == 1 && hidden.stored == 2, "the empty folder is stored but not displayed")
        let text = CategoryDiagnosticsService.text([live], playlist: "Test")
        #expect(text.contains("Provider: 4") && text.contains("Stored: 2") && !text.contains("http"))
    }
}
