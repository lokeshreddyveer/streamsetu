import Testing
import Foundation
@testable import REDDY

/// The Netflix website-data identity is frozen: changing it would sign every existing user out. These tests never create a store.
@Suite("Provider store identity") @MainActor struct ProviderStoreIdentityTests {
    static let netflixLiteral = "afdfb6b8-2671-42a0-bd87-6973dcd90758"

    @Test func testNetflixLiteral() {
        #expect(NetflixWebModel.storeIdentifier == UUID(uuidString: Self.netflixLiteral))
        #expect(NetflixWebModel.storeIdentifier.uuidString.lowercased() == Self.netflixLiteral)
    }

    @Test func aTestProcessIsRecognisedAndNeverGetsTheProductionStore() {
        #expect(NetflixWebModel.isRunningUnderTests)
        let before = NetflixWebModel.blockedProductionStoreRequests
        let store = NetflixWebModel.productionStore()
        #expect(!store.isPersistent, "a test process gets an in-memory store")
        #expect(NetflixWebModel.blockedProductionStoreRequests == before + 1)
    }
}
