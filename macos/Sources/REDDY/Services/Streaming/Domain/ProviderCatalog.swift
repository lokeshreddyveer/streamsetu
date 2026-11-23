import Foundation

/// The ten service definitions as data. The ONLY place service names, addresses, hosts and store identifiers live.
/// Store identifiers were generated once and are frozen forever; each is pinned by a literal-equality test. Never derive one.
enum ProviderCatalog {
    private static let https: Set<String> = ["https"]
    private static func site(_ suffix: String) -> HostRule { HostRule(suffix: suffix, role: .site) }
    /// A sign-in host confirmed from public sources; still https, main-frame, exact registrable suffix only.
    private static func auth(_ suffix: String) -> HostRule { HostRule(suffix: suffix, role: .auth) }
    private static func url(_ s: String) -> URL { URL(string: s)! }
    private static func record(_ s: CapabilityStatus, _ e: Evidence = .researchSnippet, _ note: String? = nil) -> CapabilityRecord<CapabilityStatus> { CapabilityRecord(s, evidence: e, noteKey: note) }

    /// Initial pins on a fresh install and after a reset (identical to the bar before the hub existed).
    static let defaultPinned: [ProviderID] = [.netflix]

    /// Unverified (nine new services): embedded identically in every build, external links blocked with a notice.
    private static func unverified(id: ProviderID, name: String, home: String, store: StaticString, rules: [HostRule], cookies: [String],
                                   auth: CapabilityStatus = .manualVerificationRequired, authNote: String? = nil, mode: AuthenticationMode = .signInInApp,
                                   region: RegionNote, terms: String? = nil, release: String? = nil) -> ProviderDefinition {
        ProviderDefinition(
            id: id, displayName: name, homeURL: url(home), availability: .unverified, distributionAuthorization: .unresolved, termsNote: terms,
            externalLinks: .blockWithNotice, platforms: [.macOS], storeIdentity: StoreIdentity(store),
            urlPolicy: ProviderURLPolicy(hostRules: rules, inAppSchemes: https),
            capabilities: CapabilityMatrix(websiteLoading: record(.enabledForTesting, .none), authentication: record(auth, .researchSnippet, authNote),
                                           protectedPlayback: record(.manualVerificationRequired, .none), distribution: CapabilityRecord(.unverified)),
            authentication: mode, sessionCookieDomains: cookies, zoomDefault: 1.0, zoomDefaultsKey: "streaming.zoom.\(id.rawValue)", regionNote: region, releaseNote: release)
    }

    static let netflix = ProviderDefinition(
        id: "netflix", displayName: "Netflix", homeURL: url("https://www.netflix.com/"), availability: .available, distributionAuthorization: .unresolved,
        termsNote: "No embedding clause and no grant recorded.", externalLinks: .confirmThenOpen, platforms: [.macOS],
        storeIdentity: StoreIdentity("afdfb6b8-2671-42a0-bd87-6973dcd90758"),
        urlPolicy: ProviderURLPolicy(hostRules: [site("netflix.com")], inAppSchemes: https),
        capabilities: CapabilityMatrix(websiteLoading: record(.ownerVerified, .ownerCheck), authentication: record(.ownerVerified, .ownerCheck),
                                       protectedPlayback: record(.ownerVerified, .ownerCheck), distribution: CapabilityRecord(.unverified)),
        authentication: .signInInApp, sessionCookieDomains: ["netflix.com"], zoomDefault: 0.85, zoomDefaultsKey: "netflix.pageZoom", regionNote: .countryVariants, releaseNote: nil)

