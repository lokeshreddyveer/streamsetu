import Testing
import Foundation
@testable import REDDY

@Suite("Local credential store") struct LocalCredentialStoreTests {
    func dir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("reddy-cred-\(UUID().uuidString)", isDirectory: true) }

    @Test func roundTripsAcrossInstancesAndNeverStoresPlaintext() throws {
        let d = dir()
        let a = LocalCredentialStore(directory: d)
        try a.save(Credentials(username: "bob", password: "hunter2-secret", url: "http://x.example/get.php?token=abc123"), ref: "src-1")
        let b = LocalCredentialStore(directory: d)
        let got = try #require(try b.load(ref: "src-1"))
        #expect(got.username == "bob" && got.password == "hunter2-secret" && got.url == "http://x.example/get.php?token=abc123")
        let raw = try Data(contentsOf: d.appendingPathComponent("vault.bin"))
        for secret in ["bob", "hunter2-secret", "abc123", "x.example"] { #expect(raw.range(of: Data(secret.utf8)) == nil, "“\(secret)” must not appear in the file") }
        let attrs = try FileManager.default.attributesOfItem(atPath: d.appendingPathComponent("vault.bin").path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        #expect(try b.load(ref: "missing") == nil)
        try b.delete(ref: "src-1")
        #expect(try LocalCredentialStore(directory: d).load(ref: "src-1") == nil)
    }

    @Test func aTamperedFileIsRefusedNotMisread() throws {
        let d = dir()
        let a = LocalCredentialStore(directory: d)
        try a.save(Credentials(username: "u", password: "p"), ref: "r")
        var raw = try Data(contentsOf: d.appendingPathComponent("vault.bin"))
        raw[raw.count / 2] ^= 0xFF
        try raw.write(to: d.appendingPathComponent("vault.bin"))
        #expect(throws: (any Error).self) { try LocalCredentialStore(directory: d).load(ref: "r") }
    }

    @Test func buildsWithoutAStableIdentityNeverTouchTheKeychain() throws {
        let d = dir()
        let defaults = UserDefaults(suiteName: "cred-\(UUID().uuidString)")!
        let store = StandardCredentialStore(keychain: KeychainManager(service: "app.reddy.iptv.test-\(UUID().uuidString)"), local: LocalCredentialStore(directory: d), stableIdentity: false, defaults: defaults)
        try store.save(Credentials(username: "a", password: "b"), ref: "r1")
        #expect(try store.load(ref: "r1")?.password == "b")
        #expect(try LocalCredentialStore(directory: d).load(ref: "r1")?.password == "b")
        try store.delete(ref: "r1")
        #expect(try store.load(ref: "r1") == nil)
    }
}

@Suite("Vault bound to this Mac") struct VaultBindingTests {
    func dir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("reddy-vault-\(UUID().uuidString)", isDirectory: true) }

    @Test func aVaultCopiedToAnotherMacCannotBeRead() throws {
        let d = dir()
        let here = LocalCredentialStore(directory: d, machineID: { "MAC-A" })
        try here.save(Credentials(username: "bob", password: "secret-pw"), ref: "r")
        #expect(try LocalCredentialStore(directory: d, machineID: { "MAC-A" }).load(ref: "r")?.password == "secret-pw")
        #expect(throws: (any Error).self) { try LocalCredentialStore(directory: d, machineID: { "MAC-B" }).load(ref: "r") }
        let raw = try Data(contentsOf: d.appendingPathComponent("vault.bin"))
        #expect(raw.prefix(4) == Data("SSV2".utf8))
    }

    @Test func anOlderVaultIsReadAndUpgraded() throws {
        let d = dir()
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        // exactly what the previous version wrote: AES-GCM under the stored key, no header
        let keyData = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        try keyData.write(to: d.appendingPathComponent("vault.key"))
        let plain = try JSONEncoder().encode(["old": Credentials(username: "u", password: "old-pw")])
        let box = try AES.GCM.seal(plain, using: SymmetricKey(data: keyData)).combined!
        try box.write(to: d.appendingPathComponent("vault.bin"))
        let store = LocalCredentialStore(directory: d, machineID: { "MAC-A" })
        #expect(try store.load(ref: "old")?.password == "old-pw")
        #expect(try Data(contentsOf: d.appendingPathComponent("vault.bin")).prefix(4) == Data("SSV2".utf8), "rewritten in the new format")
        #expect(try LocalCredentialStore(directory: d, machineID: { "MAC-A" }).load(ref: "old")?.password == "old-pw")
    }

    @Test func theRealHardwareIdentifierIsStable() {
        let a = LocalCredentialStore.hardwareIdentifier(), b = LocalCredentialStore.hardwareIdentifier()
        #expect(a == b && !a.isEmpty)
    }
}
import CryptoKit
