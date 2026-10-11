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
}

/// Test double that keeps secrets in memory only.
final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var items: [String: Credentials] = [:]
    private let lock = NSLock()
    func save(_ credentials: Credentials, ref: String) throws { lock.lock(); items[ref] = credentials; lock.unlock() }
    func load(ref: String) throws -> Credentials? { lock.lock(); defer { lock.unlock() }; return items[ref] }
    func delete(ref: String) throws { lock.lock(); items[ref] = nil; lock.unlock() }
}
