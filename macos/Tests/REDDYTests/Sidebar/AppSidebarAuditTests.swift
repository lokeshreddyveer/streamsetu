import Testing
import Foundation
@testable import REDDY

@MainActor @Suite("App sidebar audit") struct AppSidebarAuditTests {
    private func folder(_ id: String, _ title: String = "F") -> SidebarEntry {
        SidebarEntry(id: "f:" + id, selection: .folder(id), title: title, symbol: "folder")
    }

    // MARK: stale selection after folders change

    @Test func aHiddenFolderResetsTheSelectionToTheTabsFirstShortcut() {
        let list = [folder("a"), folder("b")]
        #expect(SidebarModel.selectionAfterReload(.folder("a"), folders: list, tab: .movies) == nil)
        #expect(SidebarModel.selectionAfterReload(.folder("gone"), folders: list, tab: .movies) == AppRouter.defaultSelection(for: .movies))
        #expect(SidebarModel.selectionAfterReload(.shortcut(.favorites), folders: [], tab: .movies) == nil, "shortcuts are never reset")
        let uncategorized = SidebarEntry(id: "f:" + CatalogCategory.uncategorizedID, selection: .folder(CatalogCategory.uncategorizedID), title: "Uncategorized", symbol: "tray", count: 3)
        #expect(SidebarModel.selectionAfterReload(.folder(CatalogCategory.uncategorizedID), folders: [uncategorized], tab: .movies) == nil, "Uncategorized with titles stays")
        #expect(SidebarModel.selectionAfterReload(.folder(CatalogCategory.uncategorizedID), folders: list, tab: .movies) == AppRouter.defaultSelection(for: .movies), "an emptied Uncategorized row is gone, so the selection leaves it")
    }

    @Test func theRouterDropsAFolderThatNoLongerExistsButWaitsForAnUnreadList() {
        let router = AppRouter()
        router.navigate(.movies, .folder("a"))
        router.resetStaleFolderSelections(folders: [.channel: []])          // movies not read yet: left alone
        #expect(router.selection == .folder("a"))
        router.resetStaleFolderSelections(folders: [.movie: [folder("b")]])
        #expect(router.selection == AppRouter.defaultSelection(for: .movies))
        router.navigate(.series, .folder("s"))
        router.resetStaleFolderSelections(folders: [.series: [folder("s")]])
        #expect(router.selection == .folder("s"))
    }

    // MARK: folder menu

    @Test func hideFolderStaysInTheMenuWhileTheFolderSearchHasText() {
        let list = [folder("a"), folder("b"), folder("c")]
        let plan = SidebarModel.folderMenu(for: list[1], in: list, canReorder: false, canHide: true, parentalAvailable: false, canLock: true, lockedIDs: [])
        #expect(plan.hide && !plan.moves && !plan.lock && !plan.unlock)
        let none = SidebarModel.folderMenu(for: list[1], in: list, canReorder: false, canHide: false, parentalAvailable: false, canLock: false, lockedIDs: [])
        #expect(none.isEmpty)
    }

    @Test func uncategorizedHasNoMenuAtAll() {
        let u = SidebarEntry(id: "f:" + CatalogCategory.uncategorizedID, selection: .folder(CatalogCategory.uncategorizedID), title: "Uncategorized", symbol: "tray")
        let plan = SidebarModel.folderMenu(for: u, in: [folder("a"), u], canReorder: true, canHide: true, parentalAvailable: true, canLock: true, lockedIDs: [])
        #expect(plan.isEmpty)
    }

    @Test func firstCannotMoveUpAndLastCannotMoveDownAndLockFollowsTheState() {
        let u = SidebarEntry(id: "f:" + CatalogCategory.uncategorizedID, selection: .folder(CatalogCategory.uncategorizedID), title: "Uncategorized", symbol: "tray")
        let list = [folder("a"), folder("b"), folder("c"), u]
        let first = SidebarModel.folderMenu(for: list[0], in: list, canReorder: true, canHide: true, parentalAvailable: true, canLock: true, lockedIDs: [])
        #expect(first.moves && !first.moveUp && first.moveDown && first.lock && !first.unlock)
        let last = SidebarModel.folderMenu(for: list[2], in: list, canReorder: true, canHide: true, parentalAvailable: true, canLock: true, lockedIDs: ["c"])
        #expect(last.moveUp && !last.moveDown && last.unlock && !last.lock, "Uncategorized does not count as a place below")
    }

    // MARK: drag end

    @Test func aDragIsOverWhenThePrimaryButtonIsUp() {
        #expect(SidebarModel.dragHasEnded(pressedButtons: 0))
        #expect(SidebarModel.dragHasEnded(pressedButtons: 2), "only the right button is down")
        #expect(!SidebarModel.dragHasEnded(pressedButtons: 1))
        #expect(!SidebarModel.dragHasEnded(pressedButtons: 3))
    }

    @Test func aFolderDragIsNotText() {
        let p = SidebarFolderDrag.provider(for: "f:x")
        #expect(SidebarFolderDrag.isFolder(p))
        #expect(!p.hasItemConformingToTypeIdentifier("public.utf8-plain-text"))
        #expect(!SidebarFolderDrag.isFolder(NSItemProvider(object: "https://example.com/list.m3u" as NSString)))
    }

    // MARK: titles, filter, icons

    @Test func appWordingIsTranslatedButAProviderFolderNeverIs() {
        let pinned = SidebarModel.pinned(for: .movies)
        let allLocalized = pinned.allSatisfy { $0.titleIsLocalized }
        #expect(allLocalized)
        let provider = folder("t", "Tonight")
        #expect(!provider.titleIsLocalized && provider.displayTitle == "Tonight")
    }

    @Test func filteringTwiceGivesTheSameAnswerAndFollowsTheQuery() {
        let list = [folder("a", "Sports HD"), folder("b", "News"), folder("c", "Sports 4K")]
        let first = SidebarModel.filter(list, query: "sports").map(\.id)
        #expect(first == SidebarModel.filter(list, query: "sports").map(\.id))
        #expect(SidebarModel.filter(list, query: "news").map(\.id) == ["f:b"])
        #expect(SidebarModel.filter(Array(list.prefix(2)), query: "sports").map(\.id) == ["f:a"], "a different list is not served from the old answer")
    }

    @Test func aRuleWordWithTrailingSpaceMatchesAtTheEndOfAName() {
        #expect(FolderIcons.symbol(for: "US") == "globe.americas")
        #expect(FolderIcons.symbol(for: "US East") == "globe.americas")
        #expect(FolderIcons.symbol(for: "Business") == "folder")
        #expect(FolderIcons.symbol(for: "Plus Max") == "folder")
    }

    // MARK: assistant reach

    @Test func everySidebarShortcutHasADestinationInOpenScreen() {
        #expect(AssistantCoverage.shortcutsNotOffered.isEmpty)
        let names = Set(CommandTarget.allCases.map(\.rawValue))
        for s in [Shortcut.featured, .recentlyAdded, .unwatched, .unwatchedFavorites, .addedThisMonth, .newEpisodes] { #expect(names.contains(s.rawValue), "\(s)") }
        #expect(CommandTarget.downloads.title == "Downloads" && CommandTarget.settings.title == "Settings")
    }
}
