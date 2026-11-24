import Foundation

/// The service definitions as data. The ONLY place service names, addresses, hosts and store identifiers live.
/// Store identifiers were generated once and are frozen forever; each is pinned by a literal-equality test. Never derive one.
enum ProviderCatalog {
    private static let https: Set<String> = ["https"]
    private static func site(_ suffix: String) -> HostRule { HostRule(suffix: suffix, role: .site) }
    /// A sign-in host confirmed from public sources; still https, main-frame, exact registrable suffix only.
    private static func auth(_ suffix: String) -> HostRule { HostRule(suffix: suffix, role: .auth) }
    /// An exact host whose own pages are only the whole path segment "/in" (and below): the service's Indian web platform.
    private static func indiaPath(_ host: String) -> HostRule { HostRule(suffix: host, role: .site, exactHost: true, pathPrefixSegments: ["in"]) }
    private static func url(_ s: String) -> URL { URL(string: s)! }
    private static func record(_ s: CapabilityStatus, _ e: Evidence = .researchSnippet, _ note: String? = nil) -> CapabilityRecord<CapabilityStatus> { CapabilityRecord(s, evidence: e, noteKey: note) }

    /// Initial pins on a fresh install and after a reset (identical to the bar before the hub existed).
    static let defaultPinned: [ProviderID] = [.netflix]

    /// Unverified (every service but Netflix): embedded identically in every build, external links blocked with a notice.
    private static func unverified(id: ProviderID, name: String, home: String, store: StaticString, rules: [HostRule], cookies: [String],
                                   auth: CapabilityStatus = .manualVerificationRequired, authNote: String? = nil, mode: AuthenticationMode = .signInInApp,
                                   region: RegionNote, terms: String? = nil, release: String? = nil, userAgent: UserAgentProfile = .safari,
                                   availability: ServiceAvailability = .unverified, compat: CompatibilityResult = .unchecked,
                                   enhancements: Set<PageEnhancement> = [], regionProfile: RegionProfile? = nil, regionNotice: [RegionNoticeHost] = []) -> ProviderDefinition {
        ProviderDefinition(
            id: id, displayName: name, homeURL: url(home), availability: availability, distributionAuthorization: .unresolved, termsNote: terms,
            externalLinks: .blockWithNotice, platforms: [.macOS], storeIdentity: StoreIdentity(store),
            urlPolicy: ProviderURLPolicy(hostRules: rules + HostRule.googleSignIn, inAppSchemes: https, regionNoticeHosts: regionNotice),
            capabilities: CapabilityMatrix(websiteLoading: record(.enabledForTesting, .none), authentication: record(auth, .researchSnippet, authNote),
                                           protectedPlayback: record(.manualVerificationRequired, .none), distribution: CapabilityRecord(.unverified), compatibility: compat),
            authentication: mode, sessionCookieDomains: cookies, zoomDefault: 1.0, zoomDefaultsKey: "streaming.zoom.\(id.rawValue)", regionNote: region, releaseNote: release, userAgentProfile: userAgent, pageEnhancements: enhancements, regionProfile: regionProfile)
    }

    /// Owner-confirmed results (tested by the owner on his own Mac, Release builds); only the checks he confirmed carry an outcome.
    private static let checkedDay = "2026-11-22"
    private static func owner(_ build: String, _ passed: [CompatibilityResult.Check], failed: [CompatibilityResult.Check] = [], notApplicable: [CompatibilityResult.Check] = [], note: String = "owner-verified") -> CompatibilityResult {
        .ownerChecked(on: checkedDay, build: build, passed: passed, failed: failed, notApplicable: notApplicable, note: note)
    }

    static let netflix = ProviderDefinition(
        id: "netflix", displayName: "Netflix", homeURL: url("https://www.netflix.com/"), availability: .available, distributionAuthorization: .unresolved,
        termsNote: "No embedding clause and no grant recorded.", externalLinks: .confirmThenOpen, platforms: [.macOS],
        storeIdentity: StoreIdentity("afdfb6b8-2671-42a0-bd87-6973dcd90758"),
        urlPolicy: ProviderURLPolicy(hostRules: [site("netflix.com")] + HostRule.googleSignIn, inAppSchemes: https),
        capabilities: CapabilityMatrix(websiteLoading: record(.ownerVerified, .ownerCheck), authentication: record(.ownerVerified, .ownerCheck),
                                       protectedPlayback: record(.ownerVerified, .ownerCheck), distribution: CapabilityRecord(.unverified)),
        authentication: .signInInApp, sessionCookieDomains: ["netflix.com"], zoomDefault: 0.85, zoomDefaultsKey: "netflix.pageZoom", regionNote: .countryVariants, releaseNote: nil,
        userAgentProfile: .safari)

