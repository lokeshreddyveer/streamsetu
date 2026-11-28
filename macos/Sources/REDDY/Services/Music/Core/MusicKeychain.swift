import Foundation

/// The one place Music keeps a secret. It wraps the app's own `KeychainManager` under the service name "StreamSetu.Music", so the macOS access rule
/// (no password prompt after an update) and the iOS protection class are the app's, not a second copy. Nothing here ever syncs to iCloud.
struct MusicKeychain: Sendable {
    static let service = "StreamSetu.Music"
    static let shared = MusicKeychain()
    private let manager: KeychainManager

    init(service: String = MusicKeychain.service) { manager = KeychainManager(service: service) }

    func read(_ account: String) -> String? { (try? manager.load(ref: account))?.password }

    /// Saves the value, or removes the item when it is nil or empty. True when the Keychain accepted it.
    @discardableResult
    func write(_ account: String, _ value: String?) -> Bool {
        guard let value, !value.isEmpty else { remove(account); return true }
        return (try? manager.save(Credentials(username: nil, password: value, url: nil), ref: account)) != nil
    }

    func remove(_ account: String) { try? manager.delete(ref: account) }

    /// Binary secrets (a device key) are kept as base64 text.
    func readData(_ account: String) -> Data? { read(account).flatMap { Data(base64Encoded: $0) } }
    func writeData(_ account: String, _ data: Data) { write(account, data.base64EncodedString()) }
}
