import Testing
import WebKit
import AppKit
import SwiftUI
import CryptoKit
import os
@testable import REDDY

/// A stand-in for the sponsor service: records what it was asked and answers from a fixed list. Nothing here touches the network.
final class FakeSegments: SponsorSegmentsFetching, @unchecked Sendable {
    private let log = OSAllocatedUnfairLock<[String]>(initialState: [])
    var answer: [SponsorSpan]?
    var asked: [String] { log.withLock { $0 } }
    init(_ answer: [SponsorSpan]? = []) { self.answer = answer }
    func segments(forVideoID id: String) async -> [SponsorSpan]? { log.withLock { $0.append(id) }; return answer }
}

@MainActor enum EnhancementRig {
    static func suite() -> UserDefaults { UserDefaults(suiteName: "enhancement-test-" + UUID().uuidString)! }
    /// A runtime over a throwaway UserDefaults suite (never the real one), not restricted unless asked.
    static func runtime(_ client: SponsorSegmentsFetching = FakeSegments(), restricted: Bool = false, defaults: UserDefaults? = nil) -> EnhancementRuntime {
        let r = EnhancementRuntime(store: EnhancementStore(defaults: defaults ?? suite()), client: client)
        r.isRestricted = { restricted }
        return r
    }
    static var youtube: ProviderDefinition { ProviderCatalog.all.first { $0.id == .youtube }! }
    static func grantAll(_ r: EnhancementRuntime) { PageEnhancement.allCases.forEach { r.store.grant($0) } }
    static func scripts(_ d: ProviderDefinition, _ r: EnhancementRuntime) -> [WKUserScript] {
        let c = WKUserContentController()
        EnhancementInstaller(definition: d, runtime: r).apply(to: c)
        return c.userScripts
    }
    static func load(_ web: WKWebView, _ html: String, base: String) async {
        web.loadHTMLString(html, baseURL: URL(string: base))
        for _ in 0..<200 { try? await Task.sleep(for: .milliseconds(50)); if !web.isLoading { break } }
    }
    static func config(_ d: ProviderDefinition, _ r: EnhancementRuntime) -> (WKWebViewConfiguration, EnhancementInstaller) {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        let inst = EnhancementInstaller(definition: d, runtime: r)
        inst.apply(to: cfg.userContentController)
        return (cfg, inst)
    }
}

@Suite("Page enhancements: defaults, consent, installation") @MainActor struct EnhancementPolicyTests {
    @Test func everythingIsOffInAFreshStore() {
        let r = EnhancementRig.runtime()
        for e in PageEnhancement.allCases {
            #expect(!r.store.isEnabled(e) && !r.store.hasConsent(e) && !r.store.isActive(e) && r.store.consent(e) == nil, "\(e)")
        }
        #expect(r.active(for: EnhancementRig.youtube).isEmpty)
    }

    @Test func onlyTheYouTubeAndSpotifyDefinitionsDeclareEnhancements() {
        let declaring = ProviderCatalog.all.filter { !$0.pageEnhancements.isEmpty }
        #expect(declaring.map(\.id) == [.youtube, .spotify])
        #expect(declaring.first?.pageEnhancements == [.adSkip, .sponsorSkip])
        #expect(declaring.last?.pageEnhancements == [.spotifyHideAds, .spotifyMuteAds])
        #expect(ProviderCatalog.all.count == 12 && ProviderCatalog.all.filter { $0.pageEnhancements.isEmpty }.count == 10)
    }

    @Test func nothingIsInstalledByDefaultOrWithoutConsent() {
        let r = EnhancementRig.runtime()
        #expect(EnhancementRig.scripts(EnhancementRig.youtube, r).isEmpty, "default: no script")
        // switched on in the store but never agreed to (for example a hand-edited preference): still nothing
        for e in PageEnhancement.allCases { r.store.isolatedSetEnabledForTest(e) }
        #expect(PageEnhancement.allCases.allSatisfy { r.store.isEnabled($0) && !r.store.isActive($0) })
        #expect(EnhancementRig.scripts(EnhancementRig.youtube, r).isEmpty, "enabled without consent: no script")
    }

