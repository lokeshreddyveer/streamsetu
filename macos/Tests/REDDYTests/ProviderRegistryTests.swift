import Testing
import Foundation
@testable import REDDY

@Suite("Provider registry") struct ProviderRegistryTests {
    static let frozen: [(String, String)] = [
        ("netflix", "afdfb6b8-2671-42a0-bd87-6973dcd90758"), ("primevideo", "e19483cc-c942-4b44-8aec-edc4a6a4c7dc"),
        ("disneyplus", "eb14ffb5-2e9f-4629-8a99-6f700c8b3398"), ("hulu", "32bc5ffc-0cdc-46d7-a7d4-bff3a25d0cca"),
        ("hbomax", "eac63ddd-0365-428e-b75a-5bf55799a0f6"), ("peacock", "320567c5-6338-46bd-8680-fedd1bab701f"),
        ("paramountplus", "862a68b0-ee28-4ebc-af6e-a8df1a592a83"), ("appletv", "61c40311-eeed-49f9-8a69-92ab863689c2"),
        ("youtube", "20bed3f7-5bc0-46f4-ade6-bce2f57350db"), ("crunchyroll", "84d233c6-bd18-4367-b759-6e8b206e5b84"),
    ]
    let reg = ProviderRegistry.standard

    @Test func tenDefinitionsInCatalogOrderWithNetflixFirst() {
        #expect(reg.definitions.map(\.id.rawValue) == Self.frozen.map(\.0))
        #expect(reg.definitions.map(\.displayName) == ["Netflix", "Prime Video", "Disney+", "Hulu", "HBO Max", "Peacock", "Paramount+", "Apple TV", "YouTube", "Crunchyroll"])
    }

