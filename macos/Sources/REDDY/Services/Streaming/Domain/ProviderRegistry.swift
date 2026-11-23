import Foundation

enum RegistryIssue: Equatable, Sendable {
    case duplicateID(ProviderID)
    case duplicateStoreIdentity(ProviderID)
    case duplicateZoomKey(ProviderID)
    case homeURLNotHTTPS(ProviderID)
    case homeHostNotAllowed(ProviderID)
    case noHosts(ProviderID)
}

/// Every service the app knows, as data. Adding, removing or switching off a service is a registry change and nothing else.
struct ProviderRegistry: Sendable {
    let definitions: [ProviderDefinition]          // catalog order = default order

    static let standard = ProviderRegistry(definitions: ProviderCatalog.all)

    init(definitions: [ProviderDefinition]) { self.definitions = definitions }

    func definition(for id: ProviderID) -> ProviderDefinition? { definitions.first { $0.id == id } }

    /// Everything that is not merely `registered`, on this platform (disabled stays listed, with a badge).
    func listed(on platform: Platform) -> [ProviderDefinition] {
        definitions.filter { $0.availability.isListed && $0.platforms.contains(platform) }
    }

    static func validate(_ defs: [ProviderDefinition]) -> [RegistryIssue] {
        var issues: [RegistryIssue] = []
        var ids = Set<ProviderID>(), stores = Set<UUID>(), zooms = Set<String>()
        for d in defs {
            if !ids.insert(d.id).inserted { issues.append(.duplicateID(d.id)) }
            if !stores.insert(d.storeIdentity.uuid).inserted { issues.append(.duplicateStoreIdentity(d.id)) }
            if !zooms.insert(d.zoomDefaultsKey).inserted { issues.append(.duplicateZoomKey(d.id)) }
            if d.homeURL.scheme?.lowercased() != "https" { issues.append(.homeURLNotHTTPS(d.id)) }
            if d.urlPolicy.hostRules.filter(\.active).isEmpty { issues.append(.noHosts(d.id)) }
            if !d.urlPolicy.isAllowedHost(d.homeURL.host) { issues.append(.homeHostNotAllowed(d.id)) }
        }
        return issues
    }
}

/// The ONE place that says which platform shows which service. Everything else (top bar, menus, links, restored state, programmatic
/// routing) asks this value, so a platform without a service cannot reach it by any route.
struct ServiceCapabilities: Equatable, Sendable {
    var externalServices: [ProviderID]

    static let none = ServiceCapabilities(externalServices: [])
    static let macOS = ServiceCapabilities(externalServices: ProviderRegistry.standard.listed(on: .macOS).map(\.id))
    #if os(macOS)
    static let current = ServiceCapabilities.macOS
    #else
    static let current = ServiceCapabilities.none
    #endif

    func allows(_ service: ProviderID) -> Bool { externalServices.contains(service) }

    /// The three-field view of the service's capability matrix; nothing is claimed beyond "enabled for testing" or "needs a manual check".
    func profile(for service: ProviderID) -> ServiceCapabilityProfile {
        guard allows(service), let d = ProviderRegistry.standard.definition(for: service) else {
            return ServiceCapabilityProfile(websiteLoading: .unavailable, signIn: .unavailable, protectedPlayback: .unavailable)
        }
        return d.capabilities.legacyProfile
    }
}
