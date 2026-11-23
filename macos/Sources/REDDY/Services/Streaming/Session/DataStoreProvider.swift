import WebKit

/// True inside a test process (XCTest or Swift Testing).
enum TestProcess {
    static var isRunning: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil || NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.processName.contains("xctest") || ProcessInfo.processInfo.processName.contains("swiftpm-testing")
    }
}

/// Gives each service its own website data store. Separate stores separate cookies and storage; they do not separate processes.
@MainActor protocol DataStoreProvider {
    func store(for definition: ProviderDefinition) -> WKWebsiteDataStore
}

/// The stores that hold the person's real sign-ins: one named store per service, made on first use. A test process can never get one: it is
/// handed an in-memory store instead (and the request is counted), so no test can read, change or clear a real session.
struct ProductionDataStoreProvider: DataStoreProvider {
    nonisolated(unsafe) private static var blocked: [ProviderID: Int] = [:]
    /// How many times a test process asked for a service's real store.
    static var blockedProductionStoreRequests: [ProviderID: Int] { blocked }

    func store(for definition: ProviderDefinition) -> WKWebsiteDataStore {
        if TestProcess.isRunning { Self.blocked[definition.id, default: 0] += 1; return .nonPersistent() }
        return WKWebsiteDataStore(forIdentifier: definition.storeIdentity.uuid)
    }
}

/// The made-on-first-use store of one model (the same store for the model's whole life).
@MainActor final class LazyDataStore {
    private let make: () -> WKWebsiteDataStore
    private(set) lazy var value: WKWebsiteDataStore = make()
    init(_ make: @escaping () -> WKWebsiteDataStore) { self.make = make }
}