    @Test func aScriptIsInstalledOnlyWhenDeclaredEnabledAndAgreedAndItIsTheRightKind() {
        let r = EnhancementRig.runtime()
        r.store.grant(.adSkip)
        let one = EnhancementRig.scripts(EnhancementRig.youtube, r)
        #expect(one.count == 1 && one[0].injectionTime == .atDocumentStart && one[0].isForMainFrameOnly && one[0].source.contains("ytInitialPlayerResponse"))
        r.store.grant(.sponsorSkip)
        let both = EnhancementRig.scripts(EnhancementRig.youtube, r)
        #expect(both.count == 2 && both.allSatisfy { $0.injectionTime == .atDocumentStart && $0.isForMainFrameOnly })
        #expect(both.filter { $0.source.contains("__ssSponsor") }.count == 1)
    }

    @Test func noOtherServiceEverGetsAScriptEvenWhenEverythingIsOnAndAgreedTo() throws {
        let r = EnhancementRig.runtime()
        EnhancementRig.grantAll(r)
        for d in ProviderCatalog.all where d.id != .youtube && d.id != .spotify {
            #expect(EnhancementRig.scripts(d, r).isEmpty, "\(d.id) must never get a script")
            #expect(r.active(for: d).isEmpty)
            // and through the real factory (a service on hold has no web view at all)
            guard d.presentation == .embedded else { continue }
            let v = ServiceWebViewFactory().makeWebView(definition: d, dataStore: .nonPersistent(), zoom: 1, enhancements: EnhancementInstaller(definition: d, runtime: r))
            #expect(v.configuration.userContentController.userScripts.isEmpty, "\(d.id) through the factory")
        }
        let y = EnhancementRig.youtube
        let v = ServiceWebViewFactory().makeWebView(definition: y, dataStore: .nonPersistent(), zoom: 1, enhancements: EnhancementInstaller(definition: y, runtime: r))
        #expect(v.configuration.userContentController.userScripts.count == 2, "the one service that declares them, through the factory")
        let plain = ServiceWebViewFactory().makeWebView(definition: y, dataStore: .nonPersistent(), zoom: 1)
        #expect(plain.configuration.userContentController.userScripts.isEmpty, "the factory adds nothing unless it is given the installer")
    }

    @Test func onlyAnHttpsAddressOfTheServiceCountsAndNeverKidsOrLocked() {
        let y = EnhancementRig.youtube
        let r = EnhancementRig.runtime(); EnhancementRig.grantAll(r)
        #expect(r.active(for: y).count == 2)
        let http = y.replacing(urlPolicy: y.urlPolicy, homeURL: URL(string: "http://www.youtube.com/")!)
        #expect(r.active(for: http).isEmpty, "http")
        let elsewhere = y.replacing(urlPolicy: y.urlPolicy, homeURL: URL(string: "https://video.example/")!)
        #expect(r.active(for: elsewhere).isEmpty, "a host the service's policy does not allow")
        let local = EnhancementRig.runtime(restricted: true); EnhancementRig.grantAll(local)
        #expect(local.active(for: y).isEmpty && EnhancementRig.scripts(y, local).isEmpty, "kids or locked")
        // a runtime nobody configured is restricted until the app says otherwise
        #expect(EnhancementRuntime(store: EnhancementStore(defaults: EnhancementRig.suite())).isRestricted())
    }

    @Test func consentDeclineLeavesItOffConfirmRecordsVersionAndDateAndOffRemovesTheScripts() throws {
        let r = EnhancementRig.runtime()
        let m = EnhancementToggleModel(runtime: r)
        m.set(.adSkip, on: true)
        #expect(m.pending == .adSkip && !m.isOn(.adSkip), "turning on asks first and changes nothing yet")
        m.cancel()
        #expect(m.pending == nil && !r.store.isEnabled(.adSkip) && r.store.consent(.adSkip) == nil, "Cancel leaves it off, with no record")
        let before = Date()
        m.set(.adSkip, on: true); m.confirm()
        let c = try #require(r.store.consent(.adSkip))
        #expect(m.isOn(.adSkip) && c.version == PageEnhancement.adSkip.consentVersion && abs(c.date.timeIntervalSince(before)) < 5)
        #expect(!r.store.isEnabled(.sponsorSkip), "the other one is untouched")
        // installed, then turned off: gone at the next load, and the person is told a reload is needed
        let controller = WKUserContentController()
        let installer = EnhancementInstaller(definition: EnhancementRig.youtube, runtime: r)
        installer.apply(to: controller)
        #expect(controller.userScripts.count == 1 && installer.installed == installer.wanted)
        m.set(.adSkip, on: false)
        #expect(!m.isOn(.adSkip) && m.reloadHint)
        #expect(installer.installed != installer.wanted, "the page still has it until it reloads (the reload banner)")
        installer.apply(to: controller)
        #expect(controller.userScripts.isEmpty && installer.installed.isEmpty)
        // turning it on again asks again, even though an agreement is on record
        m.set(.adSkip, on: true)
        #expect(m.pending == .adSkip)
    }

