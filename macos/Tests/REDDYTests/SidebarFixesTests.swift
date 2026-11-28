import Testing
import Foundation
@testable import REDDY

@Suite("Sidebar fixes: folders, search, order, router") @MainActor struct SidebarFixesTests {
    private func cat(_ name: String, count: Int, locked: Bool = false) -> CatalogCategory {
        CatalogCategory(id: "c-" + name, sourceID: UUID(), kind: .movie, providerID: name, name: name, sortOrder: 0, itemCount: count, isLocked: locked)
    }

    @Test func aLockedFolderStaysListedWhenEmptyFoldersAreHidden() {
        let rows = SidebarModel.folders([cat("Open", count: 3), cat("Hidden", count: 0), cat("Locked", count: 0, locked: true)], hideEmpty: true)
        #expect(rows.map(\.title) == ["Open", "Locked"])
    }

    @Test func theFolderSearchDoesNotApplyWhileCollapsed() {
        #expect(SidebarModel.appliedQuery("tel", collapsed: true) == "")
        #expect(SidebarModel.appliedQuery("tel", collapsed: false) == "tel")
    }

    @Test func aDropThatMovedNothingSavesNoOrder() {
        let a = SidebarEntry(id: "f:a", selection: .folder("a"), title: "A", symbol: "folder")
        let b = SidebarEntry(id: "f:b", selection: .folder("b"), title: "B", symbol: "folder")
        #expect(SidebarModel.changedOrder([a, b], saved: [a, b]) == nil)
        #expect(SidebarModel.changedOrder(nil, saved: [a, b]) == nil)
        #expect(SidebarModel.changedOrder([b, a], saved: [a, b]) == ["f:b", "f:a"])
    }

    @Test func aSelectedFolderHiddenBySearchIsRevealedByClearingIt() {
        let a = SidebarEntry(id: "f:a", selection: .folder("a"), title: "Alpha", symbol: "folder")
        let b = SidebarEntry(id: "f:b", selection: .folder("b"), title: "Beta", symbol: "folder")
        let hidden = SidebarModel.reveal(.folder("b"), in: [a, b], query: "alp")
        #expect(hidden?.rowID == "f:b" && hidden?.clearsSearch == true)
        let shown = SidebarModel.reveal(.folder("a"), in: [a, b], query: "alp")
        #expect(shown?.clearsSearch == false)
        #expect(SidebarModel.reveal(.folder("zzz"), in: [a, b], query: "") == nil)
    }

    @Test func sciFiGetsTheSciFiIconNotTheScienceOne() {
        #expect(FolderIcons.symbol(for: "Sci-Fi") == FolderIcons.symbol(for: "Science Fiction"))
        #expect(FolderIcons.symbol(for: "Sci-Fi") != FolderIcons.symbol(for: "Science"))
    }

    @Test func aSidebarChoiceEndsASearchEvenOnTheSelectedRow() {
        let r = AppRouter()
        r.searchQuery = "abc"
        r.select(r.selection)
        #expect(!r.isSearching && r.searchQuery.isEmpty)
    }

    @Test func wordsSetRightAfterNavigatingStayForTheScreen() {
        let r = AppRouter()
        r.searchQuery = "old"
        r.navigate(.series)
        r.searchQuery = "Name"
        #expect(r.isSearching && r.searchQuery == "Name")
    }

    @Test func aScreenQueryIsTakenOnlyByItsOwnScreenAndOnce() {
        let r = AppRouter()
        r.screenQuery = ScreenQuery(tab: .liveTV, words: "telugu channels")
        #expect(r.takeScreenQuery(for: .movies) == nil)
        #expect(r.takeScreenQuery(for: .liveTV) == "telugu channels")
        #expect(r.takeScreenQuery(for: .liveTV) == nil)
    }

    @Test func settingsCannotBeReportedOpenWithoutAnOpener() {
        let n = AtlasNavRequests.shared
        let saved = n.settingsOpener
        defer { n.settingsOpener = saved }
        n.settingsOpener = nil
        #expect(!n.showSettings(tab: nil))
        let opened = OpenCounter()
        n.settingsOpener = { opened.count += 1 }
        let ok = n.showSettings(tab: nil)
        #expect(ok && opened.count == 1)
    }
}

private final class OpenCounter { var count = 0 }
