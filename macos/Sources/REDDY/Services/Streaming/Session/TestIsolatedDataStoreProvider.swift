import WebKit

/// For tests: an in-memory store by default, or a persistent fixture store under a random identifier that is never in the catalog and is
/// removed afterwards. Production identifiers are refused, so a test cannot touch (or remove) a real session.
@MainActor struct TestIsolatedDataStoreProvider: DataStoreProvider {
    private let fixtureID: UUID?
    /// In-memory (the default).
    init() { fixtureID = nil }
    /// Persistent under `uuid` (a fresh random one unless a test wants to reopen the same fixture).
    init(persistentFixture uuid: UUID = UUID()) {
        precondition(!ProviderCatalog.all.contains { $0.storeIdentity.uuid == uuid }, "a test must never use a catalog store identifier")
        fixtureID = uuid
    }

    func store(for definition: ProviderDefinition) -> WKWebsiteDataStore {
        fixtureID.map { WKWebsiteDataStore(forIdentifier: $0) } ?? .nonPersistent()
    }

    /// Deletes a fixture store's files (never a catalog identifier).
    static func removeFixture(_ uuid: UUID) async {
        guard !ProviderCatalog.all.contains(where: { $0.storeIdentity.uuid == uuid }) else { return }
        try? await WKWebsiteDataStore.remove(forIdentifier: uuid)
    }
}
