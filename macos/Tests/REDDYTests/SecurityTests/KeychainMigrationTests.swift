import Testing
import Foundation
@testable import REDDY

/// An in-memory Keychain, so these tests never touch the real one.
private final class FakeKeychain: KeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Credentials] = [:]
    var failSaves = false
    func save(_ c: Credentials, ref: String) throws {
        if failSaves { throw KeychainError(status: -25293) }
        lock.lock(); items[ref] = c; lock.unlock()
    }
    func load(ref: String) throws -> Credentials? { try load(ref: ref, migrating: true) }
    func load(ref: String, migrating: Bool) throws -> Credentials? { lock.lock(); defer { lock.unlock() }; return items[ref] }
    func delete(ref: String) throws { lock.lock(); items[ref] = nil; lock.unlock() }
}

@Suite("Moving logins into the Keychain for signed builds") struct KeychainMigrationTests {
    private func dir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("reddy-mig-\(UUID().uuidString)", isDirectory: true) }
    private let login = Credentials(username: "bob", password: "hunter2", url: "http://x.example/get.php?token=t")

    private func store(_ d: URL, _ kc: FakeKeychain, stable: Bool) -> StandardCredentialStore {
        StandardCredentialStore(keychain: kc, local: LocalCredentialStore(directory: d), stableIdentity: stable,
                                defaults: UserDefaults(suiteName: "mig-\(UUID().uuidString)")!)
    }

    @Test func aSignedBuildMovesTheEncryptedFilesLoginsIntoTheKeychain() throws {
        let d = dir(), kc = FakeKeychain()
        try LocalCredentialStore(directory: d).save(login, ref: "src-1")                     // what an unsigned build left behind
        let signed = store(d, kc, stable: true)
        #expect(try signed.load(ref: "src-1") == login)
        #expect(try kc.load(ref: "src-1") == login, "now in the Keychain")
        #expect(try LocalCredentialStore(directory: d).load(ref: "src-1") == nil, "and gone from the file")
        #expect(try signed.load(ref: "src-1") == login, "later reads come from the Keychain")
    }

    @Test func aFailedKeychainWriteNeverLosesTheLogin() throws {
        let d = dir(), kc = FakeKeychain()
        try LocalCredentialStore(directory: d).save(login, ref: "src-1")
        kc.failSaves = true
        let signed = store(d, kc, stable: true)
        #expect(try signed.load(ref: "src-1") == login, "still usable")
        #expect(try LocalCredentialStore(directory: d).load(ref: "src-1") == login, "and still in the file")
        kc.failSaves = false
        #expect(try signed.load(ref: "src-1") == login)
        #expect(try kc.load(ref: "src-1") == login, "moved on the next read")
    }

    @Test func signedBuildsSaveAndDeleteInTheKeychainAndUnsignedOnesStayLocal() throws {
        let d = dir(), kc = FakeKeychain()
        let signed = store(d, kc, stable: true)
        try signed.save(login, ref: "a")
        #expect(try kc.load(ref: "a") == login && (try LocalCredentialStore(directory: d).load(ref: "a")) == nil)
        try signed.delete(ref: "a")
        #expect(try kc.load(ref: "a") == nil)

        let unsigned = store(dir(), kc, stable: false)
        try unsigned.save(login, ref: "b")
        #expect(try kc.load(ref: "b") == nil, "an unsigned build never writes to the Keychain")
        #expect(try unsigned.load(ref: "b") == login)
    }
}
