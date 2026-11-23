import Foundation

/// A per-service CLIENT PREFERENCE for region and language. StreamSetu stores it and shows it in Settings; it is never sent to the
/// network and never changes a request, a header, a cookie, a script or the page. It is not proof that the service is available to anyone.
/// Fixed in the catalog, so it does not follow the Mac's system region and never touches another service. Foundation only.
struct RegionProfile: Equatable, Sendable {
    /// ISO 3166-1 alpha-2 country code, uppercase.
    let preferredCountry: String
    /// A locale identifier such as "en_IN". Used only to format StreamSetu's own text for this service.
    let preferredLocaleIdentifier: String
    /// English wording key of the honest region note for this service (translated through the app's strings). Data only.
    let noteKey: String

    var preferredLocale: Locale { Locale(identifier: preferredLocaleIdentifier) }

    static let india = RegionProfile(
        preferredCountry: "IN", preferredLocaleIdentifier: "en_IN",
        noteKey: "The service decides availability from your network location. From outside India it may send StreamSetu to its own regional page, which is shown as a notice. StreamSetu does not change or hide your location.")

    /// A profile is well formed when the country is two uppercase letters and the locale identifier names that same country.
    var isWellFormed: Bool {
        preferredCountry.count == 2 && preferredCountry.allSatisfy { $0.isASCII && $0.isUppercase }
            && preferredLocaleIdentifier.hasSuffix("_" + preferredCountry) && !noteKey.isEmpty
    }
}

/// Where the network region would be recorded if anyone observed it. NOTHING in the app ever sets `.observed`: StreamSetu does not look
/// up an address, does not use location services and never infers a country. The default, and the only value the app produces, is `.unknown`.
enum NetworkRegionObservation: Equatable, Sendable {
    case unknown
    /// Reserved for a value a person enters by hand; never produced by the app.
    case observed(String)
}

/// Who decides whether the service is offered here. Always the service; StreamSetu holds no opinion.
enum ServiceRegionNote: Equatable, Sendable { case decidedByService }

/// Whether playback is allowed for this account here. Always the service's decision; the app never learns it by itself.
enum PlaybackEntitlement: Equatable, Sendable { case unknown, decidedByService }

/// The four SEPARATE answers about region. Only the first is configuration; none is derived from another, and the preference is never
/// evidence of eligibility.
struct RegionStatus: Equatable, Sendable {
    /// (1) What the person prefers for this service (client preference).
    let preferred: RegionProfile
    /// (2) What the network looks like: not observed by the app.
    var network: NetworkRegionObservation = .unknown
    /// (3) Whether the service offers itself here: the service's decision.
    var service: ServiceRegionNote = .decidedByService
    /// (4) Whether playback is permitted: the service's decision.
    var playback: PlaybackEntitlement = .decidedByService

    /// The status for a definition; nil for every service that declares no region profile. Reads nothing but the definition.
    static func of(_ d: ProviderDefinition) -> RegionStatus? { d.regionProfile.map { RegionStatus(preferred: $0) } }

    /// The four Settings lines, in order. Never says "verified", "eligible" or "available in your region".
    var lines: [String] {
        let country = preferred.preferredLocale.localizedString(forRegionCode: preferred.preferredCountry) ?? preferred.preferredCountry
        let network: String
        switch self.network {
        case .unknown: network = Localized.string("Network region: not checked by StreamSetu")
        case .observed(let code): network = Localized.string("Network region: %@ (entered by you)", code)
        }
        return [Localized.string("Preferred region: %@", "\(country) (\(preferred.preferredLocaleIdentifier))"),
                network,
                Localized.string("Service region: decided by the service"),
                Localized.string("Playback: decided by the service")]
    }
}

/// The only way a system region is ever read for streaming services. Present as a seam so a test can prove that a change of the Mac's region
/// (or any call at all) never alters a service's preference: no code path in the streaming layer reads it for a region.
typealias LocaleProvider = @Sendable () -> Locale
