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
        return fallbackMachineID()
        #else
        // iOS apps are sandboxed per app and the Keychain is used there instead (see StandardCredentialStore).
        return "streamsetu-ios"
        #endif
    }

    /// What the Mac's identifier is taken to be when the system will not give it (see `hardwareIdentifier`).
    static func fallbackMachineID() -> String { "streamsetu-unknown-machine" }

    /// Why the vault cannot be opened. None of these ever changes the vault or its key on disk.
    enum VaultError: Error, LocalizedError, Equatable {
        case unreadable          // the file is there but could not be read now
        case keyUnavailable      // the key file is missing, cut short, or could not be read, while the vault exists
        case cannotDecrypt       // opened with every key this Mac can make, and it did not open: another Mac, or damaged
        var errorDescription: String? {
            switch self {
            case .unreadable: "The saved logins could not be read right now. Nothing was changed; try again."
            case .keyUnavailable: "The key for the saved logins is missing or damaged. The saved logins were left as they are."
            case .cannotDecrypt: "The saved logins cannot be opened on this Mac (they were made with another key or on another Mac). They were left as they are; you can start a new set and keep the old file."
            }
        }
    }

    enum Health: Equatable { case ok, locked(String) }

    /// Whether the vault can be opened. Settings shows `locked` and offers `startFreshVault()`.
    var health: Health {
        lock.lock(); defer { lock.unlock() }
        do { _ = try read(); return .ok } catch { return .locked((error as? LocalizedError)?.errorDescription ?? "The saved logins cannot be opened.") }
    }

    /// Recovery for a vault that cannot be opened: the vault, its key and its backup are COPIED whole into `Recovered/<time>/` and only then taken away, so the old encrypted record is never
    /// lost, and a new empty vault starts. The kept folder is a complete vault: it opens on the Mac that made it (or with the key it was made with), and nothing is ever deleted from it.
    @discardableResult
    func startFreshVault() throws -> URL {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        try ensureDirectory()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folder = directory.appendingPathComponent("Recovered", isDirectory: true).appendingPathComponent("\(stamp)-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let files = [vaultURL, keyURL, backupURL].filter { fm.fileExists(atPath: $0.path) }
        for f in files { try fm.copyItem(at: f, to: folder.appendingPathComponent(f.lastPathComponent)) }          // all copied before anything is taken away
        for f in files { try fm.removeItem(at: f) }
        cache = nil
        return folder
    }

    /// The folders that earlier recoveries kept.
    func recoveredVaults() -> [URL] {
        let root = directory.appendingPathComponent("Recovered", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private var keyURL: URL { directory.appendingPathComponent("vault.key") }
    private var vaultURL: URL { directory.appendingPathComponent("vault.bin") }
    private var backupURL: URL { directory.appendingPathComponent("vault.bin.bak") }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var url = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// The random key kept in the folder.
    private func storedKey() throws -> SymmetricKey {
        try ensureDirectory()
        let fm = FileManager.default
        if fm.fileExists(atPath: keyURL.path) {
            guard let data = try? Data(contentsOf: keyURL) else { throw VaultError.keyUnavailable }          // there, but not readable now: never a reason for a new key
            if data.count == 32 { return SymmetricKey(data: data) }
            if fm.fileExists(atPath: vaultURL.path) { throw VaultError.keyUnavailable }                      // a wrong key file with a vault to open: a new key would lock the vault for good
        } else if fm.fileExists(atPath: vaultURL.path) {
            throw VaultError.keyUnavailable                                                                  // the vault without its key
        }
        let k = SymmetricKey(size: .bits256)
        let data = k.withUnsafeBytes { Data($0) }
        try data.write(to: keyURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        return k
    }

    /// The key actually used: the stored key mixed with this Mac's identifier.
    private func boundKey(_ id: String? = nil) throws -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: try storedKey(), salt: Data((id ?? machineID()).utf8), info: Data("streamsetu.vault.v2".utf8), outputByteCount: 32)
    }

    private func read() throws -> [String: Credentials] {
        if let cache { return cache }
        // No file: an empty vault. A file that is there but cannot be read is NOT an empty vault: treating it as one made the next save replace the real vault with a new one.
        guard FileManager.default.fileExists(atPath: vaultURL.path) else { cache = [:]; return [:] }
        let blob: Data
        do { blob = try Data(contentsOf: vaultURL) } catch { throw VaultError.unreadable }
        if blob.isEmpty { cache = [:]; return [:] }
        var upgraded = false
        let plain: Data
        do {
            if blob.prefix(Self.magic.count) == Self.magic {
                let sealed = try AES.GCM.SealedBox(combined: blob.dropFirst(Self.magic.count))
                // The Mac's identifier, and the fixed one a vault was made with when the system gave no identifier at that moment.
                let ids = [machineID(), Self.fallbackMachineID()]
                var opened: Data?
                for id in ids where opened == nil { opened = try? AES.GCM.open(sealed, using: try boundKey(id)) }
                guard let opened else { throw VaultError.cannotDecrypt }
                plain = opened; upgraded = opened != nil && (try? AES.GCM.open(sealed, using: try boundKey())) == nil
            } else {
                plain = try AES.GCM.open(try AES.GCM.SealedBox(combined: blob), using: try storedKey()); upgraded = true
            }
        } catch let e as VaultError { throw e } catch { throw VaultError.cannotDecrypt }
        guard let items = try? JSONDecoder().decode([String: Credentials].self, from: plain) else { throw VaultError.cannotDecrypt }
        cache = items
        if upgraded { try? write(items) }                       // an older file, or one made under the fallback identifier, is rewritten bound to this Mac
        return items
    }

    private func write(_ items: [String: Credentials]) throws {
        let plain = try JSONEncoder().encode(items)
        guard let combined = try AES.GCM.seal(plain, using: try boundKey()).combined else { throw KeychainError(status: errSecParam) }
        let fm = FileManager.default
        if fm.fileExists(atPath: vaultURL.path) { try? fm.removeItem(at: backupURL); try? fm.copyItem(at: vaultURL, to: backupURL) }          // one generation back, in case this write goes wrong
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
        if stable {
            try keychain.delete(ref: ref)
            // A login the encrypted file still holds (it moves into the Keychain only when first read) would come back at the next read; it goes too. A file that cannot be opened is left alone.
            try? local.delete(ref: ref)
        } else { try local.delete(ref: ref) }
    }

    // This device only (see CredentialStore): a signed build keeps these in its own Keychain whatever the iCloud setting is; any other build already keeps everything in the local file.
    func saveLocal(_ credentials: Credentials, ref: String) throws {
        if stable { try keychain.saveLocal(credentials, ref: ref) } else { try local.save(credentials, ref: ref) }
    }
    func loadLocal(ref: String) throws -> Credentials? {
        if stable { return try keychain.loadLocal(ref: ref) } else { return try local.load(ref: ref) }
    }
    func deleteLocal(ref: String) throws {
        if stable { try keychain.deleteLocal(ref: ref) } else { try local.delete(ref: ref) }
    }

    /// Whether the saved logins can be opened. A signed build keeps them in the Keychain, which is not a file that can lock; any other build uses the encrypted file, which can.
    var vaultHealth: LocalCredentialStore.Health { stable ? .ok : local.health }

    /// Recovery for an encrypted file that cannot be opened: it is kept whole and a new one starts (see `LocalCredentialStore.startFreshVault`). Nil for a signed build.
    @discardableResult
    func startFreshVault() throws -> URL? { stable ? nil : try local.startFreshVault() }

    /// Keeps logins in iCloud Keychain (or not). Only a signed build has a Keychain of its own to move them in.
    func applySync(_ on: Bool, refs: [String]) { if stable { keychain.setSynchronizable(on, migrating: refs) } }
}