    static let primevideo = unverified(
        id: "primevideo", name: "Prime Video", home: "https://www.primevideo.com/", store: "e19483cc-c942-4b44-8aec-edc4a6a4c7dc",
        rules: [site("primevideo.com"), auth("amazon.com"), auth("amazon.in")], cookies: ["primevideo.com"],
        authNote: "auth.hostsUnverified", region: .countryVariants, terms: "Terms recorded from search snippets only.")
    static let disneyplus = unverified(
        id: "disneyplus", name: "Disney+", home: "https://www.disneyplus.com/", store: "eb14ffb5-2e9f-4629-8a99-6f700c8b3398",
        rules: [site("disneyplus.com"), auth("disneyid.com"), auth("jiohotstar.com"), auth("hotstar.com")], cookies: ["disneyplus.com"], authNote: "auth.hostsUnverified", region: .partnerRegions,
        terms: "Combined agreement does not list framing or embedding as authorised.")
    static let hulu = unverified(
        id: "hulu", name: "Hulu", home: "https://www.hulu.com/", store: "32bc5ffc-0cdc-46d7-a7d4-bff3a25d0cca",
        rules: [site("hulu.com"), auth("disneyid.com"), HostRule(suffix: "disneyplus.com", role: .auth, active: false)], cookies: ["hulu.com"], region: .usOnly, terms: "Same combined agreement as the other service from that company.",
        release: "Redirects may change when the unified app launches; re-check.")
    static let hbomax = unverified(
        id: "hbomax", name: "HBO Max", home: "https://www.hbomax.com/", store: "eac63ddd-0365-428e-b75a-5bf55799a0f6",
        rules: [site("hbomax.com"), HostRule(suffix: "max.com", role: .redirectOnly), auth("auth.max.com")], cookies: ["hbomax.com"], region: .partnerRegions, terms: "Terms not retrieved.")
    static let peacock = unverified(
        id: "peacock", name: "Peacock", home: "https://www.peacocktv.com/", store: "320567c5-6338-46bd-8680-fedd1bab701f",
        rules: [site("peacocktv.com")], cookies: ["peacocktv.com"], region: .usOnly, terms: "Terms restrict frames and software applications.")
    static let paramountplus = unverified(
        id: "paramountplus", name: "Paramount+", home: "https://www.paramountplus.com/", store: "862a68b0-ee28-4ebc-af6e-a8df1a592a83",
        rules: [site("paramountplus.com"), HostRule(suffix: "cbs.com", role: .auth, active: false)], cookies: ["paramountplus.com"], region: .usOnly, terms: "Terms prohibit framing in another application.")
    static let appletv = unverified(
        id: "appletv", name: "Apple TV", home: "https://tv.apple.com/", store: "61c40311-eeed-49f9-8a69-92ab863689c2",
        rules: [site("tv.apple.com"), auth("appleid.apple.com"), auth("idmsa.apple.com"), auth("account.apple.com")],
        cookies: ["tv.apple.com", "apple.com"], authNote: "auth.hostsUnverified", region: .countryVariants)
    static let youtube = unverified(
        id: "youtube", name: "YouTube", home: "https://www.youtube.com/", store: "20bed3f7-5bc0-46f4-ade6-bce2f57350db",
        rules: [site("youtube.com"), HostRule(suffix: "youtu.be", role: .redirectOnly)], cookies: ["youtube.com"],
        auth: .unsupported, authNote: "auth.googleSignInNotSupported", mode: .signedOutOnly, region: .countryVariants,
        release: "Google sign-in hosts are not allowed; the service is used signed out.")
    static let crunchyroll = unverified(
        id: "crunchyroll", name: "Crunchyroll", home: "https://www.crunchyroll.com/", store: "84d233c6-bd18-4367-b759-6e8b206e5b84",
        rules: [site("crunchyroll.com")], cookies: ["crunchyroll.com"], region: .countryVariants, terms: "Terms not retrievable.")

    /// Catalog order is the default order.
    static let all: [ProviderDefinition] = [netflix, primevideo, disneyplus, hulu, hbomax, peacock, paramountplus, appletv, youtube, crunchyroll]
}

extension ProviderID {
    static let netflix: ProviderID = "netflix"
    static let primevideo: ProviderID = "primevideo"
    static let disneyplus: ProviderID = "disneyplus"
    static let hulu: ProviderID = "hulu"
    static let hbomax: ProviderID = "hbomax"
    static let peacock: ProviderID = "peacock"
    static let paramountplus: ProviderID = "paramountplus"
    static let appletv: ProviderID = "appletv"
    static let youtube: ProviderID = "youtube"
    static let crunchyroll: ProviderID = "crunchyroll"
}