    @Test func theCatalogValidatesCleanly() { #expect(ProviderRegistry.validate(reg.definitions).isEmpty) }

    @Test func storeIdentifiersAreFrozenLiteralsAndUnique() {
        for (id, uuid) in Self.frozen { #expect(reg.definition(for: ProviderID(unchecked: id))?.storeIdentity.uuid == UUID(uuidString: uuid), Comment(rawValue: id)) }
        #expect(Set(reg.definitions.map(\.storeIdentity.uuid)).count == 10)
    }

    @Test func addressesAreHTTPSAndOnTheirOwnHost() {
        let homes = ["https://www.netflix.com/", "https://www.primevideo.com/", "https://www.disneyplus.com/", "https://www.hulu.com/", "https://www.hbomax.com/",
                     "https://www.peacocktv.com/", "https://www.paramountplus.com/", "https://tv.apple.com/", "https://www.youtube.com/", "https://www.crunchyroll.com/"]
        #expect(reg.definitions.map(\.homeURL.absoluteString) == homes)
        for d in reg.definitions { #expect(d.urlPolicy.isAllowedHost(d.homeURL.host)); #expect(d.urlPolicy.inAppSchemes == ["https"]) }
    }

    @Test func initialStatesPoliciesAndRecordedDecisions() {
        for d in reg.definitions {
            let isNetflix = d.id == .netflix
            #expect(d.availability == (isNetflix ? .available : .unverified))
            #expect(d.externalLinks == (isNetflix ? .confirmThenOpen : .blockWithNotice))
            #expect(d.distributionAuthorization == .unresolved)
            #expect(d.platforms == [.macOS]); #expect(d.presentation == .embedded)
            #expect(d.zoomDefaultsKey == (isNetflix ? "netflix.pageZoom" : "streaming.zoom.\(d.id.rawValue)"))
        }
        #expect(reg.definition(for: .netflix)?.zoomDefault == 0.85)
        #expect(reg.definition(for: .youtube)?.authentication == .signedOutOnly)
        #expect(reg.definition(for: .youtube)?.capabilities.authentication.status == .unsupported)
        #expect(reg.definition(for: .netflix)?.capabilities.protectedPlayback.status == .ownerVerified)
        #expect(reg.definitions.dropFirst().allSatisfy { $0.capabilities.protectedPlayback.status == .manualVerificationRequired })
    }

    @Test func unverifiedSignInHostsAreDeclaredButInactive() {
        func rule(_ id: ProviderID, _ suffix: String) -> HostRule? { reg.definition(for: id)?.urlPolicy.hostRules.first { $0.suffix == suffix } }
        for (id, s) in [(ProviderID.primevideo, "amazon.com"), (.appletv, "appleid.apple.com"), (.appletv, "idmsa.apple.com")] {
            #expect(rule(id, s)?.role == .auth && rule(id, s)?.active == false, Comment(rawValue: s))
        }
        #expect(rule(.youtube, "youtu.be")?.role == .redirectOnly && rule(.hbomax, "max.com")?.role == .redirectOnly)
        #expect(reg.definition(for: .youtube)?.urlPolicy.hostRules.contains { $0.suffix.contains("google") } == false)
    }

    @Test func presentationTable() {
        #expect(ServiceAvailability.available.presentation == .embedded && ServiceAvailability.unverified.presentation == .embedded)
        #expect(ServiceAvailability.disabled.presentation == .integrationUnavailable)
        #expect(ServiceAvailability.registered.presentation == .hidden)
        #expect(ServiceAvailability.allCasesListed == [.available, .unverified, .disabled])
    }

    private func rebuilt(_ id: ProviderID, _ a: ServiceAvailability) -> ProviderRegistry {
        ProviderRegistry(definitions: reg.definitions.map { d in
            guard d.id == id else { return d }
            return ProviderDefinition(id: d.id, displayName: d.displayName, homeURL: d.homeURL, availability: a, distributionAuthorization: d.distributionAuthorization, termsNote: d.termsNote,
                                      externalLinks: d.externalLinks, platforms: d.platforms, storeIdentity: d.storeIdentity, urlPolicy: d.urlPolicy, capabilities: d.capabilities,
                                      authentication: d.authentication, sessionCookieDomains: d.sessionCookieDomains, zoomDefault: d.zoomDefault, zoomDefaultsKey: d.zoomDefaultsKey,
                                      regionNote: d.regionNote, releaseNote: d.releaseNote)
        })
    }

    @Test func flippingOneEntryChangesOnlyThatService() {
        let ids = reg.listed(on: .macOS).map(\.id)
        let registered = rebuilt(.hulu, .registered).listed(on: .macOS).map(\.id)
        #expect(registered == ids.filter { $0 != .hulu })
        let disabled = rebuilt(.hulu, .disabled).listed(on: .macOS).map(\.id)
        #expect(disabled == ids)          // disabled stays listed (with a badge)
        #expect(rebuilt(.hulu, .disabled).definition(for: .hulu)?.presentation == .integrationUnavailable)
        #expect(rebuilt(.hulu, .disabled).definition(for: .netflix) == reg.definition(for: .netflix))
    }

    @Test func validationFindsEveryKindOfIssue() {
        let n = ProviderCatalog.netflix, p = ProviderCatalog.primevideo
        #expect(ProviderRegistry.validate([n, n]).contains(.duplicateID("netflix")))
        #expect(ProviderRegistry.validate([n, n]).contains(.duplicateStoreIdentity("netflix")))
        #expect(ProviderRegistry.validate([n, n]).contains(.duplicateZoomKey("netflix")))
        let bad = ProviderDefinition(id: "x", displayName: "X", homeURL: URL(string: "http://elsewhere.test/")!, availability: .unverified, distributionAuthorization: .unresolved, termsNote: nil,
                                     externalLinks: .blockWithNotice, platforms: [.macOS], storeIdentity: StoreIdentity("11111111-1111-4111-8111-111111111111"),
                                     urlPolicy: ProviderURLPolicy(hostRules: [HostRule(suffix: "a.test", role: .site, active: false)], inAppSchemes: ["https"]), capabilities: p.capabilities,
                                     authentication: .signInInApp, sessionCookieDomains: [], zoomDefault: 1, zoomDefaultsKey: "k", regionNote: nil, releaseNote: nil)
        let issues = ProviderRegistry.validate([bad])
        #expect(issues.contains(.homeURLNotHTTPS("x")) && issues.contains(.noHosts("x")) && issues.contains(.homeHostNotAllowed("x")))
    }

    @Test func unknownIdsAreRejectedAndKnownOnesRoundTrip() {
        #expect(ProviderID(rawValue: "nope") == nil); #expect(ProviderID(rawValue: "Netflix") == nil); #expect(ProviderID(rawValue: "") == nil)
        #expect(ProviderID(rawValue: "hulu") == .hulu)
        #expect(reg.definition(for: "nope") == nil)
        #expect(ProviderID.netflix.title == "Netflix"); #expect(ProviderID(unchecked: "zzz").title == "zzz")
        let data = try? JSONEncoder().encode([ProviderID.hulu, .netflix])
        #expect((try? JSONDecoder().decode([ProviderID].self, from: data ?? Data())) == [.hulu, .netflix])
    }

    @Test func capabilitiesDeriveFromTheRegistryAndIOSHasNone() {
        #expect(ServiceCapabilities.macOS.externalServices == reg.listed(on: .macOS).map(\.id))
        #expect(ServiceCapabilities.none.externalServices.isEmpty)
        for id in ProviderID.allCases { #expect(!ServiceCapabilities.none.allows(id)); #expect(ServiceCapabilities.macOS.allows(id)) }
        #expect(ServiceCapabilities.macOS.profile(for: "ghost").websiteLoading == .unavailable)
    }

    @Test func legacyProfileNeverClaimsMoreThanTesting() {
        let n = ServiceCapabilities.macOS.profile(for: .netflix)
        #expect(n == ServiceCapabilityProfile(websiteLoading: .enabledForTesting, signIn: .manualVerificationRequired, protectedPlayback: .manualVerificationRequired))
        #expect(ServiceCapabilities.macOS.profile(for: .youtube).signIn == .unsupported)
    }

    @Test func termsNoteAndDistributionAuthorizationGateNothing() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/REDDY")
        let fm = FileManager.default
        var offenders: [String] = []
        for case let u as URL in fm.enumerator(at: root, includingPropertiesForKeys: nil)! where u.pathExtension == "swift" {
            let rel = u.path.replacingOccurrences(of: root.path + "/", with: "")
            if rel.hasPrefix("Services/Streaming/Domain/") || rel.hasPrefix("Features/Settings/") || rel.hasPrefix("Features/Streaming/") { continue }
            let t = try String(contentsOf: u, encoding: .utf8)
            if t.contains(".termsNote") || t.contains(".distributionAuthorization") { offenders.append(rel) }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }
}

extension ServiceAvailability { static var allCasesListed: [ServiceAvailability] { [.available, .unverified, .registered, .disabled].filter(\.isListed) } }
