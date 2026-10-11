import Foundation
import CryptoKit
import Security
#if os(macOS)
import IOKit
#endif

/// Logins kept in an encrypted file in the app's own folder (readable only by this user account).
///
/// Why not the Keychain: macOS ties a Keychain item to the exact code identity of the build that saved it. A build signed with a
/// local certificate has no stable identity (no Apple team), so every new build asks for the account password again. With a
/// stable Developer ID signature `StandardCredentialStore` uses the Keychain instead.
final class LocalCredentialStore: CredentialStore, @unchecked Sendable {
    private let directory: URL
    private let machineID: @Sendable () -> String
    private let lock = NSLock()
    private var cache: [String: Credentials]?
    /// Files written by this version start with these bytes; older files (key used as stored) do not, and are upgraded when read.
    private static let magic = Data("SSV2".utf8)

    /// `machineID` ties the vault to this Mac: the encryption key is derived from the stored random key *and* the hardware's
    /// own identifier, so copying the files to another Mac (or out of a backup) does not give the logins away.
    init(directory: URL = StorageService.applicationSupport.appendingPathComponent("Credentials", isDirectory: true),
         machineID: @escaping @Sendable () -> String = LocalCredentialStore.hardwareIdentifier) {
        self.directory = directory; self.machineID = machineID
    }

    /// The Mac's platform UUID, or a fixed fallback when the system won't give it.
    static func hardwareIdentifier() -> String {
        #if os(macOS)
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { if entry != 0 { IOObjectRelease(entry) } }
        if entry != 0, let v = IORegistryEntryCreateCFProperty(entry, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String { return v }
        return "streamsetu-unknown-machine"
        #else
        // iOS apps are sandboxed per app and the Keychain is used there instead (see StandardCredentialStore).
        return "streamsetu-ios"
        #endif
    }

    private var keyURL: URL { directory.appendingPathComponent("vault.key") }
    private var vaultURL: URL { directory.appendingPathComponent("vault.bin") }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var url = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// The random key kept in the folder.
    private func storedKey() throws -> SymmetricKey {
        try ensureDirectory()
        if let data = try? Data(contentsOf: keyURL), data.count == 32 { return SymmetricKey(data: data) }
        let k = SymmetricKey(size: .bits256)
        let data = k.withUnsafeBytes { Data($0) }
        try data.write(to: keyURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        return k
    }

    /// The key actually used: the stored key mixed with this Mac's identifier.
    private func boundKey() throws -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: try storedKey(), salt: Data(machineID().utf8), info: Data("streamsetu.vault.v2".utf8), outputByteCount: 32)
    }

    private func read() throws -> [String: Credentials] {
        if let cache { return cache }
        guard let blob = try? Data(contentsOf: vaultURL), !blob.isEmpty else { cache = [:]; return [:] }
        let upgraded: Bool
        let plain: Data
        if blob.prefix(Self.magic.count) == Self.magic {
            plain = try AES.GCM.open(try AES.GCM.SealedBox(combined: blob.dropFirst(Self.magic.count)), using: try boundKey()); upgraded = false
        } else {
            plain = try AES.GCM.open(try AES.GCM.SealedBox(combined: blob), using: try storedKey()); upgraded = true
        }
        let items = try JSONDecoder().decode([String: Credentials].self, from: plain)
        cache = items
        if upgraded { try? write(items) }                       // an older file is rewritten bound to this Mac
        return items
    }

    private func write(_ items: [String: Credentials]) throws {
        let plain = try JSONEncoder().encode(items)
        guard let combined = try AES.GCM.seal(plain, using: try boundKey()).combined else { throw KeychainError(status: errSecParam) }
        try (Self.magic + combined).write(to: vaultURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: vaultURL.path)
        cache = items
    }

    func save(_ credentials: Credentials, ref: String) throws {
        lock.lock(); defer { lock.unlock() }
        var items = try read(); items[ref] = credentials; try write(items)
    }

    func load(ref: String) throws -> Credentials? {
        lock.lock(); defer { lock.unlock() }
        return try read()[ref]
    }

    func delete(ref: String) throws {
        lock.lock(); defer { lock.unlock() }
        var items = try read()
        guard items.removeValue(forKey: ref) != nil else { return }
        try write(items)
    }
}

/// Picks where logins live. A build with a stable code identity (signed by an Apple team) uses the Keychain. Any other build
/// uses the local encrypted file, so it never asks for the account password; logins an earlier build left in the Keychain are
/// copied over once, the first time they are needed.
final class StandardCredentialStore: CredentialStore, @unchecked Sendable {
    private let keychain: any KeychainStore
    private let local: LocalCredentialStore
    private let stable: Bool
    private let defaults: UserDefaults

    init(keychain: (any KeychainStore)? = nil, local: LocalCredentialStore = LocalCredentialStore(),
         stableIdentity: Bool = StandardCredentialStore.hasStableIdentity(), defaults: UserDefaults = .standard) {
        self.keychain = keychain ?? KeychainManager(openAccess: !stableIdentity)
        self.local = local; self.stable = stableIdentity; self.defaults = defaults
    }

    static func hasStableIdentity() -> Bool {
        #if os(iOS)
        return true        // the iOS Keychain is private to the app and never prompts, whoever signed the build
        #else
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return false }
        return (dict[kSecCodeInfoTeamIdentifier as String] as? String)?.isEmpty == false
        #endif
    }

    func save(_ credentials: Credentials, ref: String) throws {
        if stable { try keychain.save(credentials, ref: ref) } else { try local.save(credentials, ref: ref) }
    }

    func load(ref: String) throws -> Credentials? {
        if stable {
            if let c = try keychain.load(ref: ref, migrating: false) { return c }
            // First run of a signed build: a login the encrypted file holds moves into the Keychain. The file's copy is removed
            // only once the Keychain really has it, so a failure here never loses a login.
            if let c = try local.load(ref: ref) {
                do { try keychain.save(c, ref: ref); try? local.delete(ref: ref) } catch { return c }
                return c
            }
            return nil
        }
        if let c = try local.load(ref: ref) { return c }
        // One look in the Keychain for a login an earlier build saved there. Asked once per login, whatever the answer, so
        // a refusal never turns into a prompt on every launch.
        let flag = "credentials.keychainChecked.\(ref)"
        guard !defaults.bool(forKey: flag) else { return nil }
        defaults.set(true, forKey: flag)
        guard let found = try? keychain.load(ref: ref, migrating: false) else { return nil }
        try? local.save(found, ref: ref)
        return found
    }

    func delete(ref: String) throws {
        if stable { try keychain.delete(ref: ref) } else { try local.delete(ref: ref) }
    }

    /// Keeps logins in iCloud Keychain (or not). Only a signed build has a Keychain of its own to move them in.
    func applySync(_ on: Bool, refs: [String]) { if stable { keychain.setSynchronizable(on, migrating: refs) } }
}
