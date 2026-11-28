import Foundation

// Where the account credentials live. The full cookie header is a whole Google session, so it goes to the Keychain and nowhere else:
// never to a file, a log or a message. Tests inject the in-memory store.

protocol YTMSecretStore: Sendable {
    func get(_ key: String) -> String?
    func set(_ value: String, for key: String)
    func remove(_ key: String)
}

struct YTMKeychainSecretStore: YTMSecretStore {
    private let keychain: MusicKeychain
    init(service: String = MusicKeychain.service) { keychain = MusicKeychain(service: service) }
    func get(_ key: String) -> String? { keychain.read(key) }
    func set(_ value: String, for key: String) { keychain.write(key, value) }
    func remove(_ key: String) { keychain.remove(key) }
}

final class YTMMemorySecretStore: YTMSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    init() {}
    func get(_ key: String) -> String? { lock.withLock { items[key] } }
    func set(_ value: String, for key: String) { lock.withLock { items[key] = value } }
    func remove(_ key: String) { lock.withLock { items[key] = nil } }
    var keys: [String] { lock.withLock { items.keys.sorted() } }
}
