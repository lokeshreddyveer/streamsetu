import Testing
import WebKit
import AppKit
@testable import REDDY

/// JioHotstar's region preference is a fixed client preference: it never follows the Mac's region, never reaches the network, never touches another
/// service, and is never reported as proof of availability. Local fixtures and in-memory or random-identifier stores only.
@Suite("Region profile", .serialized) @MainActor struct RegionProfileTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "reddy-region-\(UUID().uuidString)")! }
    private let reg = ProviderRegistry.standard
    private var jio: ProviderDefinition { reg.definition(for: .jiohotstar)! }

    // MARK: preference

    @Test func theJioHotstarPreferenceIsAlwaysIndiaAndEnglishIndia() {
        #expect(jio.regionProfile == RegionProfile.india)
        #expect(jio.regionProfile?.preferredCountry == "IN" && jio.regionProfile?.preferredLocaleIdentifier == "en_IN")
        #expect(jio.regionProfile?.preferredLocale.identifier == "en_IN" && jio.regionProfile?.isWellFormed == true)
    }

    @Test func aChangeOfTheSystemRegionNeverChangesAPreferenceAndTheSystemLocaleIsNeverConsulted() {
        let calls = Counter()
        var baseline: [String]?
        for id in ["en_US", "en_IN", "de_DE", "hi_IN", "fr_CA", "ja_JP"] {
            let m = StreamingServicesSettingsModel(defaults: defaults(), systemLocale: { calls.bump(); return Locale(identifier: id) })
            #expect(m.rows.first { $0.id == .jiohotstar } == nil, "on hold: no Settings row")
            let lines = RegionStatus.of(ProviderRegistry.standard.definition(for: .jiohotstar)!)!.lines
            #expect(lines.count == 4 && lines[0].contains("India") && lines[0].contains("en_IN"), Comment(rawValue: id))
            if let b = baseline { #expect(lines == b, "same four lines for \(id)") } else { baseline = lines }
            #expect(ProviderRegistry.standard.definition(for: .jiohotstar)?.regionProfile == .india)
            for other in m.rows where other.id != .jiohotstar { #expect(other.regionLines.isEmpty, Comment(rawValue: "\(other.id)")) }
        }
        #expect(calls.value == 0, "no region is ever read from the system locale")
    }

    @Test func everyOtherDefinitionHasNoRegionProfile() {
        for d in reg.definitions where d.id != .jiohotstar { #expect(d.regionProfile == nil, Comment(rawValue: "\(d.id)")) }
        #expect(reg.definitions.filter { $0.regionProfile != nil }.map(\.id) == [.jiohotstar])
    }

    /// The ten earlier definitions, frozen: ids, store identifiers, hosts (with roles and active flags), start page, zoom key, agent profile.
    private static let frozen: [(String, String, String, String, [HostRule])] = [
        ("netflix", "afdfb6b8-2671-42a0-bd87-6973dcd90758", "https://www.netflix.com/", "netflix.pageZoom", [HostRule(suffix: "netflix.com", role: .site)]),
        ("primevideo", "e19483cc-c942-4b44-8aec-edc4a6a4c7dc", "https://www.primevideo.com/", "streaming.zoom.primevideo",
         [HostRule(suffix: "primevideo.com", role: .site), HostRule(suffix: "amazon.com", role: .auth), HostRule(suffix: "amazon.in", role: .auth)]),
        ("disneyplus", "eb14ffb5-2e9f-4629-8a99-6f700c8b3398", "https://www.disneyplus.com/", "streaming.zoom.disneyplus",
         [HostRule(suffix: "disneyplus.com", role: .site), HostRule(suffix: "disneyid.com", role: .auth), HostRule(suffix: "jiohotstar.com", role: .auth), HostRule(suffix: "hotstar.com", role: .auth)]),
        ("hulu", "32bc5ffc-0cdc-46d7-a7d4-bff3a25d0cca", "https://www.hulu.com/", "streaming.zoom.hulu",
         [HostRule(suffix: "hulu.com", role: .site), HostRule(suffix: "disneyid.com", role: .auth), HostRule(suffix: "disneyplus.com", role: .auth, active: false)]),
        ("hbomax", "eac63ddd-0365-428e-b75a-5bf55799a0f6", "https://www.hbomax.com/", "streaming.zoom.hbomax",
         [HostRule(suffix: "hbomax.com", role: .site), HostRule(suffix: "max.com", role: .site), HostRule(suffix: "auth.max.com", role: .auth)]),
        ("peacock", "320567c5-6338-46bd-8680-fedd1bab701f", "https://www.peacocktv.com/", "streaming.zoom.peacock", [HostRule(suffix: "peacocktv.com", role: .site)]),
        ("paramountplus", "862a68b0-ee28-4ebc-af6e-a8df1a592a83", "https://www.paramountplus.com/", "streaming.zoom.paramountplus",
         [HostRule(suffix: "paramountplus.com", role: .site), HostRule(suffix: "cbs.com", role: .auth, active: false)]),
        ("appletv", "61c40311-eeed-49f9-8a69-92ab863689c2", "https://tv.apple.com/", "streaming.zoom.appletv",
         [HostRule(suffix: "tv.apple.com", role: .site), HostRule(suffix: "appleid.apple.com", role: .auth), HostRule(suffix: "idmsa.apple.com", role: .auth), HostRule(suffix: "account.apple.com", role: .auth)]),
        ("youtube", "20bed3f7-5bc0-46f4-ade6-bce2f57350db", "https://www.youtube.com/", "streaming.zoom.youtube",
         [HostRule(suffix: "youtube.com", role: .site), HostRule(suffix: "youtu.be", role: .redirectOnly), HostRule(suffix: "consent.google.com", role: .redirectOnly)]),
        ("crunchyroll", "84d233c6-bd18-4367-b759-6e8b206e5b84", "https://www.crunchyroll.com/", "streaming.zoom.crunchyroll", [HostRule(suffix: "crunchyroll.com", role: .site)]),
    ]

    @Test func theTenEarlierDefinitionsAreUnchangedByTheNewService() {
        #expect(reg.definitions.prefix(10).map(\.id.rawValue) == Self.frozen.map(\.0))
        for (id, uuid, home, zoom, rules) in Self.frozen {
            let d = reg.definition(for: ProviderID(unchecked: id))!
            #expect(d.storeIdentity.uuid == UUID(uuidString: uuid), Comment(rawValue: id))
            #expect(d.homeURL.absoluteString == home && d.zoomDefaultsKey == zoom, Comment(rawValue: id))
            #expect(d.urlPolicy.hostRules == rules + HostRule.googleSignIn, Comment(rawValue: id))
            #expect(d.userAgentProfile == .safari && d.regionProfile == nil, Comment(rawValue: id))
        }
    }

    // MARK: JioHotstar's own configuration

    @Test func jioHotstarHasItsOwnStoreIdentifierZoomKeyAndAgentProfile() {
        #expect(jio.storeIdentity.uuid == UUID(uuidString: "c64c1cf7-09c5-4d6a-882a-939c4396fa03"))
        #expect(reg.definitions.filter { $0.storeIdentity.uuid == jio.storeIdentity.uuid }.count == 1)
        #expect(jio.zoomDefaultsKey == "streaming.zoom.jiohotstar" && jio.userAgentProfile == .safari)
        #expect(ProviderCatalog.netflix.storeIdentity.uuid == UUID(uuidString: "afdfb6b8-2671-42a0-bd87-6973dcd90758"))
        #expect(ServiceWebModel.storeIdentifier == UUID(uuidString: "afdfb6b8-2671-42a0-bd87-6973dcd90758"))
        let provider = TestIsolatedDataStoreProvider()
        #expect(provider.store(for: jio) !== provider.store(for: ProviderCatalog.netflix))
        #expect(!ProductionDataStoreProvider().store(for: jio).isPersistent, "a test process never gets a real store")
    }

    @Test func clearingJioHotstarDataCannotTouchAnotherService() async throws {
        _ = NSApplication.shared
        let server = try ServiceFixtureServer(); try await server.start(); defer { server.stop() }
        let idA = UUID(), idB = UUID()
        defer { Task { await TestIsolatedDataStoreProvider.removeFixture(idA); await TestIsolatedDataStoreProvider.removeFixture(idB) } }
        func cookie(_ n: String) -> HTTPCookie { HTTPCookie(properties: [.name: n, .value: "v", .domain: "127.0.0.1", .path: "/", .expires: Date().addingTimeInterval(3600)])! }
        let a = ServiceWebModel(definition: ServiceTestSupport.fixture(.jiohotstar, server), dataStoreProvider: TestIsolatedDataStoreProvider(persistentFixture: idA))
        let b = ServiceWebModel(definition: ServiceTestSupport.fixture(.netflix, server), dataStoreProvider: TestIsolatedDataStoreProvider(persistentFixture: idB))
        await a.dataStore.httpCookieStore.setCookie(cookie("jio")); await b.dataStore.httpCookieStore.setCookie(cookie("keep"))
        await a.clearServiceData()
        let aLeft = await a.dataStore.httpCookieStore.allCookies().count, bLeft = await b.dataStore.httpCookieStore.allCookies().count
        #expect(aLeft == 0); #expect(bLeft == 1, "the other service stays signed in")
        a.releaseResources(); b.releaseResources()
        _ = await SessionClearing.clear(b.dataStore)
    }

    // MARK: navigation policy

    @Test func siteHostsAreAllowedAndLookalikesPlainHTTPAndInactiveHostsAreNot() {
        let p = jio.urlPolicy
        func d(_ u: String) -> ProviderURLPolicy.Decision { p.decide(URL(string: u), isMainFrame: true) }
        for u in ["https://www.jiohotstar.com/", "https://jiohotstar.com/", "https://help.jiohotstar.com/", "https://www.hotstar.com/in", "https://hotstar.com/in/home"] { #expect(d(u) == .allowInApp, Comment(rawValue: u)) }
        for u in ["https://evil-hotstar.com/", "https://hotstar.com.evil.test/", "https://jiohotstar.com.evil.test/", "https://evilhotstar.com/", "https://www.disneyplus.com/", "https://hotstar.com/", "https://help.hotstar.com/in",
                  "https://www.hotstar.com/us", "https://accounts.jio.com/login", "https://www.jio.com/", "https://jio.com.evil.test/", "https://notjiohotstar.com/"] {
            #expect(d(u) == .openExternally, Comment(rawValue: u))
        }
        #expect(d("http://www.hotstar.com/in") != .allowInApp && d("http://www.jiohotstar.com/") != .allowInApp)
        #expect(d("https://user:pw@www.hotstar.com/in") == .block && d("https://www.hotstar.com@evil.test/in") == .block)
        #expect(p.hostSuffixes == ["jiohotstar.com", "www.hotstar.com", "hotstar.com"] + HostRule.googleSignInHosts && p.inAppSchemes == ["https"])
        #expect(jio.externalLinks == .blockWithNotice)
    }

    @Test func disneyPlusKeepsItsOwnRulesExactlyAndSharingAnAuthHostIsAllowed() {
        let disney = reg.definition(for: .disneyplus)!
        #expect(disney.urlPolicy.hostRules.filter { $0.role == .auth && $0.active }.map(\.suffix) == ["disneyid.com", "jiohotstar.com", "hotstar.com"] + HostRule.googleSignInHosts)
        #expect(ProviderRegistry.validate(reg.definitions).isEmpty, "auth-role overlap with Disney+ is allowed: separate web views and stores")
    }

    @Test func twoServicesCannotShareAnActiveSiteHostAndABadProfileIsFound() {
        let j = ProviderCatalog.jiohotstar, h = ProviderCatalog.hulu
        func with(_ d: ProviderDefinition, rules: [HostRule], store: StaticString, zoom: String, region: RegionProfile?) -> ProviderDefinition {
            ProviderDefinition(id: d.id, displayName: d.displayName, homeURL: d.homeURL, availability: d.availability, distributionAuthorization: d.distributionAuthorization, termsNote: d.termsNote,
                               externalLinks: d.externalLinks, platforms: d.platforms, storeIdentity: StoreIdentity(store),
                               urlPolicy: ProviderURLPolicy(hostRules: rules, inAppSchemes: ["https"]), capabilities: d.capabilities, authentication: d.authentication,
                               sessionCookieDomains: d.sessionCookieDomains, zoomDefault: d.zoomDefault, zoomDefaultsKey: zoom, regionNote: d.regionNote, releaseNote: d.releaseNote, regionProfile: region)
        }
        let clash = with(h, rules: [HostRule(suffix: "jiohotstar.com", role: .site)], store: "22222222-2222-4222-8222-222222222222", zoom: "z", region: nil)
        #expect(ProviderRegistry.validate([j, clash]).contains(.sharedSiteHost("jiohotstar", "hulu", "jiohotstar.com")))
        let inactiveClash = with(h, rules: [HostRule(suffix: "jiohotstar.com", role: .site, active: false), HostRule(suffix: "hulu.com", role: .site)], store: "22222222-2222-4222-8222-222222222222", zoom: "z", region: nil)
        #expect(!ProviderRegistry.validate([j, inactiveClash]).contains { if case .sharedSiteHost = $0 { true } else { false } })
        let bad = RegionProfile(preferredCountry: "India", preferredLocaleIdentifier: "en_IN", noteKey: "x")
        #expect(ProviderRegistry.validate([with(j, rules: j.urlPolicy.hostRules, store: "33333333-3333-4333-8333-333333333333", zoom: "y", region: bad)]).contains(.invalidRegionProfile("jiohotstar")))
        #expect(!RegionProfile(preferredCountry: "IN", preferredLocaleIdentifier: "en_US", noteKey: "x").isWellFormed)
    }

    // MARK: honest reporting: four separate answers

    @Test func theFourLinesNeverReportTheServiceAsVerifiedOrEligible() throws {
        let status = try #require(RegionStatus.of(jio))
        #expect(status.network == .unknown && status.service == .decidedByService && status.playback == .decidedByService)
        let lines = status.lines
        #expect(lines.count == 4)
        #expect(lines[0] == "Preferred region: India (en_IN)")
        #expect(lines[1] == "Network region: not checked by StreamSetu")
        #expect(lines[2] == "Service region: decided by the service")
        #expect(lines[3] == "Playback: decided by the service")
        for l in lines + [jio.releaseNote ?? ""] {
            let low = l.lowercased()
            for word in ["verified", "eligible", "available in your", "supported in your", "unlocked"] { #expect(!low.contains(word), Comment(rawValue: l)) }
        }
        #expect(RegionStatus.of(ProviderCatalog.netflix) == nil)
        #expect(PlaybackEntitlement.unknown != .decidedByService && NetworkRegionObservation.observed("IN") != .unknown)
    }

    @Test func theRecordedStateIsUnverifiedUnresolvedAndNothingIsChecked() {
        #expect(jio.availability == .registered && jio.distributionAuthorization == .unresolved, "on hold by the owner")
        #expect(jio.capabilities.protectedPlayback.status == .manualVerificationRequired && jio.capabilities.compatibility == .unchecked)
        #expect(CompatibilityResult.Check.allCases.allSatisfy { jio.capabilities.compatibility.outcome($0) == .notChecked })
        #expect(jio.regionNote == .countryVariants && jio.homeURL.absoluteString == "https://www.hotstar.com/in")
        #expect(jio.releaseNote == RegionProfile.india.noteKey && jio.releaseNote == "The service decides availability from your network location. From outside India it may send StreamSetu to its own regional page, which is shown as a notice. StreamSetu does not change or hide your location.")
        #expect(jio.termsNote?.contains("hides nothing") == true)
        let m = StreamingServicesSettingsModel(defaults: defaults())
        #expect(m.rows.first { $0.id == .jiohotstar } == nil)
    }

    @Test func aNotAvailableInYourCountryPageIsTheServicesPageNotAnAppFailure() async throws {
        let rig = try await ServiceWebModelTests.Rig(.jiohotstar); defer { rig.finish() }
        rig.show()
        #expect(await ServiceTestSupport.until { rig.model.phase == .ready })          // the fixture's ordinary 200 page stands in for the service's own notice page
        #expect(rig.model.failureScreen == nil && rig.model.notice == nil && rig.model.blockedLinkHost == nil)
    }

    @Test func aRedirectToHotstarFromOutsideIndiaIsBlockedWithTheHostShownInTheNoticeAndDiagnostics() async throws {
        let rig = try await ServiceWebModelTests.Rig(.jiohotstar); defer { rig.finish() }
        let url = URL(string: "https://www.hotstar.com/tv")!
        rig.model.addressOffSite(url)
        #expect(rig.model.blockedLinkHost == "www.hotstar.com" && rig.model.pendingExternal == nil)
        let diagnostics = ServiceDiagnostics()
        diagnostics.recordBlocked(.jiohotstar, url: url)
        #expect(diagnostics.entries(for: .jiohotstar).map(\.host) == ["www.hotstar.com"])
    }

    // MARK: nothing leaves the app, nothing is spoofed

    @Test func noCodePathSendsOrDerivesARegionOrAddressSignal() throws {
        let streaming = try ServiceSources.text(["Services/Streaming/Runtime", "Services/Streaming/Session", "Services/Streaming/Policy", "Features/Netflix"])
        for banned in ["Accept-Language", "CoreLocation", "CLLocation", "Locale.current", "preferredLanguages", "ipify", "geoip", "X-Forwarded-For", "navigator.language"] {
            #expect(!streaming.contains(banned), Comment(rawValue: banned))
        }
        let runtimeWithoutCopy = try ServiceSources.text(["Services/Streaming/Runtime"], excluding: ["ServiceWebModel.swift"])
        #expect(!runtimeWithoutCopy.contains("regionProfile") && !runtimeWithoutCopy.contains("RegionStatus") && !runtimeWithoutCopy.contains("RegionProfile"), "the web layer never reads the preference")
        let domain = try ServiceSources.text(["Services/Streaming/Domain"])
        for banned in ["URLSession", "CoreLocation", "CLLocation", "NWPathMonitor"] { #expect(!domain.contains(banned), Comment(rawValue: banned)) }
        #expect(!domain.contains("= .observed("), "nothing in the app ever sets an observed network region")
    }
}
