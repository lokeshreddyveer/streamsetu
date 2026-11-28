import Foundation
import Observation

// `ProviderID` (still typealiased as `ExternalService`), `ServiceCapabilities` and the capability types live in Services/Streaming/Domain. No WebKit or
// AppKit here: this file is compiled for every Apple platform, and only `ServiceCapabilities` decides where a service is switched on.

/// Which top-level destination is showing: the app's own screens (Home, Live TV, Movies, Series, TV Guide, held by `AppRouter.tab`) or one service.
enum TopLevelDestination: Equatable, Sendable {
    case streamSetu
    /// StreamSetu's own Podcasts screen (a native destination without a sidebar). It is not an `AppTab`: the five tabs keep their meaning.
    case podcasts
    /// StreamSetu's own Music screen (a native destination with its own sidebar inside the page).
    case music
    case service(ProviderID)

    var rawValue: String { switch self { case .streamSetu: "streamSetu"; case .podcasts: "podcasts"; case .music: "music"; case .service(let s): "service." + s.rawValue } }
    /// StreamSetu's own screens (a tab or Podcasts), as opposed to a service's website.
    var isNative: Bool { if case .service = self { false } else { true } }
}

/// The destination state machine, pure. The last native section is not copied here: it is `AppRouter.tab`, which nothing touches
/// while a service is active.
struct DestinationState: Equatable, Sendable {
    private(set) var active: TopLevelDestination = .streamSetu
    /// The native destination to return to from a service (`.streamSetu` means the last tab, which `AppRouter.tab` holds; `.podcasts` means Podcasts).
    private(set) var lastNative: TopLevelDestination = .streamSetu
    let capabilities: ServiceCapabilities

    init(capabilities: ServiceCapabilities = .current) { self.capabilities = capabilities }

    /// Decodes a stored or received destination. Anything unknown, or a service this platform does not have, becomes StreamSetu.
    init(rawValue: String?, capabilities: ServiceCapabilities = .current) {
        self.capabilities = capabilities
        if rawValue == "podcasts" { active = .podcasts; lastNative = .podcasts }
        else if rawValue == "music" { active = .music; lastNative = .music }
        else if let raw = rawValue, raw.hasPrefix("service."), let s = ProviderID(rawValue: String(raw.dropFirst(8))), capabilities.allows(s) { active = .service(s) }
    }

    /// StreamSetu's own screens are showing (a tab or Podcasts): the bottom player and the assistant belong to them (derived, never stored separately).
    var navExpanded: Bool { active.isNative }
    /// The sidebar and the five tabs' screens are showing (not Podcasts, which has its own layout).
    var showsTabs: Bool { active == .streamSetu }
    var activeService: ProviderID? { if case .service(let s) = active { s } else { nil } }

    /// Returns false (and changes nothing) when the platform does not have the service.
    @discardableResult mutating func select(_ service: ProviderID) -> Bool {
        guard capabilities.allows(service) else { return false }
        if active.isNative { lastNative = active }
        active = .service(service); return true
    }
    /// Native navigation to a tab (or any native screen other than Podcasts).
    mutating func selectStreamSetu() { active = .streamSetu; lastNative = .streamSetu }
    mutating func selectPodcasts() { active = .podcasts; lastNative = .podcasts }
    mutating func selectMusic() { active = .music; lastNative = .music }
    /// Leaving a service: back to the native destination that was open before it.
    mutating func returnFromService() { guard activeService != nil else { return }; active = lastNative }
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
    /// True while the app is locked: Podcasts, like every other screen, cannot be opened then.
    @ObservationIgnored var lockGate: () -> Bool = { false }
    /// True while a Kids profile is in use. Podcasts (the public directory is unfiltered) is refused and hidden then: top bar, Services list, the
    /// Navigate command, `router.go(.podcasts)` and every direct open all go through `podcastsAllowed`.
    @ObservationIgnored var kidsGate: () -> Bool = { false }

    init(capabilities: ServiceCapabilities = .current) { state = DestinationState(capabilities: capabilities) }

    var capabilities: ServiceCapabilities { state.capabilities }
    var active: TopLevelDestination { state.active }
    var navExpanded: Bool { state.navExpanded }
    var showsTabs: Bool { state.showsTabs }
    var activeService: ProviderID? { state.activeService }
    var services: [ProviderID] { state.capabilities.externalServices }

    var isBlocked: Bool { gate() }
    /// The one rule for Podcasts: not while the app is locked and not for a Kids profile.
    var podcastsAllowed: Bool { !lockGate() && !kidsGate() }
    /// The one rule for Music: the same as Podcasts (not while locked, not for a Kids profile).
    var musicAllowed: Bool { !lockGate() && !kidsGate() }
    /// A Kids profile is in use (Podcasts is then not offered anywhere).
    var isKidsProfile: Bool { kidsGate() }

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

    /// Opens Podcasts in the main window. Refused while the app is locked or a Kids profile is in use. A service that was showing stops first.
    @discardableResult func selectPodcasts() -> Bool {
        guard podcastsAllowed else { return false }
        let previous = state.activeService
        state.selectPodcasts()
        if let previous { resolve(previous)?.serviceBecameHidden() }
        return true
    }

    /// Opens Music in the main window. Refused while the app is locked or a Kids profile is in use. A service that was showing stops first.
    @discardableResult func selectMusic() -> Bool {
        guard musicAllowed else { return false }
        let previous = state.activeService
        state.selectMusic()
        if let previous { resolve(previous)?.serviceBecameHidden() }
        return true
    }

    /// From a service back to where StreamSetu was (the last tab, or Podcasts). Does nothing when no service shows.
    func returnToStreamSetu() {
        guard let previous = state.activeService else { return }
        state.returnFromService()
        resolve(previous)?.serviceBecameHidden()
    }

    /// A profile switch to Kids while Podcasts is open: leave it (nothing else changes).
    func enforcePodcastsRule() { if state.active == .podcasts, !podcastsAllowed { leaveForTab() } }
    /// The same for Music.
    func enforceMusicRule() { if state.active == .music, !musicAllowed { leaveForTab() } }

    /// Native navigation (a tab, a title, a search result, a link) always leaves a service or Podcasts first.
    func leaveForTab() {
        guard state.active != .streamSetu else { return }
        let previous = state.activeService
        state.selectStreamSetu()
        if let previous { resolve(previous)?.serviceBecameHidden() }
    }

    func attach(to router: AppRouter) {
        router.onNavigate = { [weak self] in self?.leaveForTab() }
        router.onOpenPodcasts = { [weak self] in self?.selectPodcasts() }
        router.onOpenMusic = { [weak self] in self?.selectMusic() }
    }
}
