import Foundation

/// Thin convenience over a `CredentialStore` for creating references and cleaning up.
struct SecureStorage: Sendable {
    let store: CredentialStore

    func newReference() -> String { "src-" + UUID().uuidString.lowercased() }

    func save(_ c: Credentials, ref: String? = nil) throws -> String {
        let r = ref ?? newReference()
        try store.save(c, ref: r)
        return r
    }

    func credentials(for source: PlaylistSource) -> Credentials? {
        guard let ref = source.credentialRef else { return nil }
        return try? store.load(ref: ref)
    }

    func remove(ref: String?) { if let ref { try? store.delete(ref: ref) } }
}
