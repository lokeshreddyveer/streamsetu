import Testing
import WebKit
@testable import REDDY

/// Every service has its own store identifier, and a test process can never be handed a real one. No test here creates a catalog store.
@Suite("Data store provider") @MainActor struct DataStoreProviderTests {
    @Test func everyServiceHasItsOwnFrozenStoreIdentifier() {
        let ids = ProviderCatalog.all.map(\.storeIdentity.uuid)
        #expect(ids.count == 10 && Set(ids).count == 10)
        #expect(ProviderCatalog.netflix.storeIdentity.uuid == UUID(uuidString: "afdfb6b8-2671-42a0-bd87-6973dcd90758"))
        #expect(ServiceWebModel.storeIdentifier == ProviderCatalog.netflix.storeIdentity.uuid)
    }

    @Test func aTestProcessGetsAnInMemoryStoreForEveryServiceAndTheRequestIsCounted() {
        #expect(TestProcess.isRunning)
        for d in ProviderCatalog.all {
            let before = ProductionDataStoreProvider.blockedProductionStoreRequests[d.id] ?? 0
            let store = ProductionDataStoreProvider().store(for: d)
            #expect(!store.isPersistent, "\(d.id)")
            #expect(ProductionDataStoreProvider.blockedProductionStoreRequests[d.id] == before + 1, "\(d.id)")
        }
    }

    @Test func aModelAsksForItsStoreOnlyWhenItIsUsed() {
        for d in ProviderCatalog.all {
            let before = ProductionDataStoreProvider.blockedProductionStoreRequests[d.id] ?? 0
            let m = ServiceWebModel(definition: d)
            #expect((ProductionDataStoreProvider.blockedProductionStoreRequests[d.id] ?? 0) == before, "made: no store yet (\(d.id))")
            #expect(!m.dataStore.isPersistent)
            #expect(ProductionDataStoreProvider.blockedProductionStoreRequests[d.id] == before + 1, "\(d.id)")
            #expect(m.webView == nil)
        }
    }

    @Test func twoServicesNeverShareAStore() {
        let provider = TestIsolatedDataStoreProvider()
        let a = provider.store(for: ProviderCatalog.primevideo), b = provider.store(for: ProviderCatalog.hulu)
        #expect(a !== b)
    }

    @Test func aFixtureStoreUsesARandomIdentifierThatIsNeverInTheCatalog() async {
        let id = UUID()
        let p = TestIsolatedDataStoreProvider(persistentFixture: id)
        #expect(p.store(for: ProviderCatalog.netflix).isPersistent)
        #expect(!ProviderCatalog.all.contains { $0.storeIdentity.uuid == id })
        await TestIsolatedDataStoreProvider.removeFixture(id)
        await TestIsolatedDataStoreProvider.removeFixture(ProviderCatalog.netflix.storeIdentity.uuid)          // refused: a catalog id is never removed
    }

    @Test func storeIdentifiersAreLiteralsAndRemovalLivesInOneTestOnlyFile() throws {
        let running = try ServiceSources.runtime()
        #expect(!running.contains("UUID(uuidString:") && !running.contains("remove(forIdentifier") && !running.contains("WKWebsiteDataStore.default()"))
        let testOnly = try ServiceSources.text(["Services/Streaming/Session"], excluding: ["DataStoreProvider.swift", "SessionClearing.swift"])
        #expect(testOnly.contains("remove(forIdentifier") && testOnly.contains("catalog"))
    }
}
