import Foundation
import WebKit
@testable import REDDY

/// Shared helpers for the service model tests: fixture definitions that point a real catalog entry at the local server.
@MainActor enum ServiceTestSupport {
    /// A catalog service, with its address policy and start page replaced by the local fixture server (its link and store configuration kept).
    static func fixture(_ id: ProviderID, _ server: ServiceFixtureServer, path: String = "/home", tls: Bool = false) -> ProviderDefinition {
        let d = ProviderCatalog.all.first { $0.id == id }!
        return d.replacing(urlPolicy: ProviderURLPolicy(hostSuffixes: ["127.0.0.1"], inAppSchemes: [tls ? "https" : "http"], allowsAnyPort: true), homeURL: server.url(path))
    }

    static func until(_ timeout: Double = 30, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return true }; try? await Task.sleep(for: .milliseconds(40)) }
        return cond()
    }

    /// The ten services, in catalog order.
    static var all: [ProviderDefinition] { ProviderCatalog.all }
    /// The services that never leave the app.
    static var blocking: [ProviderDefinition] { ProviderCatalog.all.filter { $0.externalLinks == .blockWithNotice } }
}
