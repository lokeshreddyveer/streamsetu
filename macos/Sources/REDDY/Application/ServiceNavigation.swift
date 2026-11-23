import Foundation
import Observation

// `ProviderID` (still typealiased as `ExternalService`), `ServiceCapabilities` and the capability types live in Services/Streaming/Domain. No WebKit or
// AppKit here: this file is compiled for every Apple platform, and only `ServiceCapabilities` decides where a service is switched on.

/// Which top-level destination is showing: the app's own screens (Home, Live TV, Movies, Series, TV Guide, held by `AppRouter.tab`) or one service.
enum TopLevelDestination: Equatable, Sendable {
    case streamSetu
    case service(ProviderID)

    var rawValue: String { switch self { case .streamSetu: "streamSetu"; case .service(let s): "service." + s.rawValue } }
}

/// The destination state machine, pure. The last native section is not copied here: it is `AppRouter.tab`, which nothing touches
/// while a service is active.
struct DestinationState: Equatable, Sendable {
    private(set) var active: TopLevelDestination = .streamSetu
    let capabilities: ServiceCapabilities

    init(capabilities: ServiceCapabilities = .current) { self.capabilities = capabilities }

    /// Decodes a stored or received destination. Anything unknown, or a service this platform does not have, becomes StreamSetu.
    init(rawValue: String?, capabilities: ServiceCapabilities = .current) {
        self.capabilities = capabilities
        if let raw = rawValue, raw.hasPrefix("service."), let s = ProviderID(rawValue: String(raw.dropFirst(8))), capabilities.allows(s) { active = .service(s) }
    }

    /// The five native tabs are shown (derived, never stored separately).
    var navExpanded: Bool { active == .streamSetu }
    var activeService: ProviderID? { if case .service(let s) = active { s } else { nil } }

    /// Returns false (and changes nothing) when the platform does not have the service.
    @discardableResult mutating func select(_ service: ProviderID) -> Bool {
        guard capabilities.allows(service) else { return false }
        active = .service(service); return true
    }
    mutating func selectStreamSetu() { active = .streamSetu }
}

/// What a platform provides to host a service's content (the macOS one wraps a web view). Shared code only talks to this.
@MainActor protocol ExternalServiceHost: AnyObject {
    func serviceBecameVisible()
    /// Hidden or replaced by the native player: stop its media.
    func serviceBecameHidden()
    func openInDefaultBrowser()
    func clearServiceData() async
    /// Free what a hidden service holds (memory pressure, long idle).
    func releaseResources()
}

/// Finds the host of one service (the macOS registry of web models). Shared code never sees WebKit.
@MainActor protocol ServiceHostResolving: AnyObject {
    func host(for id: ProviderID) -> (any ExternalServiceHost)?
}

/// Owner of the destination state. Every route into a service (top bar, menu, shortcut, link, restored state, Setu) goes through `select`,
/// which checks the platform's capabilities; every native navigation goes back through the router hook.
@MainActor @Observable
final class ServiceNavigation {
    private(set) var state: DestinationState
    /// The registry that resolves each service's host. Choosing one service while another shows hides the other first.
    @ObservationIgnored weak var hosts: (any ServiceHostResolving)?
    /// Single-host hook kept until the registry is wired: serves Netflix only.
    @ObservationIgnored weak var host: (any ExternalServiceHost)?
    /// Set by the app: true while a Kids profile is in use or the app is locked. A blocked platform state refuses every route into a service.
    @ObservationIgnored var gate: () -> Bool = { false }

    init(capabilities: ServiceCapabilities = .current) { state = DestinationState(capabilities: capabilities) }

    var capabilities: ServiceCapabilities { state.capabilities }
    var active: TopLevelDestination { state.active }
    var navExpanded: Bool { state.navExpanded }
    var activeService: ProviderID? { state.activeService }
    var services: [ProviderID] { state.capabilities.externalServices }

    var isBlocked: Bool { gate() }

    private func resolve(_ id: ProviderID) -> (any ExternalServiceHost)? {
        if let hosts { return hosts.host(for: id) }
        return id == .netflix ? host : nil
    }

    @discardableResult func select(_ service: ProviderID) -> Bool {
        guard !gate() else { return false }
        let previous = state.activeService
        guard state.select(service) else { return false }
        if let previous, previous != service { resolve(previous)?.serviceBecameHidden() }          // service to service: the old one stops first
        resolve(service)?.serviceBecameVisible(); return true
    }

    /// Restored or received destination text: only valid, enabled destinations take effect.
    @discardableResult func restore(_ raw: String?) -> Bool {
        let d = DestinationState(rawValue: raw, capabilities: state.capabilities)
        guard let s = d.activeService else { return false }
        return select(s)
    }

    func returnToStreamSetu() {
        guard let previous = state.activeService else { return }
        state.selectStreamSetu()
        resolve(previous)?.serviceBecameHidden()
    }

    /// Native navigation (a tab, a title, a search result, a link) always leaves the service first.
    func attach(to router: AppRouter) { router.onNavigate = { [weak self] in self?.returnToStreamSetu() } }
}
