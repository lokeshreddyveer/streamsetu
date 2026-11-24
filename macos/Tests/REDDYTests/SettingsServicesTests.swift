import Testing
import Foundation
@testable import REDDY

/// Settings > Privacy > Streaming Services: the list, the badges, pinning and order through the shared preferences, and the confirmed
/// one-service clear. Every test uses its own defaults suite and a recording closure: no real store, session or browser is touched.
@Suite("Settings: streaming services") @MainActor struct SettingsServicesTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "reddy-svc-settings-\(UUID().uuidString)")! }

    private func copy(_ d: ProviderDefinition, availability: ServiceAvailability) -> ProviderDefinition {
        ProviderDefinition(id: d.id, displayName: d.displayName, homeURL: d.homeURL, availability: availability, distributionAuthorization: d.distributionAuthorization,
                           termsNote: d.termsNote, externalLinks: d.externalLinks, platforms: d.platforms, storeIdentity: d.storeIdentity, urlPolicy: d.urlPolicy,
                           capabilities: d.capabilities, authentication: d.authentication, sessionCookieDomains: d.sessionCookieDomains, zoomDefault: d.zoomDefault,
                           zoomDefaultsKey: d.zoomDefaultsKey, regionNote: d.regionNote, releaseNote: d.releaseNote, userAgentProfile: d.userAgentProfile, pageEnhancements: d.pageEnhancements, regionProfile: d.regionProfile)
    }

    @Test func listsEveryListedServiceWithItsBadge() {
        let m = StreamingServicesSettingsModel(defaults: defaults())
        #expect(m.rows.count == 11)
        #expect(Set(m.rows.map(\.id)) == Set(ProviderCatalog.all.map(\.id).filter { $0 != .jiohotstar }), "JioHotstar is on hold and has no row")
        #expect(m.rows.first { $0.id == .netflix }?.badge == "Available")
        let verified: Set<ProviderID> = [.netflix, .primevideo, .disneyplus, .hulu, .hbomax, .paramountplus, .appletv, .peacock, .youtube, .crunchyroll]        // owner-confirmed on 2026-11-22
        #expect(m.rows.filter { verified.contains($0.id) }.allSatisfy { $0.badge == "Available" })
        #expect(m.rows.filter { !verified.contains($0.id) }.allSatisfy { $0.badge == "Unverified" })
        #expect(m.rows.filter { $0.badge == "Unverified" }.map(\.id) == [.spotify], "Spotify is the one listed service the owner has not confirmed")
        #expect(m.rows.first?.id == .netflix && m.rows.first?.pinned == true)
    }

    @Test func disabledIsListedWithABadgeAndRegisteredIsNot() {
        var defs = ProviderCatalog.all
        defs[2] = copy(defs[2], availability: .disabled)
        defs[3] = copy(defs[3], availability: .registered)
        let m = StreamingServicesSettingsModel(registry: ProviderRegistry(definitions: defs), defaults: defaults())
        #expect(m.rows.count == 10, "twelve definitions minus the held JioHotstar minus the registered one")
        #expect(m.rows.first { $0.id == defs[2].id }?.badge == "Disabled")
        #expect(m.rows.contains { $0.id == defs[3].id } == false)
        #expect(m.rows.first { $0.id == defs[2].id }?.canOpen == false)
    }

    @Test func distributionIsOneNoteForTheSectionNotALinePerService() {
        let m = StreamingServicesSettingsModel(defaults: defaults())
        #expect(m.distributionNote == "Distribution permission: unresolved for every service")
        #expect(StreamingServicesSettingsModel.distributionNote(for: [.confirmed, .confirmed]) == nil)
        #expect(StreamingServicesSettingsModel.distributionNote(for: [.confirmed, .unresolved, .unresolved]) == "Distribution permission: unresolved for 2 services")
        #expect(m.rows.allSatisfy { !($0.statusLine ?? "").contains("Distribution") })
    }

    @Test func noServiceShowsASignInLimitationNowThatGoogleSignInIsAllowed() {
        let m = StreamingServicesSettingsModel(defaults: defaults())
        #expect(m.rows.allSatisfy { $0.limitation == nil })
    }

    @Test func pinUnpinAndReorderUseTheSharedPreferencesAndPersist() {
        let d = defaults()
        let m = StreamingServicesSettingsModel(defaults: d)
        m.togglePin(.hulu); m.togglePin(.peacock)
        #expect(m.preferences.pinned == [.netflix, .hulu, .peacock])
        m.moveLeft(.peacock)
        #expect(m.preferences.pinned == [.netflix, .peacock, .hulu])
        #expect(m.rows.prefix(3).map(\.id) == [.netflix, .peacock, .hulu])
        #expect(ServicePreferences.load(from: d).pinned == [.netflix, .peacock, .hulu])        // what the bar reads
        m.togglePin(.netflix)
        #expect(m.preferences.pinned == [.peacock, .hulu])
        m.resetOrder()
        #expect(m.preferences.pinned == [.netflix])
        #expect(ServicePreferences.load(from: d).pinned == [.netflix])
    }

    @Test func movingAtTheEdgesDoesNothing() {
        let m = StreamingServicesSettingsModel(defaults: defaults())
        m.togglePin(.hulu)
        m.moveLeft(.netflix); m.moveRight(.hulu); m.moveLeft(.primevideo)              // first, last, not pinned
        #expect(m.preferences.pinned == [.netflix, .hulu])
        #expect(m.rows[0].canMoveLeft == false && m.rows[0].canMoveRight == true && m.rows[1].canMoveRight == false)
    }

    @Test func pinningNeverClearsOrNavigates() async {
        var cleared: [ProviderID] = [], opened: [ProviderID] = []
        let m = StreamingServicesSettingsModel(defaults: defaults(), actions: .init(open: { opened.append($0) }, clearWebsiteData: { cleared.append($0); return .cleared }))
        m.togglePin(.hulu); m.togglePin(.hulu); m.resetOrder()
        #expect(cleared.isEmpty && opened.isEmpty)
    }

    @Test func clearNamesTheServiceAsksFirstAndClearsOnlyThatOne() async {
        var cleared: [ProviderID] = []
        let m = StreamingServicesSettingsModel(defaults: defaults(), actions: .init(clearWebsiteData: { cleared.append($0); return .cleared }))
        m.requestClear(.disneyplus)
        #expect(m.pendingClear == .disneyplus && cleared.isEmpty)                         // nothing yet: the person has to confirm
        #expect(m.confirmationTitle(.disneyplus).contains("Disney+"))
        #expect(m.confirmationMessage(.disneyplus).contains("Disney+") && m.confirmationMessage(.disneyplus).contains("signs you out"))
        await m.confirmClear()
        #expect(cleared == [.disneyplus] && m.pendingClear == nil)
        #expect(m.notice?.contains("Disney+") == true)
    }

    @Test func cancellingClearsNothing() async {
        var cleared: [ProviderID] = []
        let m = StreamingServicesSettingsModel(defaults: defaults(), actions: .init(clearWebsiteData: { cleared.append($0); return .cleared }))
        m.requestClear(.hulu); m.cancelClear()
        await m.confirmClear()
        #expect(cleared.isEmpty && m.pendingClear == nil)
    }

    @Test func clearWithoutTheSessionApiSaysSoAndFailureIsReported() async {
        let unwired = StreamingServicesSettingsModel(defaults: defaults())
        #expect(unwired.canClear == false)
        unwired.requestClear(.hulu); await unwired.confirmClear()
        #expect(unwired.notice == "Clearing data is not available yet.")
        let failing = StreamingServicesSettingsModel(defaults: defaults(), actions: .init(clearWebsiteData: { _ in .failed }))
        failing.requestClear(.hulu); await failing.confirmClear()
        #expect(failing.notice?.contains("Hulu") == true && failing.notice?.hasPrefix("Could not") == true)
    }

    @Test func openGoesThroughTheSuppliedRouteOnlyForEmbeddedServices() {
        var opened: [ProviderID] = []
        var defs = ProviderCatalog.all
        defs[2] = copy(defs[2], availability: .disabled)
        let m = StreamingServicesSettingsModel(registry: ProviderRegistry(definitions: defs), defaults: defaults(), actions: .init(open: { opened.append($0) }))
        m.open(.hulu); m.open(defs[2].id)
        #expect(opened == [.hulu])
    }

    /// Owner rule: no external-browser action for the ten, so the section holds no way to launch one. Netflix keeps its own existing action elsewhere.
    @Test func theSectionHasNoBrowserLaunchCode() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/REDDY/Features/Settings/Views/StreamingServicesSettingsSection.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        for token in ["NSWorkspace", "openURL", "LSOpen", "canOpenURL", "WKWebsiteDataStore", "remove(forIdentifier"] { #expect(!text.contains(token), "found \(token)") }
    }
}
