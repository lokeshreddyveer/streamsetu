import WebKit

// The Netflix destination now runs on the one model every service uses (Services/Streaming/Runtime). These names stay until the final cleanup
// so existing callers and tests keep compiling; nothing here has behaviour of its own.
typealias NetflixWebModel = ServiceWebModel
typealias NetflixWebView = ServiceWebView
typealias NetflixMenuActions = ServiceMenuActions

extension ServiceWebModel {
    /// The stable name of the Netflix website data on this Mac. Lives in the catalog; the value must never change.
    static var storeIdentifier: UUID { ProviderCatalog.netflix.storeIdentity.uuid }

    /// How many times a test process asked for the real Netflix store (always answered with an in-memory one).
    static var blockedProductionStoreRequests: Int { ProductionDataStoreProvider.blockedProductionStoreRequests[ProviderCatalog.netflix.id] ?? 0 }

    /// The store that holds the person's real Netflix sign-in (an in-memory one in a test process).
    static func productionStore() -> WKWebsiteDataStore { ProductionDataStoreProvider().store(for: ProviderCatalog.netflix) }

    /// The Netflix model the app uses.
    static func forApp() -> ServiceWebModel { forApp(ProviderCatalog.netflix) }
}