    static let primevideo = unverified(
        id: "primevideo", name: "Prime Video", home: "https://www.primevideo.com/", store: "e19483cc-c942-4b44-8aec-edc4a6a4c7dc",
        rules: [site("primevideo.com"), auth("amazon.com"), auth("amazon.in")], cookies: ["primevideo.com"],
        authNote: "auth.hostsUnverified", region: .countryVariants, terms: "Terms recorded from search snippets only.",
        availability: .available, compat: owner("Release 2.17.11", [.siteLoads, .signInPageRenders, .signInCompletes, .video]))
    static let disneyplus = unverified(
        id: "disneyplus", name: "Disney+", home: "https://www.disneyplus.com/", store: "eb14ffb5-2e9f-4629-8a99-6f700c8b3398",
        rules: [site("disneyplus.com"), auth("disneyid.com"), auth("jiohotstar.com"), auth("hotstar.com")], cookies: ["disneyplus.com"], authNote: "auth.hostsUnverified", region: .partnerRegions,
        terms: "Combined agreement does not list framing or embedding as authorised.",
        availability: .available, compat: owner("Release 2.17.10", [.siteLoads, .signInCompletes, .video]))
    static let hulu = unverified(
        id: "hulu", name: "Hulu", home: "https://www.hulu.com/", store: "32bc5ffc-0cdc-46d7-a7d4-bff3a25d0cca",
        rules: [site("hulu.com"), auth("disneyid.com"), HostRule(suffix: "disneyplus.com", role: .auth, active: false)], cookies: ["hulu.com"], region: .usOnly, terms: "Same combined agreement as the other service from that company.",
        release: "Redirects may change when the unified app launches; re-check.",
        availability: .available, compat: owner("Release 2.17.10", [.siteLoads, .signInCompletes, .video]))
    static let hbomax = unverified(
        id: "hbomax", name: "HBO Max", home: "https://www.hbomax.com/", store: "eac63ddd-0365-428e-b75a-5bf55799a0f6",
        rules: [site("hbomax.com"), site("max.com"), auth("auth.max.com")], cookies: ["hbomax.com"], region: .partnerRegions, terms: "Terms not retrieved.",
        release: "max.com was widened to a normal site address because scripted navigation to it while idle was being cancelled; now confirmed fixed.",
        availability: .available, compat: owner("Release 2.17.12", [.siteLoads, .signInPageRenders, .signInCompletes, .video]))
    static let peacock = unverified(
        id: "peacock", name: "Peacock", home: "https://www.peacocktv.com/", store: "320567c5-6338-46bd-8680-fedd1bab701f",
        rules: [site("peacocktv.com")], cookies: ["peacocktv.com"], region: .usOnly, terms: "Terms restrict frames and software applications.",
        availability: .available, compat: owner("Release 2.17.11", [.siteLoads, .signInCompletes, .video]))
    static let paramountplus = unverified(
        id: "paramountplus", name: "Paramount+", home: "https://www.paramountplus.com/", store: "862a68b0-ee28-4ebc-af6e-a8df1a592a83",
        rules: [site("paramountplus.com"), HostRule(suffix: "cbs.com", role: .auth, active: false)], cookies: ["paramountplus.com"], region: .usOnly, terms: "Terms prohibit framing in another application.",
        availability: .available, compat: owner("Release 2.17.11", [.siteLoads, .signInPageRenders, .signInCompletes, .video]))
    static let appletv = unverified(
        id: "appletv", name: "Apple TV", home: "https://tv.apple.com/", store: "61c40311-eeed-49f9-8a69-92ab863689c2",
        rules: [site("tv.apple.com"), auth("appleid.apple.com"), auth("idmsa.apple.com"), auth("account.apple.com")],
        cookies: ["tv.apple.com", "apple.com"], authNote: "auth.hostsUnverified", region: .countryVariants,
        availability: .available, compat: owner("Release 2.17.11", [.siteLoads, .signInPageRenders, .signInCompletes, .video]))
    static let youtube = unverified(
        id: "youtube", name: "YouTube", home: "https://www.youtube.com/", store: "20bed3f7-5bc0-46f4-ade6-bce2f57350db",
        rules: [site("youtube.com"), HostRule(suffix: "youtu.be", role: .redirectOnly),
               HostRule(suffix: "consent.google.com", role: .redirectOnly)], cookies: ["youtube.com"],
        authNote: "auth.hostsUnverified", region: .countryVariants,
        release: "Sign in with Google is allowed; the service also works signed out. Google sign-in has not been checked yet.",
        availability: .available, compat: owner("Release 2.17.11", [.siteLoads, .video], note: "signed-out checks only; Google sign-in not yet checked"),
        enhancements: [.adSkip, .sponsorSkip])
    static let crunchyroll = unverified(
        id: "crunchyroll", name: "Crunchyroll", home: "https://www.crunchyroll.com/", store: "84d233c6-bd18-4367-b759-6e8b206e5b84",
        rules: [site("crunchyroll.com")], cookies: ["crunchyroll.com"], region: .countryVariants, terms: "Terms not retrievable.",
        availability: .available, compat: owner("Release 2.17.11", [.siteLoads, .signInPageRenders, .signInCompletes, .video]))

