import Testing
import Foundation
@testable import REDDY

@MainActor @Suite struct ProfileTests {
    private func count(_ db: DatabaseManager, _ t: String) throws -> Int { try db.read { try $0.queryOne("SELECT COUNT(*) FROM \(t)", []) { $0.int(0) } } ?? 0 }

    @Test func eachProfileKeepsItsOwnFavouritesAndProgress() throws {
        let db = try TestSupport.makeDB()
        let service = ProfileService(db: db)
        try db.write { c in
            try c.execute("INSERT INTO favorites(item_id, kind, created_at, sort_order) VALUES('x|movie|1', 'movie', 1, 0)")
            try c.execute("INSERT INTO watch_progress(item_id, kind, position_seconds, duration_seconds, updated_at, completed) VALUES('x|movie|1', 'movie', 60, 600, 1, 0)")
        }
        let kid = try #require(service.add(name: "Anya", kind: .adult, pin: nil))
        #expect(service.switchTo(kid.id) == .switched)
        #expect(try count(db, "favorites") == 0 && count(db, "watch_progress") == 0)
        try db.write { try $0.execute("INSERT INTO favorites(item_id, kind, created_at, sort_order) VALUES('x|movie|2', 'movie', 2, 0)") }
        #expect(service.switchTo(ProfileService.mainID) == .switched)
        #expect(try count(db, "favorites") == 1 && count(db, "watch_progress") == 1)
        let ids: [String] = try db.read { try $0.query("SELECT item_id FROM favorites", []) { $0.string(0) } }
        #expect(ids == ["x|movie|1"])
        #expect(service.switchTo(kid.id) == .switched)
        #expect(try count(db, "favorites") == 1)
    }

    @Test func switchingIsNotLoggedAsDeletionsForSync() throws {
        let db = try TestSupport.makeDB()
        let service = ProfileService(db: db)
        try db.write { try $0.execute("INSERT INTO favorites(item_id, kind, created_at, sort_order) VALUES('x|movie|1', 'movie', 1, 0)") }
        let before = try db.read { try $0.queryOne("SELECT COUNT(*) FROM lan_log WHERE deleted = 1", []) { $0.int(0) } } ?? 0
        let other = try #require(service.add(name: "B", kind: .adult, pin: nil))
        _ = service.switchTo(other.id)
        let after = try db.read { try $0.queryOne("SELECT COUNT(*) FROM lan_log WHERE deleted = 1", []) { $0.int(0) } } ?? 0
        #expect(before == after)
        let outbox = try db.read { try $0.queryOne("SELECT COUNT(*) FROM sync_outbox WHERE tbl = 'favorites' AND key LIKE '%x|movie|1%'", []) { $0.int(0) } } ?? 0
        #expect(outbox == 1)       // the one from adding it; the switch added nothing
    }

    @Test func aKidsProfileNeedsItsPINToLeaveAndAProfilePINToEnter() throws {
        let db = try TestSupport.makeDB()
        let service = ProfileService(db: db)
        #expect(service.add(name: "Kid", kind: .kids, pin: nil) == nil)
        let kid = try #require(service.add(name: "Kid", kind: .kids, pin: "1234"))
        let locked = try #require(service.add(name: "Dad", kind: .adult, pin: "9999"))
        #expect(service.switchTo(locked.id) == .needsPIN)
        #expect(service.switchTo(locked.id, pin: "0000") == .wrongPIN)
        #expect(service.switchTo(kid.id) == .switched)
        #expect(service.leavingNeedsPIN)
        #expect(service.switchTo(ProfileService.mainID) == .needsPIN)
        #expect(service.switchTo(ProfileService.mainID, pin: "9999") == .wrongPIN)
        #expect(service.switchTo(ProfileService.mainID, pin: "1234") == .switched)
        #expect(!service.remove(ProfileService.mainID))
        #expect(service.remove(kid.id))
    }

    @Test func theActiveProfileSurvivesARelaunch() throws {
        let db = try TestSupport.makeDB()
        let service = ProfileService(db: db)
        let p = try #require(service.add(name: "B", kind: .adult, pin: nil))
        _ = service.switchTo(p.id)
        #expect(ProfileService(db: db).activeID == p.id)
    }
}
