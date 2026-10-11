import Testing
import Foundation
@testable import REDDY

@Suite("Channel manager: folder order and instant edits") @MainActor struct ChannelManagerTests {
    func container() throws -> AppContainer {
        try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-cm-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
    }

    func seed(_ c: AppContainer, folders: Int = 5, perFolder: Int = 3) throws -> (PlaylistSource, [CatalogCategory]) {
        let src = try TestSupport.makeSource(c.db, type: .xtream)
        let cats = (0..<folders).map { i in CatalogCategory(id: CatalogCategory.makeID(source: src.id, kind: .channel, provider: "\(i)"), sourceID: src.id, kind: .channel, providerID: "\(i)", name: "Folder \(i)", sortOrder: i) }
        var chans: [Channel] = []
        for (i, cat) in cats.enumerated() { for k in 0..<perFolder { var ch = TestSupport.channel(src, "\(i)-\(k)", "Channel \(i)-\(k)", cat: nil, order: i); ch.categoryID = cat.id; ch.categoryName = cat.name; chans.append(ch) } }
        try c.indexer.commitChannels(source: src, categories: cats, channels: chans)
        return (src, cats)
    }

    @Test func folderOrderIsSavedAndUsedByTheSidebarQuery() throws {
        let c = try container()
        let (src, cats) = try seed(c)
        let provider = try c.catalog.categories(sourceID: src.id, kind: .channel, includeHidden: false).map(\.name)
        #expect(provider == ["Folder 0", "Folder 1", "Folder 2", "Folder 3", "Folder 4"])
        let wanted = [cats[3], cats[0], cats[4]].map(\.id)
        try c.catalog.setFolderOrder(wanted)
        let after = try c.catalog.categories(sourceID: src.id, kind: .channel, includeHidden: false).map(\.name)
        #expect(after == ["Folder 3", "Folder 0", "Folder 4", "Folder 1", "Folder 2"], "ordered folders first, the rest keep the provider's order")
        try c.catalog.clearFolderOrder(wanted)
        #expect(try c.catalog.categories(sourceID: src.id, kind: .channel, includeHidden: false).map(\.name) == provider)
    }

    @Test func folderOrderSurvivesAResync() throws {
        let c = try container()
        let (src, cats) = try seed(c)
        try c.catalog.setFolderOrder(cats.reversed().map(\.id))
        let chans = cats.enumerated().flatMap { (i, cat) in (0..<3).map { k -> Channel in var ch = TestSupport.channel(src, "\(i)-\(k)", "Channel \(i)-\(k)", cat: nil, order: i); ch.categoryID = cat.id; ch.categoryName = cat.name; return ch } }
        try c.indexer.commitChannels(source: src, categories: cats, channels: chans)
        #expect(try c.catalog.categories(sourceID: src.id, kind: .channel, includeHidden: false).first?.name == "Folder 4")
    }

    @Test func hidingAFolderRemovesItFromTheSidebarOnly() throws {
        let c = try container()
        let (src, cats) = try seed(c)
        try c.favoritesRepo.hide(cats[1].id, kind: "category")
        #expect(try c.catalog.categories(sourceID: src.id, kind: .channel, includeHidden: false).count == 4)
        #expect(try c.catalog.categories(sourceID: src.id, kind: .channel, includeHidden: true).count == 5, "the folder and its channels are still in the library")
    }

    @Test func editsShowAtOnceAndPersist() async throws {
        let c = try container()
        let (_, _) = try seed(c, folders: 2, perFolder: 4)
        let vm = CommandCenterViewModel()
        await vm.load(c)
        #expect(vm.channels.count == 8 && vm.visible.count == 8)
        let id = vm.channels[0].id
        vm.setHidden(true, ids: [id], c)
        #expect(vm.isHidden(id), "no waiting for the database")
        vm.filter = .hidden
        #expect(vm.visible.map(\.id) == [id])
        vm.filter = .all
        vm.rename(id, to: "My Channel", c)
        vm.search = "my channel"
        #expect(vm.visible.map(\.id) == [id])
        vm.search = ""
        vm.setCategory("Brand New", ids: [id], c)
        #expect(vm.categories.contains("Brand New"))
        await vm.flush()
        #expect(try c.favoritesRepo.hiddenIDs(kind: "channel").contains(id))
        let o = try #require(try c.favoritesRepo.override(for: id))
        #expect(o.displayName == "My Channel" && o.categoryName == "Brand New")
    }

