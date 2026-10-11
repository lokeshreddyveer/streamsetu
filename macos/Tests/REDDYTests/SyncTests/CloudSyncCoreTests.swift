import Testing
import Foundation
@testable import REDDY

/// Two "devices" (two databases) exchanging rows the way iCloud would, without iCloud.
@Suite("iCloud sync: changes and merging") struct CloudSyncCoreTests {
    struct Device {
        let db: DatabaseManager
        let core: SyncCore
        let favorites: SQLiteFavoritesRepository
        let history: SQLiteHistoryRepository
        let catalog: SQLiteCatalogRepository
        init(defaults: UserDefaults? = nil) throws {
            let database = try TestSupport.makeDB()
            db = database
            favorites = SQLiteFavoritesRepository(db: database); history = SQLiteHistoryRepository(db: database); catalog = SQLiteCatalogRepository(db: database)
            core = SyncCore(db: database, settings: defaults.map { DefaultsSettingsSync(defaults: $0, db: database) })
        }
    }

    /// What one device would send and the other would receive.
    @discardableResult
    func ship(_ a: Device, to b: Device) throws -> SyncApplyResult {
        let pending = try a.core.pending()
        let rows = try a.core.rows(for: pending)
        let result = try b.core.apply(rows)
        try a.core.markPushed(rows)
        return result
    }

    @Test func favouritesAndCollectionsArriveOnTheOtherDevice() throws {
        let a = try Device(), b = try Device()
        try a.favorites.setFavorite("ch-1", kind: .channel, on: true)
        let col = try a.favorites.createCollection(name: "Football")
        try a.favorites.add(itemID: "ch-1", kind: .channel, toCollection: col.id)
        try ship(a, to: b)
        #expect(try b.favorites.favoriteIDs(kind: .channel) == ["ch-1"])
        let cols = try b.favorites.collections()
        #expect(cols.map(\.name) == ["Football"])
        #expect(try b.favorites.collectionItems(id: col.id).map(\.itemID) == ["ch-1"])
    }

    @Test func aChangeThatArrivedIsNotSentBack() throws {
        let a = try Device(), b = try Device()
        try a.favorites.setFavorite("m-1", kind: .movie, on: true)
        try ship(a, to: b)
        #expect(try b.core.pending().isEmpty, "applying remote changes must not queue them again")
        #expect(try a.core.pending().isEmpty, "delivered changes leave the queue")
    }

    @Test func deletionsTravelToo() throws {
        let a = try Device(), b = try Device()
        try a.favorites.setFavorite("m-1", kind: .movie, on: true)
        try ship(a, to: b)
        Thread.sleep(forTimeInterval: 0.02)                                         // timestamps have millisecond resolution
        try a.favorites.setFavorite("m-1", kind: .movie, on: false)
        try ship(a, to: b)
        #expect(try b.favorites.favoriteIDs(kind: .movie).isEmpty)
        let col = try a.favorites.createCollection(name: "Temp")
        try ship(a, to: b)
        Thread.sleep(forTimeInterval: 0.02)
        try a.favorites.deleteCollection(id: col.id)
        try ship(a, to: b)
        #expect(try b.favorites.collections().isEmpty)
    }