    /// Spotify web player. Sign-in is the service's own email/username and password form on accounts.spotify.com (same registrable domain, so one
    /// site rule covers the player, the sign-in pages and the account pages). Google's sign-in hosts are in the shared group every service has;
    /// Apple and Facebook sign-in hosts are NOT allowed, so those buttons do nothing here. Its CDNs (scdn.co, spotifycdn.com, audio hosts) and the captcha hosts load as sub-resources and
    /// frames, which the address policy does not gate, so they need no rule. spotify.link is the service's own link shortener (redirect hop only).
    static let spotify = unverified(
        id: "spotify", name: "Spotify", home: "https://open.spotify.com", store: "f00c305d-909f-420c-b11e-c7ce68a5a3e3",
        rules: [site("spotify.com"), HostRule(suffix: "spotify.link", role: .redirectOnly)], cookies: ["spotify.com"],
        authNote: "auth.hostsUnverified", region: .countryVariants,
        terms: "Terms and user guidelines prohibit blocking or circumventing ads; recorded as data only.",
        release: "Sign in with email or username and password, or with Google. Apple and Facebook sign-in are not offered.",
        enhancements: [.spotifyHideAds, .spotifyMuteAds])

    /// JioHotstar: the preference is India (en_IN), fixed here and independent of the Mac's region. It is a client preference only: availability and
    /// playback are decided by the service, the network region is not observed by the app, and nothing is spoofed or hidden. The service's official web
    /// platform is https://www.hotstar.com/in (jiohotstar.com is an official alias that redirects to it). Loadable: jiohotstar.com, and the EXACT hosts
    /// www.hotstar.com and hotstar.com under the whole path segment /in only. The service's country router (the bare root of those hosts) is admitted
    /// only as a redirect hop; a redirect to another two-letter country path on those hosts is the service's own regional page and is cancelled and
    /// shown as such; every other address (other paths, subdomains, lookalikes) is the app's own "Link blocked". Sign-in hosts for India cannot be
    /// seen from outside India and are not guessed. Auth-role hosts may overlap Disney+'s (separate web views and stores); an active SITE rule may not be shared.
    static let jiohotstar = unverified(
        id: "jiohotstar", name: "JioHotstar", home: "https://www.hotstar.com/in", store: "c64c1cf7-09c5-4d6a-882a-939c4396fa03",
        rules: [site("jiohotstar.com"), indiaPath("www.hotstar.com"), indiaPath("hotstar.com")],
        cookies: ["hotstar.com", "jiohotstar.com"], authNote: "auth.hostsUnverified", region: .countryVariants,
        terms: "Official terms bar concealing location and framing; recorded as data only. StreamSetu hides nothing.",
        release: RegionProfile.india.noteKey, availability: .registered, compat: .unchecked, regionProfile: .india,          // ON HOLD by the owner (2026-11-23): not listed, unreachable by any route; set back to .unverified to re-enable
        regionNotice: [RegionNoticeHost(host: "www.hotstar.com", pathPattern: RegionNoticeHost.countryPathExceptIn),
                       RegionNoticeHost(host: "hotstar.com", pathPattern: RegionNoticeHost.countryPathExceptIn)])

    /// Catalog order is the default order.
    static let all: [ProviderDefinition] = [netflix, primevideo, disneyplus, hulu, hbomax, peacock, paramountplus, appletv, youtube, crunchyroll, spotify, jiohotstar]
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
    static let spotify: ProviderID = "spotify"
    static let jiohotstar: ProviderID = "jiohotstar"
}