    @Test func largeLibrariesAreShownInPages() async throws {
        let c = try container()
        let (_, _) = try seed(c, folders: 40, perFolder: 50)             // 2,000 channels
        let vm = CommandCenterViewModel()
        await vm.load(c)
        #expect(vm.matchCount == 2000 && vm.visible.count == CommandCenterViewModel.pageSize)
        vm.showMore()
        #expect(vm.visible.count == CommandCenterViewModel.pageSize * 2)
        vm.selectAllMatching()
        #expect(vm.selection.count == 2000 && vm.allMatchingSelected, "selecting all covers every match, not just the visible page")
    }

    @Test func reorderingTheSidebarShowsAtOnceAndIsSaved() async throws {
        let c = try container()
        let (src, cats) = try seed(c, folders: 4, perFolder: 2)
        let state = AppState(container: c, defaults: UserDefaults(suiteName: "reorder-\(UUID().uuidString)")!)
        state.reload()
        for _ in 0..<100 where state.folderEntries(for: .liveTV).isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }     // folders load in the background
        let before = state.folderEntries(for: .liveTV).map(\.title)
        #expect(before == ["Folder 0", "Folder 1", "Folder 2", "Folder 3"])
        let ids = [cats[2], cats[0], cats[3], cats[1]].map { "f:" + $0.id }
        state.reorderFolders(tab: .liveTV, entryIDs: ids)
        #expect(state.folderEntries(for: .liveTV).map(\.title) == ["Folder 2", "Folder 0", "Folder 3", "Folder 1"], "no waiting for the database")
        var saved: [String] = []
        for _ in 0..<100 {
            saved = try c.catalog.categories(sourceID: src.id, kind: .channel, includeHidden: false).map(\.name)
            if saved.first == "Folder 2" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(saved == ["Folder 2", "Folder 0", "Folder 3", "Folder 1"])
    }
}

@Suite("History clearing") @MainActor struct HistoryClearingTests {
    func container() throws -> AppContainer {
        try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-hist-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
    }

    @Test func clearsOnlyWhatEachOptionSays() throws {
        let c = try container()
        let a = UUID(), b = UUID()
        func id(_ s: UUID, _ n: String) -> String { s.uuidString.lowercased() + "|" + n }
        let h = c.historyRepo
        try h.recordPlay(itemID: id(a, "m1"), kind: .movie, title: "A movie")
        try h.recordPlay(itemID: id(a, "c1"), kind: .channel, title: "A channel")
        try h.recordPlay(itemID: id(b, "m2"), kind: .movie, title: "Other playlist movie")
        try h.saveProgress(WatchProgress(itemID: id(a, "m1"), kind: .movie, seriesID: nil, positionSeconds: 30, durationSeconds: 100, updatedAt: Date(), completed: false))
        try h.saveProgress(WatchProgress(itemID: id(b, "m2"), kind: .movie, seriesID: nil, positionSeconds: 30, durationSeconds: 100, updatedAt: Date(), completed: false))
        let prefixA = a.uuidString.lowercased() + "|"

        try h.clearRecent(kind: .channel, sourcePrefix: prefixA)
        #expect(try h.recentIDs(kind: .channel, limit: 10).isEmpty)
        #expect(try h.recentIDs(kind: .movie, limit: 10).count == 2, "movies untouched")
        try h.clearRecent(kind: nil, sourcePrefix: prefixA)
        #expect(try h.recentIDs(kind: .movie, limit: 10) == [id(b, "m2")], "only the viewed playlist is cleared")
        #expect(try h.watchLog(limit: 10).count == 3, "the log is separate from the recent lists")

        let entry = try #require(try h.watchLog(limit: 10).first { $0.itemID == id(a, "m1") })
        try h.removeLogEntry(itemID: entry.itemID, playedAt: entry.playedAt)
        #expect(try h.watchLog(limit: 10).count == 2)
        try h.clearLog(since: Date().addingTimeInterval(-60), sourcePrefix: prefixA)
        #expect(try h.watchLog(limit: 10).map(\.itemID) == [id(b, "m2")])
        try h.clearLog(since: Date().addingTimeInterval(3600), sourcePrefix: nil)
        #expect(try h.watchLog(limit: 10).count == 1, "nothing is newer than an hour from now")

        try h.clearResumePoints(sourcePrefix: prefixA)
        #expect(try h.progress(for: id(a, "m1")) == nil && (try h.progress(for: id(b, "m2"))) != nil)
        try h.removeRecent(itemID: id(b, "m2"))
        #expect(try h.recentIDs(kind: .movie, limit: 10).isEmpty)
    }
}