    @Test func theLaterChangeWinsAndAnOlderOneIsIgnored() throws {
        let b = try Device()
        let key = try SyncCore.jsonArray(["m-1"])
        let newer = SyncRow(table: "watch_progress", key: key, values: #"{"kind":"movie","series_id":null,"position_seconds":900,"duration_seconds":6000,"updated_at":2000,"completed":0}"#, modified: 2_000)
        let older = SyncRow(table: "watch_progress", key: key, values: #"{"kind":"movie","series_id":null,"position_seconds":10,"duration_seconds":6000,"updated_at":1000,"completed":0}"#, modified: 1_000)
        try b.core.apply([newer])
        let result = try b.core.apply([older])
        #expect(result.applied == 0 && result.skipped == 1)
        #expect(try b.history.progress(for: "m-1")?.positionSeconds == 900)
        let newest = SyncRow(table: "watch_progress", key: key, values: newer.values!.replacingOccurrences(of: "900", with: "1500"), modified: 3_000)
        try b.core.apply([newest])
        #expect(try b.history.progress(for: "m-1")?.positionSeconds == 1500)
    }

    @Test func aLocalChangeNotYetSentBeatsAnOlderRemoteOne() throws {
        let b = try Device()
        try b.favorites.setFavorite("m-1", kind: .movie, on: true)                 // queued here, just now
        let key = try SyncCore.jsonArray(["m-1"])
        let result = try b.core.apply([SyncRow(table: "favorites", key: key, values: nil, modified: 1)])      // someone removed it long ago
        #expect(result.applied == 0)
        #expect(try b.favorites.favoriteIDs(kind: .movie) == ["m-1"])
    }

    @Test func theWatchLogHasNoDuplicatesWhateverTheOrder() throws {
        let a = try Device(), b = try Device()
        try a.history.recordPlay(itemID: "m-1", kind: .movie, title: "Film")
        let rows = try a.core.rows(for: try a.core.pending()).filter { $0.table == "watch_history" }
        #expect(rows.count == 1)
        try b.core.apply(rows)
        try b.core.apply(rows.map { var r = $0; r.modified += 1; return r })        // the same play delivered again, as newer
        let count = try b.db.read { try $0.scalarInt("SELECT COUNT(*) FROM watch_history") }
        #expect(count == 1)
    }

    @Test func aPlaylistArrivesWithoutItsDeviceOnlyStatus() throws {
        let a = try Device(), b = try Device()
        let src = try TestSupport.makeSource(a.db, name: "Home")
        try ship(a, to: b)
        let got = try #require(try b.catalog.source(id: src.id))
        #expect(got.name == "Home" && got.type == src.type && got.baseURL == src.baseURL)
        // a refresh on A changes only device-local columns: nothing to send
        try a.catalog.updateSyncStatus(sourceID: src.id, status: "completed", lastSync: Date())
        #expect(try a.core.pending().isEmpty)
        try a.catalog.setEnabled(false, sourceID: src.id)
        try ship(a, to: b)
        #expect(try b.catalog.source(id: src.id)?.enabled == false)
        let storedID = try b.db.read { try $0.queryOne("SELECT id FROM sources") { $0.string(0) } } ?? ""
        let removed = try SyncCore.jsonArray([storedID])
        let res = try b.core.apply([SyncRow(table: "sources", key: removed, values: nil, modified: Date().timeIntervalSince1970 + 100)])
        let gone = try b.catalog.source(id: src.id)
        #expect(res.removedSources == [storedID] && gone == nil)
    }

    @Test func anItemInACollectionThatHasNotArrivedYetIsKept() throws {
        let b = try Device()
        let item = SyncRow(table: "collection_items", key: try SyncCore.jsonArray(["col-9", "ch-1"]), values: #"{"kind":"channel","sort_order":0,"added_at":1}"#, modified: 10)
        try b.core.apply([item])
        let col = SyncRow(table: "collections", key: try SyncCore.jsonArray(["col-9"]), values: #"{"name":"Late","created_at":1}"#, modified: 11)
        try b.core.apply([col])
        #expect(try b.favorites.collections().first?.name == "Late")
        #expect(try b.favorites.collectionItems(id: "col-9").map(\.itemID) == ["ch-1"])
    }

    @Test func existingDataIsQueuedWhenSyncIsFirstSwitchedOn() throws {
        let a = try Device()
        try a.favorites.setFavorite("m-1", kind: .movie, on: true)
        try a.core.markPushed(try a.core.rows(for: try a.core.pending()))          // pretend it was sent
        try a.db.write { try $0.execute("DELETE FROM sync_meta") }                  // ...but the record of it is lost
        try a.core.enqueueEverything()
        #expect(try a.core.pending().contains { $0.table == "favorites" })
    }

    @Test func settingsTravelButOnlyTheOnesOnTheList() throws {
        let da = UserDefaults(suiteName: "sync-a-\(UUID().uuidString)")!, dbb = UserDefaults(suiteName: "sync-b-\(UUID().uuidString)")!
        let a = try Device(defaults: da), b = try Device(defaults: dbb)
        da.set("Dracula", forKey: "settings.theme"); da.set(true, forKey: "settings.autoresume"); da.set(45, forKey: "playlist.\(UUID().uuidString.lowercased()).guideshift")
        da.set("secret", forKey: "parental.pinhash"); da.set("x", forKey: "somethingelse")
        try a.core.detectSettingsChanges()
        try ship(a, to: b)
        #expect(dbb.string(forKey: "settings.theme") == "Dracula" && dbb.bool(forKey: "settings.autoresume"))
        #expect(dbb.object(forKey: "parental.pinhash") == nil && dbb.object(forKey: "somethingelse") == nil)
        // a hostile record naming a key that is not on the list is ignored
        let evil = SyncRow(table: "settings", key: try SyncCore.jsonArray(["parental.pinhash"]), values: #"{"t":"s","v":"0000"}"#, modified: 9_999_999_999)
        try b.core.apply([evil])
        #expect(dbb.object(forKey: "parental.pinhash") == nil)
        // unchanged settings are not sent again
        try a.core.detectSettingsChanges()
        #expect(try a.core.pending().isEmpty)
        da.set("Nord", forKey: "settings.theme")
        try a.core.detectSettingsChanges()
        #expect(try a.core.pending().count == 1)
    }
}