    @Test func settingsAndTheFirstOpenCardShareOneStoreAndStayInSync() {
        let r = EnhancementRig.runtime()
        let settings = EnhancementToggleModel(runtime: r), card = EnhancementToggleModel(runtime: r)
        card.set(.sponsorSkip, on: true); card.confirm()
        #expect(settings.isOn(.sponsorSkip) && card.isOn(.sponsorSkip))
        settings.set(.sponsorSkip, on: false)
        #expect(!card.isOn(.sponsorSkip) && !card.store.isEnabled(.sponsorSkip))
        // the Settings model reads the same one the app uses
        #expect(StreamingServicesSettingsModel().enhancements.runtime === EnhancementRuntime.shared)
    }

    @Test func kidsOrLockedCanNotTurnAnythingOn() {
        let r = EnhancementRig.runtime(restricted: true)
        let m = EnhancementToggleModel(runtime: r)
        m.set(.adSkip, on: true)
        #expect(m.pending == nil)
        r.isRestricted = { false }; m.set(.adSkip, on: true)
        r.isRestricted = { true }; m.confirm()
        #expect(!r.store.isEnabled(.adSkip), "a profile switch while the explanation was showing does not turn it on")
    }

    @Test func theFirstOpenPromptIsShownOnceOnlyForTheServiceThatDeclaresOptionsAndNeverWhenRestrictedOrConfigured() {
        let r = EnhancementRig.runtime()
        let y = EnhancementRig.youtube
        #expect(r.shouldPrompt(for: y))
        for d in ProviderCatalog.all where d.id != .youtube && d.id != .spotify { #expect(!r.shouldPrompt(for: d), "\(d.id)") }
        r.store.recordPromptAnswered(for: .youtube)
        #expect(!r.shouldPrompt(for: y), "not again after any answer")
        r.store.resetPrompt(for: .youtube)
        #expect(r.shouldPrompt(for: y), "Settings can bring it back")
        #expect(!EnhancementRig.runtime(restricted: true).shouldPrompt(for: y))
        let configured = EnhancementRig.runtime(); configured.store.grant(.adSkip)
        #expect(!configured.shouldPrompt(for: y), "already configured")
        configured.store.disable(.adSkip)
        #expect(!configured.shouldPrompt(for: y), "an earlier agreement counts as configured")
    }

    @Test func settingsRowsOfferTheTogglesForTheDeclaringServiceOnly() {
        let m = StreamingServicesSettingsModel(defaults: EnhancementRig.suite())
        for row in m.rows { #expect(row.enhancements.isEmpty == (row.id != .youtube && row.id != .spotify), "\(row.id)") }
        #expect(m.rows.first { $0.id == .spotify }?.enhancements == [.spotifyHideAds, .spotifyMuteAds])
        #expect(m.rows.first { $0.id == .youtube }?.enhancements == [.adSkip, .sponsorSkip])
        nonisolated(unsafe) var reloaded: [ProviderID] = []
        m.actions.reloadService = { reloaded.append($0) }
        m.reloadService(.youtube)
        #expect(reloaded == [.youtube])
    }

    @Test func scriptsMayOnlyBeCreatedInsideTheEnhancementsFolder() throws {
        let root = ServiceSources.root
        let fm = FileManager.default
        var offenders: [String] = []
        let tokens = ["WKUserScript", "addScriptMessageHandler", "WKScriptMessageHandler", "evaluateJavaScript", "callAsyncJavaScript", ".add(h, contentWorld"]
        let e = fm.enumerator(at: root, includingPropertiesForKeys: nil)!
        var enhancementHasThem = false
        for case let url as URL in e where url.pathExtension == "swift" {
            let rel = String(url.path.dropFirst(root.path.count + 1))
            guard rel.hasPrefix("Services/Streaming/") || rel.hasPrefix("Features/Streaming/") || rel.hasPrefix("Features/Netflix/") || rel.hasPrefix("Features/Settings/") else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let has = tokens.contains { text.contains($0) }
            if rel.hasPrefix("Services/Streaming/Enhancements/") { enhancementHasThem = enhancementHasThem || has } else if has { offenders.append(rel) }
        }
        #expect(enhancementHasThem && offenders.isEmpty, "page code is created only in Enhancements: \(offenders)")
        // the generic runtime names no service and no enhancement kind
        let runtime = try ServiceSources.text(["Services/Streaming/Runtime"])
        #expect(!runtime.lowercased().contains("\"youtube\"") && !runtime.contains(".adSkip") && !runtime.contains(".sponsorSkip"), "no provider conditional in the generic web model")
    }

    @Test func newWordingHasHindiAndTelugu() throws {
        for code in ["hi", "te"] {
            let url = ServiceSources.root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Localization/\(code).lproj/Localizable.strings")
            let table = try #require(NSDictionary(contentsOf: url) as? [String: String])
            var keys: [String] = ["Skip ads and sponsor segments on YouTube? Both are off. You can change this any time in Settings.", "Page options", "Not now", "Set up", "Turn On",
                                  "Reload %@ to apply your page options.", "Changes apply the next time %@ loads.", "Show the First-Open Prompt Again", "Skipped sponsor", "Undo", "Reload",
                                  "Turn on the Spotify ad options?", "Both options are off. You can change this any time in Settings.", PageEnhancement.spotifyRisks, "Sign in for %@",
                                  "This link was blocked: %@. It is not an allowed sign-in or service address."]
            for e in PageEnhancement.allCases { keys += [e.title, e.summary, e.consentTitle, e.consentMessage] }
            keys += ServiceCredits.all.filter { $0.id == "sponsorblock" }.map(\.text)
            keys += ProviderCatalog.all.compactMap(\.releaseNote)
            for k in keys { #expect((table[k] ?? "").isEmpty == false, Comment(rawValue: "\(code): \(k.prefix(60))")) }
        }
    }

    @Test func theCreditNamesTheLicenceAndLinksToTheService() {
        let c = ServiceCredits.all.first { $0.id == "sponsorblock" }
        #expect(c?.text.contains("CC BY-NC-SA 4.0") == true && c?.url.absoluteString == "https://sponsor.ajay.app")
        #expect(LegalText.licenses.contains("SponsorBlock") && LegalText.licenses.contains("CC BY-NC-SA 4.0") && LegalText.privacy.contains("first 4 characters of a hash"))
    }
}

extension EnhancementStore {
    /// Test only: the "enabled" preference alone, as if it had been edited by hand.
    func isolatedSetEnabledForTest(_ e: PageEnhancement) { setEnabledOnlyForTest(e) }
}

@Suite("Page enhancements: rules") struct EnhancementRulesTests {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    @Test func theBundledFileIsTheBuiltInCopyAndValid() throws {
        let url = ServiceSources.root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/youtube-ads.json")
        let file = try Data(contentsOf: url)
        #expect(YouTubeAdRules.validated(file) == YouTubeAdRules.builtIn)
        #expect(file.count < YouTubeAdRules.maxBytes)
    }

    @Test func unexpectedEntriesAreRefusedWhole() {
        let ok = ##"{"version":1,"stripKeys":["adPlacements"],"hideSelectors":["#a"],"skipSelectors":[".b"]}"##
        #expect(YouTubeAdRules.validated(data(ok)) != nil)
        for bad in [
            #"{"version":1,"stripKeys":["a-b"],"hideSelectors":[],"skipSelectors":[]}"#,
            #"{"version":1,"stripKeys":["adPlacements"],"hideSelectors":["a{display:none}"],"skipSelectors":[]}"#,
            #"{"version":1,"stripKeys":["adPlacements"],"hideSelectors":["a;b"],"skipSelectors":[]}"#,
            #"{"version":1,"stripKeys":["adPlacements"],"hideSelectors":[],"skipSelectors":["x[style='background:url(x)']"]}"#,
            #"{"version":1,"stripKeys":[],"hideSelectors":[],"skipSelectors":[]}"#,
            #"{"version":0,"stripKeys":["a"],"hideSelectors":[],"skipSelectors":[]}"#,
            #"{"version":1,"stripKeys":["a"],"hideSelectors":[]}"#,
            "not json",
        ] { #expect(YouTubeAdRules.validated(data(bad)) == nil, "\(bad)") }
        let big = Data(repeating: 0x20, count: YouTubeAdRules.maxBytes + 1)
        #expect(YouTubeAdRules.validated(big) == nil)
    }

    @Test func theScriptCarriesTheRulesAsDataAndOnlyActsOnTheServiceHost() {
        let s = YouTubeAdRules.builtIn.script
        #expect(s.contains("\"adPlacements\"") && s.contains("ytd-ad-slot-renderer") && s.contains("ytp-skip-ad-button"))
        #expect(s.contains("youtube\\.com"))
    }
}

@Suite("Page enhancements: ad skipping on a stand-in page", .serialized) @MainActor struct AdSkipStandInTests {
    static let page = """
    <html><head><script>var ytInitialPlayerResponse = {adPlacements:[1], playerAds:[2], adSlots:[3], videoDetails:{title:'t'}};</script></head>
    <body><div id="masthead-ad" style="height:20px">ad</div><div id="keep">content</div>
    <div id="movie_player" class="html5-video-player ad-showing"><video id="v"></video><button class="ytp-skip-ad-button" onclick="window.clicked=true">Skip</button></div>
    <script>
    var v = document.getElementById('v'), t = 0, muted = false, rate = 1;
    Object.defineProperty(v, 'duration', { get: function () { return 30; } });
    Object.defineProperty(v, 'currentTime', { get: function () { return t; }, set: function (x) { t = x; } });
    Object.defineProperty(v, 'muted', { get: function () { return muted; }, set: function (x) { muted = x; } });
    Object.defineProperty(v, 'playbackRate', { get: function () { return rate; }, set: function (x) { rate = x; } });
    </script></body></html>
    """

    private func web(_ r: EnhancementRuntime, base: String) async -> WKWebView {
        let (cfg, _) = EnhancementRig.config(EnhancementRig.youtube, r)
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 400), configuration: cfg)
        await EnhancementRig.load(w, Self.page, base: base)
        return w
    }

    @Test func theAdScheduleIsStrippedAdBoxesHiddenAndARunningAdIsSkipped() async throws {
        _ = NSApplication.shared
        let r = EnhancementRig.runtime(); r.store.grant(.adSkip)
        let w = await web(r, base: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        let keys = try await w.evaluateJavaScript("JSON.stringify(Object.keys(ytInitialPlayerResponse))") as? String
        #expect(keys == "[\"videoDetails\"]", "the inline player data lost its ad schedule: \(keys ?? "nil")")
        let parsed = try await w.evaluateJavaScript("JSON.stringify(Object.keys(JSON.parse('{\"playerResponse\":{\"adPlacements\":[1],\"keep\":1},\"adSlots\":[3],\"x\":1}').playerResponse))") as? String
        #expect(parsed == "[\"keep\"]")
        let display = try await w.evaluateJavaScript("getComputedStyle(document.getElementById('masthead-ad')).display") as? String
        #expect(display == "none", "an ad box is hidden")
        let keep = try await w.evaluateJavaScript("getComputedStyle(document.getElementById('keep')).display") as? String
        #expect(keep != "none", "real content is not")
        try await Task.sleep(for: .seconds(1.2))
        let state = try await w.evaluateJavaScript("JSON.stringify({t: document.getElementById('v').currentTime, m: document.getElementById('v').muted, clicked: !!window.clicked})") as? String ?? ""
        #expect(state.contains("\"t\":30") && state.contains("\"clicked\":true"), "the skip button was clicked and the ad run to its end: \(state)")
    }

    @Test func withoutTheOptionOrOnAnotherSiteTheSamePageIsUntouched() async throws {
        _ = NSApplication.shared
        let off = await web(EnhancementRig.runtime(), base: "https://www.youtube.com/")
        let a = try await off.evaluateJavaScript("JSON.stringify(Object.keys(ytInitialPlayerResponse))") as? String
        #expect(a == "[\"adPlacements\",\"playerAds\",\"adSlots\",\"videoDetails\"]", "off by default: nothing removed: \(a ?? "nil")")
        let on = EnhancementRig.runtime(); on.store.grant(.adSkip)
        let other = await web(on, base: "https://video.example/")
        let b = try await other.evaluateJavaScript("JSON.stringify(Object.keys(ytInitialPlayerResponse))") as? String
        #expect(b == "[\"adPlacements\",\"playerAds\",\"adSlots\",\"videoDetails\"]", "the script does nothing on another host")
    }
}

@Suite("Page enhancements: sponsor skipping") @MainActor struct SponsorSkipTests {
    static let id = "dQw4w9WgXcQ"
    static let segment = SponsorSpan(start: 1.0, end: 2.5, category: "sponsor", uuid: "s1")

    @Test func theRequestCarriesOnlyAFourCharacterHashPrefixAndNothingElse() throws {
        #expect(SponsorVideoID.hashPrefix(Self.id) == "5f6b")
        let url = try #require(SponsorBlockClient.requestURL(videoID: Self.id))
        #expect(url.scheme == "https" && url.host == "sponsor.ajay.app" && url.path == "/api/skipSegments/5f6b" && url.port == nil && url.user == nil && url.password == nil && url.fragment == nil)
        #expect(!url.absoluteString.contains(Self.id), "the identifier itself is never sent")
        let names = Set(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map(\.name))
        #expect(names == ["categories", "actionTypes"], "no other parameter (no account, no identifier)")
        let expected = SHA256.hash(data: Data(Self.id.utf8)).map { String(format: "%02x", $0) }.joined().prefix(4)
        #expect(String(expected) == SponsorVideoID.hashPrefix(Self.id))
        #expect(SponsorBlockClient.requestURL(videoID: "short") == nil && SponsorBlockClient.requestURL(videoID: "../etc/passwd") == nil)
        let src = try ServiceSources.text(["Services/Streaming/Enhancements"])
        #expect(src.contains("httpCookieStorage = nil") && src.contains("httpShouldSetCookies = false") && src.contains("urlCache = nil") && src.contains(".ephemeral"))
    }

    @Test func theClientReducesTheAnswerAndEveryFailureIsSilent() async throws {
        let body = #"""
        [{"videoID":"aaaaaaaaaaa","segments":[{"segment":[5,9],"category":"sponsor","UUID":"x","actionType":"skip"}]},
         {"videoID":"dQw4w9WgXcQ","segments":[
            {"segment":[1,2.5],"category":"sponsor","UUID":"s1","actionType":"skip"},
            {"segment":[2,4],"category":"sponsor","UUID":"s2","actionType":"skip"},
            {"segment":[10,11],"category":"intro","UUID":"s3","actionType":"skip"},
            {"segment":[20,20.1],"category":"sponsor","UUID":"s4","actionType":"skip"},
            {"segment":[30,40],"category":"sponsor","UUID":"s5","actionType":"mute"},
            {"segment":[-1,3],"category":"sponsor","UUID":"s6","actionType":"skip"}]}]
        """#
        nonisolated(unsafe) var requested: [URL] = []
        var client = SponsorBlockClient()
        client.transport = { url in requested.append(url); return (Data(body.utf8), 200) }
        let spans = try #require(await client.segments(forVideoID: Self.id))
        #expect(spans == [SponsorSpan(start: 1, end: 4, category: "sponsor", uuid: "s1")], "only this video, only sponsor, overlaps merged, bad numbers dropped: \(spans)")
        #expect(requested.count == 1 && requested[0].path == "/api/skipSegments/5f6b")
        client.transport = { _ in (Data(), 404) }
        #expect(await client.segments(forVideoID: Self.id) == [])
        client.transport = { _ in throw URLError(.timedOut) }
        #expect(await client.segments(forVideoID: Self.id) == nil, "a timeout degrades silently")
        client.transport = { _ in (Data("garbage".utf8), 200) }
        #expect(await client.segments(forVideoID: Self.id) == nil)
        client.transport = { _ in (Data(), 500) }
        #expect(await client.segments(forVideoID: Self.id) == nil)
    }

    private func handler(_ r: EnhancementRuntime) -> SponsorMessageHandler { SponsorMessageHandler(runtime: r, definition: EnhancementRig.youtube) }

    @Test func noRequestIsMadeWhenOffUnconsentedOrRestricted() async {
        func asks(_ r: EnhancementRuntime, _ fake: FakeSegments) async -> Int {
            let h = handler(r); h.handle(videoID: Self.id, reply: { _ in }); await h.settle(); return fake.asked.count
        }
        let f1 = FakeSegments([Self.segment]); #expect(await asks(EnhancementRig.runtime(f1), f1) == 0, "off")
        let f2 = FakeSegments([Self.segment]); let r2 = EnhancementRig.runtime(f2); r2.store.isolatedSetEnabledForTest(.sponsorSkip)
        #expect(await asks(r2, f2) == 0, "enabled but not agreed to")
        let f3 = FakeSegments([Self.segment]); let r3 = EnhancementRig.runtime(f3, restricted: true); r3.store.grant(.sponsorSkip)
        #expect(await asks(r3, f3) == 0, "kids or locked")
        let f4 = FakeSegments([Self.segment]); let r4 = EnhancementRig.runtime(f4); r4.store.grant(.adSkip)
        #expect(await asks(r4, f4) == 0, "only the other option is on")
        let f5 = FakeSegments([Self.segment]); let r5 = EnhancementRig.runtime(f5); r5.store.grant(.sponsorSkip)
        #expect(await asks(r5, f5) == 1 && f5.asked == [Self.id], "on and agreed to: exactly one request, for this video")
    }

    @Test func theAnswerIsRememberedFailuresAndEmptyAnswersSayNothingAndAMessageFromElsewhereIsRefused() async {
        let fake = FakeSegments([Self.segment]); let r = EnhancementRig.runtime(fake); r.store.grant(.sponsorSkip)
        let h = handler(r)
        nonisolated(unsafe) var replies: [String] = []
        h.handle(videoID: Self.id, reply: { replies.append($0) }); await h.settle()
        h.handle(videoID: Self.id, reply: { replies.append($0) }); await h.settle()
        #expect(fake.asked.count == 1 && replies.count == 2 && replies[0].contains("\"uuid\":\"s1\""), "remembered in memory, not asked twice")
        let bad = FakeSegments(nil); let rb = EnhancementRig.runtime(bad); rb.store.grant(.sponsorSkip)
        let hb = handler(rb); nonisolated(unsafe) var n = 0
        hb.handle(videoID: Self.id, reply: { _ in n += 1 }); await hb.settle()
        #expect(bad.asked.count == 1 && n == 0, "a failed lookup does nothing visible")
        let policy = EnhancementRig.youtube.urlPolicy
        #expect(SponsorMessageHandler.originAllowed(host: "www.youtube.com", scheme: "https", isMainFrame: true, policy: policy))
        #expect(!SponsorMessageHandler.originAllowed(host: "www.youtube.com", scheme: "http", isMainFrame: true, policy: policy))
        #expect(!SponsorMessageHandler.originAllowed(host: "www.youtube.com", scheme: "https", isMainFrame: false, policy: policy))
        #expect(!SponsorMessageHandler.originAllowed(host: "youtube.com.evil.example", scheme: "https", isMainFrame: true, policy: policy))
    }

    static let page = """
    <html><body><div id="movie_player" class="html5-video-player"><video id="v" class="html5-main-video"></video></div></body></html>
    """

    private func world(_ w: WKWebView, _ js: String) async -> Any? {
        try? await w.callAsyncJavaScript(js, contentWorld: WKContentWorld.world(name: SponsorSkipScript.worldName))
    }

    /// The video is steered by seeking, as a person scrubbing does; its length and position come from the test (a hidden web view may not load media).
    private func standIn(_ w: WKWebView) async {
        _ = await world(w, """
            var v = document.getElementById('v'), t = 0;
            Object.defineProperty(v, 'duration', { get: function () { return 60; } });
            Object.defineProperty(v, 'paused', { get: function () { return true; } });
            Object.defineProperty(v, 'currentTime', { get: function () { return t; }, set: function (x) { t = x; setTimeout(function () { v.dispatchEvent(new Event('seeked')); }, 0); } });
            return true;
            """)
    }

    private func time(_ w: WKWebView) async -> Double { (await world(w, "return document.getElementById('v').currentTime;") as? Double) ?? -1 }

    @Test func aMarkedSegmentIsSkippedWithAnUndoAndNothingHappensWhenItIsOff() async throws {
        _ = NSApplication.shared
        let fake = FakeSegments([Self.segment]); let r = EnhancementRig.runtime(fake); r.store.grant(.sponsorSkip)
        let (cfg, inst) = EnhancementRig.config(EnhancementRig.youtube, r)
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 400), configuration: cfg)
        await EnhancementRig.load(w, Self.page, base: "https://www.youtube.com/watch?v=\(Self.id)")
        await standIn(w)
        // the page asked, the app answered through the real message path
        for _ in 0..<50 { if let s = await world(w, SponsorSkipScript.stats) as? String, s.contains("\"count\":1") { break }; try await Task.sleep(for: .milliseconds(100)) }
        #expect(fake.asked == [Self.id], "one request, for this video")
        let stats = await world(w, SponsorSkipScript.stats) as? String ?? ""
        #expect(stats.contains("\"count\":1"), Comment(rawValue: stats))
        _ = await world(w, "document.getElementById('v').currentTime = 1.3; await new Promise(function (r) { setTimeout(r, 600); }); return true;")
        let after = await time(w)
        #expect(after >= 2.5, "the video jumped over the segment (now at \(after))")
        let label = await world(w, "var b = document.querySelector('[data-ss-sponsor] button'); return b ? b.textContent : null;") as? String
        #expect(label == "Undo", "a small note with Undo is shown")
        _ = await world(w, "document.querySelector('[data-ss-sponsor] button').click(); return true;")
        try await Task.sleep(for: .seconds(0.7))
        let back = await time(w)
        #expect(back < 2.5 && back >= 0.9, "Undo went back to the start of the segment (at \(back))")
        let again = await world(w, "document.getElementById('v').currentTime = 1.2; await new Promise(function (r) { setTimeout(r, 600); }); return document.getElementById('v').currentTime;") as? Double ?? -1
        #expect(again < 2.5, "an undone segment is not skipped again (at \(again))")
        _ = inst

        // off: no script, no handler, no request
        let fake2 = FakeSegments([Self.segment]); let r2 = EnhancementRig.runtime(fake2)
        let (cfg2, _) = EnhancementRig.config(EnhancementRig.youtube, r2)
        #expect(cfg2.userContentController.userScripts.isEmpty)
        let w2 = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 400), configuration: cfg2)
        await EnhancementRig.load(w2, Self.page, base: "https://www.youtube.com/watch?v=\(Self.id)")
        try await Task.sleep(for: .seconds(0.8))
        #expect(fake2.asked.isEmpty)
    }

    @Test func itDoesNothingOnAProtectedVideoWhileAnAdPlaysOrAnotherVideoIsShown() async throws {
        _ = NSApplication.shared
        func run(markup: String = "", id: String = Self.id, protected: Bool = false) async throws -> Double {
            let fake = FakeSegments([SponsorSpan(start: 0.5, end: 3.0, category: "sponsor", uuid: "s1")]); let r = EnhancementRig.runtime(fake); r.store.grant(.sponsorSkip)
            let (cfg, _) = EnhancementRig.config(EnhancementRig.youtube, r)
            let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 400), configuration: cfg)
            await EnhancementRig.load(w, Self.page.replacingOccurrences(of: "html5-video-player", with: "html5-video-player \(markup)"), base: "https://www.youtube.com/watch?v=\(id)")
            await standIn(w)
            if protected { _ = await world(w, "Object.defineProperty(document.getElementById('v'), 'mediaKeys', { value: {} }); return true;") }
            for _ in 0..<50 { if let s = await world(w, SponsorSkipScript.stats) as? String, s.contains("\"count\":1") { break }; try await Task.sleep(for: .milliseconds(100)) }
            _ = await world(w, "document.getElementById('v').currentTime = 1.0; await new Promise(function (r) { setTimeout(r, 600); }); return true;")
            return await time(w)
        }
        let control = try await run()
        #expect(control >= 3.0, "the control skips (at \(control)); without it the cases below could pass because nothing works")
        #expect(try await run(protected: true) == 1.0)
        #expect(try await run(markup: "ad-showing") == 1.0)
    }
}

@Suite("Page enhancements: shots") @MainActor struct EnhancementShotsTests {
    /// Renders the Settings section and the first-open card to PNG for a look. Runs only when ENHANCEMENT_SHOTS names a folder.
    @Test func renderSettingsAndTheFirstOpenCard() throws {
        guard let dir = ProcessInfo.processInfo.environment["ENHANCEMENT_SHOTS"] else { return }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func shot<V: View>(_ view: V, _ size: CGSize, _ file: String, dark: Bool) throws {
            let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height, alignment: .top).background(dark ? Color(white: 0.12) : Color.white).environment(\.colorScheme, dark ? .dark : .light)))
            host.frame = NSRect(origin: .zero, size: size)
            let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            win.contentView = host; win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for _ in 0..<8 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: dir).appendingPathComponent(file))
            withExtendedLifetime(win) {}
        }
        let r = EnhancementRig.runtime(); r.isRestricted = { false }
        let model = EnhancementToggleModel(runtime: r)
        for dark in [true, false] {
            let tag = dark ? "dark" : "light"
            try shot(EnhancementPromptCard(enhancements: [.adSkip, .sponsorSkip], model: model) {}, CGSize(width: 520, height: 200), "prompt-\(tag).png", dark: dark)
            try shot(VStack(alignment: .leading) { ForEach(PageEnhancement.allCases) { EnhancementToggleRow(enhancement: $0, model: model) } }.padding(20), CGSize(width: 620, height: 170), "settings-toggles-\(tag).png", dark: dark)
        }
        let was = EnhancementRuntime.shared.isRestricted
        EnhancementRuntime.shared.isRestricted = { false }
        defer { EnhancementRuntime.shared.isRestricted = was }
        try shot(StreamingServicesSettingsSection().padding(20), CGSize(width: 720, height: 2000), "settings-section.png", dark: false)
    }
}
