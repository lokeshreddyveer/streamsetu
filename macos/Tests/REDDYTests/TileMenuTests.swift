import Testing
import Foundation
@testable import REDDY

@Suite("Shared tile menu") struct TileMenuTests {
    private func actions(_ f: TileMenu.Facts) -> [TileMenu.Action] { TileMenu.entries(f).map(\.action) }

    @Test func menuContentsPerTileType() {
        typealias A = TileMenu.Action
        func facts(_ k: TileMenu.Kind, fav: Bool = false, later: Bool = false, queued: Bool = false, folder: String? = nil, cast: Bool = false, multi: Bool = false) -> TileMenu.Facts {
            var f = TileMenu.Facts(kind: k); f.isFavorite = fav; f.isWatchLater = later; f.inQueue = queued; f.folderName = folder; f.hasCast = cast; f.canMultiView = multi; return f
        }
        let table: [(String, TileMenu.Facts, [A])] = [
            ("title, plain", facts(.title), [.play, .watchPrivately, .openDetails, .favorite, .watchLater, .collection, .playNext, .addToQueue, .dontRecommend, .share, .hide]),
            ("title with folder and cast", facts(.title, folder: "Telugu", cast: true), [.play, .watchPrivately, .openDetails, .openFolder, .goToCast, .favorite, .watchLater, .collection, .playNext, .addToQueue, .dontRecommend, .share, .hide]),
            ("favourite in the queue", facts(.title, fav: true, queued: true), [.play, .watchPrivately, .openDetails, .favorite, .watchLater, .moveToFront, .moveToEnd, .collection, .removeFromQueue, .dontRecommend, .share, .hide]),
            ("continue watching", facts(.continueWatching, folder: "Hindi"), [.resume, .watchPrivately, .openDetails, .openFolder, .favorite, .watchLater, .collection, .playNext, .addToQueue, .dontRecommend, .share, .hide, .removeFromContinue]),
            ("channel", facts(.channel, multi: true), [.play, .watchPrivately, .favorite, .collection, .share, .multiView, .hideChannel]),
        ]
        for (name, f, expected) in table { #expect(actions(f) == expected, "\(name): \(actions(f).map(\.rawValue))") }
    }

    @Test func noDuplicatesAndDestructiveItemsComeLast() {
        for kind in [TileMenu.Kind.title, .continueWatching, .channel] {
            var f = TileMenu.Facts(kind: kind); f.folderName = "X"; f.hasCast = true; f.isFavorite = true; f.canMultiView = true
            let e = TileMenu.entries(f)
            #expect(Set(e.map(\.action)).count == e.count && Set(e.map(\.title)).count == e.count, "\(kind): no item twice")
            let firstDestructive = e.firstIndex { $0.destructive } ?? e.count
            let tail = e[firstDestructive...].map(\.destructive)
            #expect(!tail.contains(false), "\(kind): destructive items are last")
            if let share = e.firstIndex(where: { $0.action == .share }) { #expect(share < firstDestructive) }
            #expect([.play, .resume].contains(e[0].action), "play or resume first")
        }
    }

    @Test func continueWatchingOffersRemovalLastAndNoInventedWatchedAction() {
        let f = TileMenu.Facts(kind: .continueWatching)
        #expect(TileMenu.entries(f).last?.action == .removeFromContinue)
        #expect(!TileMenu.Action.allCases.map(\.rawValue).contains { $0.lowercased().contains("watched") }, "no Mark as Watched: it would write history")
    }

    @Test func everyEntryReachesVoiceOverExceptTheOnesTheSystemDraws() throws {
        // The menu and the VoiceOver actions both come from TileMenu.entries; only the submenu and the share sheet are left to the system.
        let f = TileMenu.Facts(kind: .title)
        let system = TileMenu.entries(f).filter(\.isSystemControl).map(\.action)
        #expect(Set(system) == [.collection, .share])
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/REDDY/Features/Shared/TileMenu.swift"), encoding: .utf8)
        #expect(src.contains(".accessibilityActions") && src.contains("filter { !$0.isSystemControl }") && src.contains(".contextMenu { TileMenuContent"))
    }

    @Test func everyTileSurfaceUsesTheSharedBuilder() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for f in ["macos/Sources/REDDY/Features/Home/Views/HomeScreen.swift", "macos/Sources/REDDY/Features/Movies/Views/LibraryScreen.swift", "ios/StreamSetu/Screens/HomeView.swift", "ios/StreamSetu/Screens/LibraryView.swift", "ios/StreamSetu/Screens/FolderRowsView.swift"] {
            let t = try String(contentsOf: root.appendingPathComponent(f), encoding: .utf8)
            #expect(!t.contains("Button(\"Don't Recommend This\""), "\(f) builds no menu by hand")
            #expect(t.contains("tileMenu") || t.contains("TileMenu") || t.contains("TileMenu("), "\(f) uses the shared menu")
        }
    }

    // MARK: marker-only writes

    private func progress(_ id: String, series: String? = nil, at: Date) -> WatchProgress {
        WatchProgress(itemID: id, kind: series == nil ? .movie : .episode, seriesID: series, positionSeconds: 600, durationSeconds: 6000, updatedAt: at, completed: false)
    }

    @Test func removingFromContinueWatchingWritesOnlyTheMarkerAndUndoRestores() throws {
        let db = try TestSupport.makeDB()
        let repo = SQLiteHistoryRepository(db: db)
        let t0 = Date().addingTimeInterval(-1000)
        try repo.saveProgress(progress("m1", at: t0)); try repo.saveProgress(progress("m2", at: t0))
        try repo.recordPlay(itemID: "m1", kind: .movie, title: "One")
        func snapshot() throws -> [String] {
            try db.read { c in
                try c.query("SELECT item_id, kind, IFNULL(series_id,''), position_seconds, duration_seconds, updated_at, completed FROM watch_progress ORDER BY item_id", []) { "\($0.string(0))|\($0.string(1))|\($0.string(2))|\($0.double(3))|\($0.double(4))|\($0.double(5))|\($0.int(6))" }
                + (try c.query("SELECT item_id, played_at FROM watch_history ORDER BY id", []) { "\($0.string(0))|\($0.double(1))" })
                + (try c.query("SELECT item_id, play_count FROM recently_watched", []) { "\($0.string(0))|\($0.int(1))" })
            }
        }
        let before = try snapshot()
        #expect(try repo.continueWatching(limit: 10).count == 2)
        try repo.hideFromContinue(itemID: "m1")
        #expect(try repo.continueWatching(limit: 10).map(\.itemID) == ["m2"])
        #expect(try snapshot() == before, "progress, resume position, watched state and history are byte-identical")
        try repo.showInContinue(itemID: "m1")
        #expect(try repo.continueWatching(limit: 10).count == 2, "undo restores")
        try repo.hideFromContinue(itemID: "m1")
        try repo.saveProgress(progress("m1", at: Date().addingTimeInterval(5)))
        #expect(try repo.continueWatching(limit: 10).map(\.itemID).contains("m1"), "playing it again brings it back")
    }

    @Test func hidingAnEpisodeHidesTheSeriesEntryAndUndoRestoresIt() throws {
        let db = try TestSupport.makeDB()
        let repo = SQLiteHistoryRepository(db: db)
        let t0 = Date().addingTimeInterval(-1000)
        try repo.saveProgress(progress("e1", series: "s1", at: t0)); try repo.saveProgress(progress("e2", series: "s1", at: t0.addingTimeInterval(10)))
        #expect(try repo.continueWatching(limit: 10).map(\.itemID) == ["e2"])
        try repo.hideFromContinue(itemID: "e2")
        #expect(try repo.continueWatching(limit: 10).isEmpty, "an older episode of the same series does not stand in")
        try repo.showInContinue(itemID: "e2")
        #expect(try repo.continueWatching(limit: 10).map(\.itemID) == ["e2"])
    }

    @Test @MainActor func theMarkerTravelsWithTheProfileAndIsClearedByAReset() {
        #expect(ProfileService.personalTables.contains("continue_hidden") && DatabaseRecovery.personalTables.contains("continue_hidden"))
    }

    @Test func hidingATitleIsUndoneByUnhide() throws {
        let db = try TestSupport.makeDB()
        let repo = SQLiteFavoritesRepository(db: db)
        try repo.hide("movie-1", kind: "movie")
        #expect(try repo.hiddenIDs(kind: "movie") == ["movie-1"])
        try repo.unhide("movie-1")
        #expect(try repo.hiddenIDs(kind: "movie").isEmpty)
    }
}
