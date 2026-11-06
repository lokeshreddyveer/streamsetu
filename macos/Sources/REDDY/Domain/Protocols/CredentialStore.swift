import Foundation

struct Credentials: Codable, Hashable, Sendable {
    var username: String?
    var password: String?
    /// Full original URL for sources whose address itself carries secrets (tokens, embedded logins).
    var url: String?
}

protocol CredentialStore: Sendable {
    func save(_ credentials: Credentials, ref: String) throws
    func load(ref: String) throws -> Credentials?
    func delete(ref: String) throws
    /// For a secret that belongs to this device alone: never put in iCloud Keychain, whatever the sync setting is (a device's own identity key,
    /// which would otherwise be copied to the person's other devices and make them the same device).
    func saveLocal(_ credentials: Credentials, ref: String) throws
    func loadLocal(ref: String) throws -> Credentials?
    func deleteLocal(ref: String) throws
}

extension CredentialStore {
    func saveLocal(_ credentials: Credentials, ref: String) throws { try save(credentials, ref: ref) }
    func loadLocal(ref: String) throws -> Credentials? { try load(ref: ref) }
    func deleteLocal(ref: String) throws { try delete(ref: ref) }
}

/// Test double that keeps secrets in memory only.
final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var items: [String: Credentials] = [:]
    private let lock = NSLock()
    func save(_ credentials: Credentials, ref: String) throws { lock.lock(); items[ref] = credentials; lock.unlock() }
    func load(ref: String) throws -> Credentials? { lock.lock(); defer { lock.unlock() }; return items[ref] }
    func delete(ref: String) throws { lock.lock(); items[ref] = nil; lock.unlock() }
}
