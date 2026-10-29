import Testing
import Foundation
import CryptoKit
@testable import REDDY

@Suite("PINs are stored with a slow derivation") struct PINHashTests {
    private func hex(_ b: [UInt8]) -> String { PINHash.hex(b) }

    @Test func theDerivationIsStandardPBKDF2HMACSHA256() {
        // Published test vectors for PBKDF2-HMAC-SHA256.
        let salt = Data("salt".utf8)
        #expect(hex(PINHash.derive("password", salt: salt, rounds: 1)) == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        #expect(hex(PINHash.derive("password", salt: salt, rounds: 2)) == "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")
        #expect(hex(PINHash.derive("password", salt: salt, rounds: 4096)) == "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
        #expect(hex(PINHash.derive("passwd", salt: salt, rounds: 1, length: 64)) == "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783")
    }

    @Test func aStoredPINIsVersionedAndCarriesItsRounds() {
        let stored = PINHash.make("1234", salt: Data("s".utf8), rounds: 1000)
        #expect(stored.hasPrefix("pbkdf2-sha256$1000$"))
        #expect(stored.split(separator: "$").last?.count == 64)
        #expect(PINHash.verify("1234", salt: Data("s".utf8), stored: stored) == .right)
        #expect(PINHash.verify("1235", salt: Data("s".utf8), stored: stored) == .wrong)
        #expect(PINHash.verify("1234", salt: Data("other".utf8), stored: stored) == .wrong, "the salt is part of the answer")
    }

    @Test func theRoundsAreMeasuredOnTheDeviceAndKeptInRange() {
        #expect(PINHash.calibratedRounds >= PINHash.minRounds && PINHash.calibratedRounds <= PINHash.maxRounds)
        let stored = PINHash.make("0000", salt: Data("s".utf8))
        #expect(stored.hasPrefix("pbkdf2-sha256$\(PINHash.calibratedRounds)$"))
    }

    @Test func aPINStoredTheOldFastWayStillWorksAndIsReportedAsOld() {
        let salt = Data("old-salt".utf8)
        let legacy = PINHash.hex(Array(SHA256.hash(data: salt + Data("4321".utf8))))
        #expect(PINHash.verify("4321", salt: salt, stored: legacy) == .rightButOld)
        #expect(PINHash.verify("4322", salt: salt, stored: legacy) == .wrong)
    }

    @Test func garbageIsNeverAccepted() {
        for bad in ["", "pbkdf2-sha256$0$00", "pbkdf2-sha256$abc$00", "pbkdf2-sha256$1000", "scrypt$1$2", "pbkdf2-sha256$99999999999$00"] {
            #expect(PINHash.verify("1234", salt: Data("s".utf8), stored: bad) == .wrong, "\(bad)")
        }
    }

    @MainActor @Test func aProfilePINStoredTheOldWayIsUpgradedOnTheFirstRightEntry() throws {
        let db = try TestSupport.makeDB()
        let defaults = UserDefaults(suiteName: "pin-\(UUID().uuidString)")!
        let service = ProfileService(db: db, defaults: defaults)
        let salt = "legacy-salt"
        let legacy = PINHash.hex(Array(SHA256.hash(data: Data((salt + "2468").utf8))))
        try db.write { try $0.execute("INSERT INTO profiles(id, name, kind, pin_salt, pin_hash, color, sort_order, created_at) VALUES('p1', 'Kid', 'kids', ?, ?, 0, 1, 0)", [salt, legacy]) }
        service.reload()
        #expect(!service.checkPIN("p1", "0000"), "a wrong PIN is refused and nothing is rewritten")
        let before: String? = try db.read { try $0.queryOne("SELECT pin_hash FROM profiles WHERE id = 'p1'", []) { $0.string(0) } }
        #expect(before == legacy)
        #expect(service.checkPIN("p1", "2468"))
        let after: String? = try db.read { try $0.queryOne("SELECT pin_hash FROM profiles WHERE id = 'p1'", []) { $0.string(0) } }
        #expect(after?.hasPrefix("pbkdf2-sha256$") == true && after != legacy, "stored again in the new form")
        #expect(service.checkPIN("p1", "2468"), "and still right afterwards")
        #expect(!service.checkPIN("p1", "1111"))
    }

    @MainActor @Test func aNewProfilePINIsStoredInTheNewForm() throws {
        let db = try TestSupport.makeDB()
        let service = ProfileService(db: db, defaults: UserDefaults(suiteName: "pin-\(UUID().uuidString)")!)
        let kid = try #require(service.add(name: "Anya", kind: .kids, pin: "1357"))
        let stored: String? = try db.read { try $0.queryOne("SELECT pin_hash FROM profiles WHERE id = ?", [kid.id]) { $0.string(0) } }
        #expect(stored?.hasPrefix("pbkdf2-sha256$") == true)
        #expect(service.checkPIN(kid.id, "1357") && !service.checkPIN(kid.id, "7531"))
    }
}
