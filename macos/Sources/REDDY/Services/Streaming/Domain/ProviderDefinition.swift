import Foundation

enum Platform: Sendable { case macOS }

/// The registry switch. Independent of every other field; flipping one entry changes one service and nothing else.
enum ServiceAvailability: String, Sendable {
    /// Defined but not offered (staging): not listed, unreachable by any route.
    case registered
    /// Embedded; verified working by the owner.
    case available
    /// Embedded; compatibility not yet established.
    case unverified
    /// Listed with a badge but not offered: shows the native "unavailable" screen.
    case disabled

    enum Presentation: Equatable, Sendable { case embedded, integrationUnavailable, hidden }
    var presentation: Presentation {
        switch self {
        case .available, .unverified: .embedded
        case .disabled: .integrationUnavailable
        case .registered: .hidden
        }
    }
    var isListed: Bool { self != .registered }
}

/// What happens when a page links outside the service. Configuration, not a provider conditional.
enum ExternalLinkPolicy: String, Sendable { case confirmThenOpen, blockWithNotice }

/// Recorded decision data only; nothing gates on it.
enum DistributionAuthorization: String, Sendable { case confirmed, unresolved }

enum AuthenticationMode: String, Sendable { case signInInApp, signedOutOnly }

enum RegionNote: String, Sendable { case usOnly, countryVariants, partnerRegions }

/// A literal data-store identifier. Derived or hashed ids are forbidden: the id is frozen once shipped.
struct StoreIdentity: Equatable, Sendable {
    let uuid: UUID
    init(_ literal: StaticString) {
        guard let u = UUID(uuidString: "\(literal)") else { preconditionFailure("invalid store identity literal") }
        uuid = u
    }
}

/// How the embedded service identifies itself. `.safari` sets only WebKit's application-name part so the default string reads as Safari; `.webKitDefault` changes nothing.
enum UserAgentProfile: String, Sendable { case webKitDefault, safari }

/// Configuration only: no credentials, no tokens, no behaviour.
struct ProviderDefinition: Equatable, Sendable, Identifiable {
    let id: ProviderID
    let displayName: String
    let homeURL: URL
    let availability: ServiceAvailability
    let distributionAuthorization: DistributionAuthorization
    let termsNote: String?
    let externalLinks: ExternalLinkPolicy
    let platforms: Set<Platform>
    let storeIdentity: StoreIdentity
    let urlPolicy: ProviderURLPolicy
    let capabilities: CapabilityMatrix
    let authentication: AuthenticationMode
    /// Domains whose presence means "a session exists" (yes or no only; never names or values).
    let sessionCookieDomains: [String]
    let zoomDefault: Double
    let zoomDefaultsKey: String
    let regionNote: RegionNote?
    let releaseNote: String?
    var userAgentProfile: UserAgentProfile = .safari
    /// Optional page additions this service supports (all off until a person enables and agrees to each). Empty for every service but the one that declares them.
    var pageEnhancements: Set<PageEnhancement> = []
    /// A fixed client preference for region and language (nil for every service that declares none). Never sent anywhere and never proof of eligibility.
    var regionProfile: RegionProfile? = nil

    /// The provider's own regional pages (exact hosts), kept with the address policy that applies them. Empty for every service but one.
    var regionNoticeHosts: [RegionNoticeHost] { urlPolicy.regionNoticeHosts }

    var presentation: ServiceAvailability.Presentation { availability.presentation }
}
