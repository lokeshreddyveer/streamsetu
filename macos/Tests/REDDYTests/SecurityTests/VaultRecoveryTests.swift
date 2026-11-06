import Testing
import Foundation
@testable import REDDY

/// What happens to the saved logins when the vault cannot be opened. The encrypted record is never overwritten or deleted by a failure; recovery moves it aside, whole.
/// Throwaway folders and a fake machine id only: no Keychain, no real data.
@Suite("Login vault: a failure never destroys the encrypted record") struct VaultRecoveryTests {
    private func dir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("reddy-vaultrec-\(UUID().uuidString)", isDirectory: true) }
    private let login = Credentials(username: "bob", password: "hunter2", url: "http://x.example/get.php?token=t")
    private let other = Credentials(username: "amy", password: "pw-2", url: nil)

    private func store(_ d: URL, id: String = "mac-A") -> LocalCredentialStore { LocalCredentialStore(directory: d, machineID: { id }) }
    private func bytes(_ d: URL, _ name: String) -> Data? { try? Data(contentsOf: d.appendingPathComponent(name)) }

    @Test func aVaultThatExistsButCannotBeReadIsNeverTreatedAsEmpty() throws {
        let d = dir()
        try store(d).save(login, ref: "src-1")
        let before = try #require(bytes(d, "vault.bin"))
        let path = d.appendingPathComponent("vault.bin").path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)       // a read that fails for a moment
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) }
        #expect(throws: (any Error).self) { try store(d).save(other, ref: "src-2") }                // must refuse, not start a new vault
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        #expect(bytes(d, "vault.bin") == before, "the vault file must be exactly as it was")
        #expect(try store(d).load(ref: "src-1") == login, "and the saved login must still be there")
    }

    @Test func aDamagedOrUnreadableKeyFileIsNeverReplacedWhileAVaultExists() throws {
        let d = dir()
        try store(d).save(login, ref: "src-1")
        let key = try #require(bytes(d, "vault.key")), vault = try #require(bytes(d, "vault.bin"))
        try Data(key.prefix(10)).write(to: d.appendingPathComponent("vault.key"))                  // a cut-short key file
        #expect(throws: (any Error).self) { try store(d).save(other, ref: "src-2") }
        #expect(bytes(d, "vault.key") == Data(key.prefix(10)), "the key file is left alone (a new random key would make the vault unreadable for good)")
        #expect(bytes(d, "vault.bin") == vault)
        try key.write(to: d.appendingPathComponent("vault.key"))                                    // the key comes back (restored from a backup, say)
        #expect(try store(d).load(ref: "src-1") == login)
    }

    @Test func aVaultWithoutItsKeyIsNotGivenANewKey() throws {
        let d = dir()
        try store(d).save(login, ref: "src-1")
        let vault = try #require(bytes(d, "vault.bin"))
        try FileManager.default.removeItem(at: d.appendingPathComponent("vault.key"))
        #expect(throws: (any Error).self) { try store(d).save(other, ref: "src-2") }
        #expect(!FileManager.default.fileExists(atPath: d.appendingPathComponent("vault.key").path), "no new key was made over the missing one")
        #expect(bytes(d, "vault.bin") == vault)
    }

    @Test func aVaultThatCannotBeOpenedIsReportedAndLeftWhole() throws {
        let d = dir()
        try store(d, id: "mac-A").save(login, ref: "src-1")
        let vault = try #require(bytes(d, "vault.bin")), key = try #require(bytes(d, "vault.key"))
        let b = store(d, id: "mac-B")                                                                // another Mac, or a hardware id that changed
        #expect(throws: (any Error).self) { try b.load(ref: "src-1") }
        #expect(throws: (any Error).self) { try b.save(other, ref: "src-2") }
        if case .locked = b.health {} else { Issue.record("the store must say it is locked, so Settings can offer recovery") }
        #expect(bytes(d, "vault.bin") == vault && bytes(d, "vault.key") == key, "nothing was touched")
    }

    @Test func startingAFreshVaultKeepsTheOldRecordWholeAndWorksAtOnce() throws {
        let d = dir()
        try store(d, id: "mac-A").save(login, ref: "src-1")
        let vault = try #require(bytes(d, "vault.bin")), key = try #require(bytes(d, "vault.key"))
        let b = store(d, id: "mac-B")
        let kept = try b.startFreshVault()
        #expect(try Data(contentsOf: kept.appendingPathComponent("vault.bin")) == vault, "the old encrypted file is kept byte for byte")
        #expect(try Data(contentsOf: kept.appendingPathComponent("vault.key")) == key, "with its key")
        #expect(b.health == .ok)
        try b.save(other, ref: "src-2")
        #expect(try b.load(ref: "src-2") == other)
        #expect(try b.load(ref: "src-1") == nil, "the old logins are not mixed in; they are in the kept folder")
        #expect(b.recoveredVaults().count == 1)
        // The kept folder is a complete vault: opened on the Mac that made it, every login is there.
        let again = LocalCredentialStore(directory: kept, machineID: { "mac-A" })
        #expect(try again.load(ref: "src-1") == login)
    }

    @Test func aVaultSavedWhileTheHardwareIdWasUnavailableIsOpenedAndUpgraded() throws {
        let d = dir()
        try LocalCredentialStore(directory: d, machineID: LocalCredentialStore.fallbackMachineID).save(login, ref: "src-1")   // IOKit gave no id that time
        let real = store(d, id: "real-hardware-id")
        #expect(try real.load(ref: "src-1") == login, "it opens with the fallback id too")
        #expect(throws: Never.self) { try real.save(other, ref: "src-2") }
        #expect(try store(d, id: "real-hardware-id").load(ref: "src-1") == login, "and is bound to the real id from then on")
    }

    @Test func everyWriteKeepsThePreviousVaultAsABackup() throws {
        let d = dir()
        let s = store(d)
        try s.save(login, ref: "src-1")
        let first = try #require(bytes(d, "vault.bin"))
        try s.save(other, ref: "src-2")
        #expect(bytes(d, "vault.bin.bak") == first, "one generation back, in case a write goes wrong")
    }
}

private final class FakeKeychain: KeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Credentials] = [:]
    func save(_ c: Credentials, ref: String) throws { lock.lock(); items[ref] = c; lock.unlock() }
    func load(ref: String) throws -> Credentials? { try load(ref: ref, migrating: true) }
    func load(ref: String, migrating: Bool) throws -> Credentials? { lock.lock(); defer { lock.unlock() }; return items[ref] }
    func delete(ref: String) throws { lock.lock(); items[ref] = nil; lock.unlock() }
}

@Suite("Login vault: deleting a login in a signed build") struct SignedBuildDeleteTests {
    @Test func aDeletedLoginDoesNotComeBackFromTheEncryptedFile() throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("reddy-vaultdel-\(UUID().uuidString)", isDirectory: true)
        let login = Credentials(username: "bob", password: "hunter2", url: nil)
        try LocalCredentialStore(directory: d, machineID: { "m" }).save(login, ref: "src-1")           // left by an unsigned build
        let signed = StandardCredentialStore(keychain: FakeKeychain(), local: LocalCredentialStore(directory: d, machineID: { "m" }), stableIdentity: true,
                                             defaults: UserDefaults(suiteName: "vaultdel-\(UUID().uuidString)")!)
        try signed.delete(ref: "src-1")                                                                  // deleted before it was ever moved to the Keychain
        #expect(try signed.load(ref: "src-1") == nil, "a login that was deleted must not be found again in the old file")
    }
}
