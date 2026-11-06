import Testing
import Foundation
@testable import REDDY

/// Two devices and a stand-in for the iCloud zone, with the same order of events as `CloudKitSync`: turning sync on queues everything, then a cycle fetches what the zone holds and
/// sends what is queued; a record someone else wrote first comes back as a conflict, the other side's row is merged, and ours is sent again only if it is the later one.
/// Throwaway databases only; nothing here touches iCloud, the Keychain or real data.
@Suite("iCloud sync: two devices, one zone") struct CloudSyncTwoDeviceTests {
    typealias Device = CloudSyncCoreTests.Device

    /// The zone: one record per name, a version counter, and last-save-wins unless the sender had not seen the latest version.
    final class Zone {
        private(set) var records: [String: SyncRow] = [:]
        private var versions: [String: Int] = [:]
        private var log: [(name: String, version: Int)] = []
        private var counter = 0

        func fetch(after token: Int) -> (rows: [SyncRow], token: Int) {
            var seen = Set<String>(); var rows: [SyncRow] = []
            for entry in log where entry.version > token && seen.insert(entry.name).inserted { if let r = records[entry.name] { rows.append(r) } }
            return (rows, counter)
        }
        func version(of name: String) -> Int { versions[name] ?? 0 }
        enum Saved { case saved(Int), conflict(SyncRow, Int) }
        func save(_ row: SyncRow, knownVersion: Int) -> Saved {
            if let current = records[row.recordName], version(of: row.recordName) != knownVersion { return .conflict(current, version(of: row.recordName)) }
            counter += 1; records[row.recordName] = row; versions[row.recordName] = counter; log.append((row.recordName, counter))
            return .saved(counter)
        }
    }

    struct Client {
        let device: Device
        var token = 0
        var known: [String: Int] = [:]
        init(_ d: Device) { device = d }
    }

    /// `CloudKitSync.start()` then the first cycles: queue everything, fetch, send.
    func start(_ c: inout Client, _ zone: Zone) throws {
        try c.device.core.enqueueEverything()
        try cycle(&c, zone)
    }

    /// One `syncNow()`: fetch and merge, then send until nothing is queued.
    func cycle(_ c: inout Client, _ zone: Zone) throws {
        let fetched = zone.fetch(after: c.token); c.token = fetched.token
        for r in fetched.rows { c.known[r.recordName] = zone.version(of: r.recordName) }
        if !fetched.rows.isEmpty { try c.device.core.apply(fetched.rows) }
        for _ in 0..<6 {
            let pending = try c.device.core.pending()
            if pending.isEmpty { break }
            let rows = try c.device.core.rows(for: pending)
            var delivered: [SyncRow] = []
            for r in rows {
                switch zone.save(r, knownVersion: c.known[r.recordName] ?? 0) {
                case .saved(let v): c.known[r.recordName] = v; delivered.append(r)
                case .conflict(let theirs, let v):
                    c.known[r.recordName] = v
                    try c.device.core.apply([theirs])           // if ours is later, it stays queued and goes round again
                }
            }
            try c.device.core.markPushed(delivered)
        }
    }

    // MARK: helpers

    func seedProgress(_ d: Device, _ item: String, position: Double, updatedAt: Double, existedBeforeSync: Bool) throws {
        try d.db.write { c in
            try c.execute("INSERT OR REPLACE INTO watch_progress(item_id, kind, series_id, position_seconds, duration_seconds, updated_at, completed) VALUES(?, 'movie', NULL, ?, 6000, ?, 0)", [item, position, updatedAt])
            if existedBeforeSync { try c.execute("DELETE FROM sync_outbox") }          // rows from before the change log existed have no queued time
        }
    }
    func seedFavorite(_ d: Device, _ item: String, createdAt: Double, existedBeforeSync: Bool) throws {
        try d.db.write { c in
            try c.execute("INSERT OR REPLACE INTO favorites(item_id, kind, created_at, sort_order) VALUES(?, 'movie', ?, 0)", [item, createdAt])
            if existedBeforeSync { try c.execute("DELETE FROM sync_outbox") }
        }
    }
    func position(_ d: Device, _ item: String) throws -> Double? { try d.db.read { try $0.queryOne("SELECT position_seconds FROM watch_progress WHERE item_id = ?", [item]) { $0.double(0) } } }
    func hasFavorite(_ d: Device, _ item: String) throws -> Bool { try d.db.read { try $0.scalarInt("SELECT COUNT(*) FROM favorites WHERE item_id = ?", [item]) > 0 } }

    // MARK: turning sync on

    @Test func aSecondDeviceTurningSyncOnDoesNotOverwriteNewerDataWithItsOldRows() throws {
        let zone = Zone()
        let a = try Device(), b = try Device()
        var ca = Client(a), cb = Client(b)
        try seedProgress(a, "m-1", position: 900, updatedAt: 5_000, existedBeforeSync: false)      // A changed it just now
        try start(&ca, zone)
        Thread.sleep(forTimeInterval: 0.05)
        try seedProgress(b, "m-1", position: 100, updatedAt: 1_000, existedBeforeSync: true)       // B's copy is old, from before it ever synced
        try start(&cb, zone)
        try cycle(&ca, zone)
        #expect(try position(b, "m-1") == 900, "the newer position must reach the device that was switched on later")
        #expect(try position(a, "m-1") == 900, "the old row of the later device must not travel back and replace the newer one")
        #expect(try zone.records.values.filter { $0.table == "watch_progress" }.count == 1)
    }

    @Test func aRowThatReallyIsNewerOnTheLaterDeviceStillWins() throws {
        let zone = Zone()
        let a = try Device(), b = try Device()
        var ca = Client(a), cb = Client(b)
        try seedProgress(a, "m-1", position: 900, updatedAt: 5_000, existedBeforeSync: false)
        try start(&ca, zone)
        Thread.sleep(forTimeInterval: 0.05)
        try seedProgress(b, "m-1", position: 4000, updatedAt: 9_000, existedBeforeSync: false)      // changed on B after A's change, with the change log running
        try start(&cb, zone)
        try cycle(&ca, zone)
        #expect(try position(a, "m-1") == 4000)
        #expect(try position(b, "m-1") == 4000)
    }

    @Test func aDeletionMadeElsewhereIsNotUndoneByADeviceThatStillHasTheRow() throws {
        let zone = Zone()
        let a = try Device(), b = try Device()
        var ca = Client(a), cb = Client(b)
        try seedFavorite(a, "m-9", createdAt: 1_000, existedBeforeSync: false)
        try start(&ca, zone)
        Thread.sleep(forTimeInterval: 0.05)
        try a.db.write { try $0.execute("DELETE FROM favorites WHERE item_id = 'm-9'") }            // A removes it: a deletion goes to the zone
        try cycle(&ca, zone)
        Thread.sleep(forTimeInterval: 0.05)
        try seedFavorite(b, "m-9", createdAt: 1_000, existedBeforeSync: true)                        // B still has the favourite from long ago
        try start(&cb, zone)
        try cycle(&ca, zone)
        #expect(try !hasFavorite(b, "m-9"), "the deletion happened after B's favourite was made, so it wins")
        #expect(try !hasFavorite(a, "m-9"), "the old favourite must not come back on the device that deleted it")
    }

    @Test func rowsOnlyOneDeviceHasAreKeptAndSharedBetweenThem() throws {
        let zone = Zone()
        let a = try Device(), b = try Device()
        var ca = Client(a), cb = Client(b)
        try seedProgress(a, "only-a", position: 10, updatedAt: 100, existedBeforeSync: true)
        try seedProgress(b, "only-b", position: 20, updatedAt: 200, existedBeforeSync: true)
        try start(&ca, zone); try start(&cb, zone); try cycle(&ca, zone)
        #expect(try position(a, "only-b") == 20)
        #expect(try position(b, "only-a") == 10)
    }

    // MARK: one bad record

    @Test func oneRecordThatCannotBeAppliedDoesNotLoseTheOthersInItsBatch() throws {
        let b = try Device()
        let good = SyncRow(table: "favorites", key: try SyncCore.jsonArray(["m-1"]), values: #"{"kind":"movie","created_at":100,"sort_order":0}"#, modified: 500)
        // A source record from a newer app: the name it should carry is missing, which the table does not allow.
        let bad = SyncRow(table: "sources", key: try SyncCore.jsonArray(["src-x"]), values: #"{"type":"xtream"}"#, modified: 500)
        let alsoGood = SyncRow(table: "favorites", key: try SyncCore.jsonArray(["m-2"]), values: #"{"kind":"movie","created_at":100,"sort_order":0}"#, modified: 500)
        let result = try b.core.apply([good, bad, alsoGood])
        #expect(try hasFavorite(b, "m-1") && hasFavorite(b, "m-2"), "the rows around the bad one must still be applied")
        #expect(result.applied == 2)
        #expect(result.failed == 1)
    }

    @Test func aRecordThatFailedIsKeptAndAppliedWhenItCanBe() throws {
        let b = try Device()
        let key = try SyncCore.jsonArray(["src-late"])
        let incomplete = SyncRow(table: "sources", key: key, values: #"{"type":"xtream"}"#, modified: 500)
        _ = try b.core.apply([incomplete])
        #expect(try b.core.quarantinedCount() == 1, "a record that could not be applied is not thrown away")
        // The same row arrives again complete (an update of the app or of the other device): it is applied and the held copy is dropped.
        let complete = SyncRow(table: "sources", key: key, values: #"{"name":"Late","type":"xtream","base_url":"http://x","credential_ref":"r","epg_url":null,"enabled":1,"created_at":1,"sort_order":0}"#, modified: 600)
        let result = try b.core.apply([complete])
        #expect(result.applied == 1)
        #expect(try b.core.quarantinedCount() == 0)
    }
}
