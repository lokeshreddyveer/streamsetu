import Testing
import WebKit
import AppKit
@testable import REDDY

/// Spotify as the eleventh embedded service: its definition, address policy, the two page options (gating, rule list, mute script) and what they
/// must never touch. Fixtures only: pages are loaded from strings with a base address, there is no real Spotify, account or session.
@MainActor extension EnhancementRig {
    static var spotify: ProviderDefinition { ProviderCatalog.all.first { $0.id == .spotify }! }
    static func eval(_ web: WKWebView, _ js: String) async -> Any? { try? await web.evaluateJavaScript(js) }
    static func waitFor(_ web: WKWebView, _ js: String, timeout: Double = 6) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if (await eval(web, js) as? Bool) == true { return true }; try? await Task.sleep(for: .milliseconds(100)) }
        return (await eval(web, js) as? Bool) == true
    }
}

@Suite("Spotify: definition and address policy") @MainActor struct SpotifyDefinitionTests {
    private let spotify = EnhancementRig.spotify
    private func d(_ s: String, redirect: Bool = false, main: Bool = true) -> ProviderURLPolicy.Decision { spotify.urlPolicy.decide(URL(string: s), isMainFrame: main, isRedirect: redirect) }

    @Test func itIsTheEleventhEmbeddedServiceWithItsOwnFrozenStore() {
        let reg = ProviderRegistry.standard
        #expect(reg.definitions.count == 12 && reg.definitions.filter { $0.presentation == .embedded }.count == 11)
        #expect(Set(reg.definitions.map(\.id)).count == 12 && Set(reg.definitions.map(\.storeIdentity.uuid)).count == 12)
        #expect(spotify.storeIdentity.uuid == UUID(uuidString: "f00c305d-909f-420c-b11e-c7ce68a5a3e3"))
        #expect(reg.definition(for: .netflix)?.storeIdentity.uuid == UUID(uuidString: "afdfb6b8-2671-42a0-bd87-6973dcd90758"), "Netflix's store identity is unchanged")
        #expect(spotify.displayName == "Spotify" && spotify.homeURL.absoluteString == "https://open.spotify.com" && spotify.userAgentProfile == .safari)
        #expect(spotify.availability == .unverified && spotify.distributionAuthorization == .unresolved && spotify.capabilities.compatibility == .unchecked)
        #expect(spotify.externalLinks == .blockWithNotice && spotify.zoomDefaultsKey == "streaming.zoom.spotify" && spotify.regionProfile == nil)
        #expect(spotify.pageEnhancements == [.spotifyHideAds, .spotifyMuteAds])
        #expect(ProviderRegistry.validate(reg.definitions).isEmpty)
        #expect(ServiceCapabilities.macOS.allows(.spotify))
    }

    @Test func itsOwnHostsLoadAndLookalikesDoNot() {
        for u in ["https://open.spotify.com/", "https://open.spotify.com/track/x?si=1", "https://accounts.spotify.com/en/login", "https://www.spotify.com/account/overview/"] { #expect(d(u) == .allowInApp, Comment(rawValue: u)) }
        for u in ["https://spotify.com.evil.example/", "https://evilspotify.com/", "https://open-spotify.com/", "https://evil.example/open.spotify.com", "https://notspotify.com/"] {
            #expect(d(u) == .openExternally, Comment(rawValue: u))
        }
        #expect(d("https://open.spotify.com@evil.example/") == .block && d("https://user:pw@open.spotify.com/") == .block)
        #expect(d("http://open.spotify.com/") == .block && d("https://open.spotify.com:8443/") == .block)
        // Apple and Facebook sign-in are not allowed, and nor is any other Google host than the exact sign-in hosts
        for u in ["https://appleid.apple.com/auth", "https://www.facebook.com/login", "https://www.google.com/", "https://myaccount.google.com/"] { #expect(d(u) == .openExternally, Comment(rawValue: u)) }
        #expect(d("https://spotify.link/x") == .openExternally && d("https://spotify.link/x", redirect: true) == .allowInApp, "the short link is a redirect hop only")
        // CDN, captcha and API hosts are sub-resources and frames: embedded frames over https load, the same as for every service
        #expect(d("https://www.google.com/recaptcha/api2/anchor", main: false) == .allowInApp)
        #expect(d("http://i.scdn.co/x", main: false) == .block)
    }
}

@Suite("Spotify: page option gating") @MainActor struct SpotifyGatingTests {
    private let spotify = EnhancementRig.spotify

    @Test func offByDefaultAndNothingIsInjected() {
        let r = EnhancementRig.runtime()
        #expect(r.active(for: spotify).isEmpty && EnhancementRig.scripts(spotify, r).isEmpty)
        let c = WKUserContentController(); let inst = EnhancementInstaller(definition: spotify, runtime: r); inst.apply(to: c)
        #expect(c.userScripts.isEmpty && !inst.hasRuleList && inst.installed.isEmpty)
    }

    @Test func enabledWithoutAgreementDoesNothing() {
        let r = EnhancementRig.runtime()
        r.store.isolatedSetEnabledForTest(.spotifyHideAds); r.store.isolatedSetEnabledForTest(.spotifyMuteAds)
        #expect(r.active(for: spotify).isEmpty && EnhancementRig.scripts(spotify, r).isEmpty)
    }

    @Test func eachOptionIsIndependentAndConsentIsPerService() {
        let r = EnhancementRig.runtime()
        r.store.grant(.adSkip); r.store.grant(.sponsorSkip)
        #expect(r.active(for: spotify).isEmpty, "YouTube's agreement is not reused for Spotify")
        r.store.grant(.spotifyMuteAds)
        #expect(r.active(for: spotify) == [.spotifyMuteAds] && r.active(for: EnhancementRig.youtube) == [.adSkip, .sponsorSkip])
        let scripts = EnhancementRig.scripts(spotify, r)
        #expect(scripts.count == 1 && scripts[0].isForMainFrameOnly && scripts[0].source.contains("open.spotify.com"))
        let fresh = EnhancementRig.runtime(); fresh.store.grant(.spotifyHideAds)
        #expect(fresh.active(for: EnhancementRig.youtube).isEmpty, "Spotify's agreement is not reused for YouTube")
        #expect(fresh.active(for: spotify) == [.spotifyHideAds] && EnhancementRig.scripts(spotify, fresh).isEmpty, "the rule-list option adds no script")
    }

    @Test func neverInAKidsProfileOrWhileLockedAndNeverForAnotherService() {
        let local = EnhancementRig.runtime(restricted: true); EnhancementRig.grantAll(local)
        #expect(local.active(for: spotify).isEmpty && EnhancementRig.scripts(spotify, local).isEmpty)
        let r = EnhancementRig.runtime(); EnhancementRig.grantAll(r)
        #expect(r.active(for: spotify).count == 2)
        for def in ProviderCatalog.all where def.id != .spotify { #expect(r.active(for: def).isDisjoint(with: [.spotifyHideAds, .spotifyMuteAds]), "\(def.id)") }
        var borrowed = EnhancementRig.youtube; borrowed.pageEnhancements = [.spotifyHideAds, .spotifyMuteAds]
        #expect(r.active(for: borrowed).isEmpty, "the Spotify options are tied to Spotify's own definition")
    }

    @Test func theKillSwitchStopsEverythingWhateverTheChoices() {
        let r = EnhancementRig.runtime(); EnhancementRig.grantAll(r)
        r.spotifyKillSwitch = { true }
        #expect(r.active(for: spotify).isEmpty && EnhancementRig.scripts(spotify, r).isEmpty)
        #expect(r.active(for: EnhancementRig.youtube).count == 2, "and it touches nothing else")
    }

    @Test func theFirstOpenCardIsSeparatePerServiceAndStatesTheRisks() {
        let r = EnhancementRig.runtime()
        #expect(r.shouldPrompt(for: spotify))
        r.store.recordPromptAnswered(for: .youtube)
        #expect(r.shouldPrompt(for: spotify), "answering YouTube's card does not answer Spotify's")
        #expect(!EnhancementRig.runtime(restricted: true).shouldPrompt(for: spotify))
        r.store.recordPromptAnswered(for: .spotify)
        #expect(!r.shouldPrompt(for: spotify))
        let copy = PageEnhancement.promptCopy(for: .spotify)
        for needle in ["terms prohibit blocking or circumventing its ads", "suspending or terminating your account", "best effort and can stop working at any time", "Premium accounts see no ads", "at your own risk", "Both options are off"] {
            #expect((copy.title + " " + copy.detail).contains(needle), Comment(rawValue: needle))
        }
        for e in [PageEnhancement.spotifyHideAds, .spotifyMuteAds] { #expect(e.consentMessage.contains(PageEnhancement.spotifyRisks)) }
        #expect(PageEnhancement.promptCopy(for: .youtube).title.hasPrefix("Skip ads and sponsor segments on YouTube?"), "YouTube's card is unchanged")
    }

    @Test func turningOnAsksFirstAndRecordsAnAgreementPerOption() throws {
        let r = EnhancementRig.runtime(); let m = EnhancementToggleModel(runtime: r)
        m.set(.spotifyMuteAds, on: true)
        #expect(m.pending == .spotifyMuteAds && !m.isOn(.spotifyMuteAds))
        m.cancel(); #expect(r.store.consent(.spotifyMuteAds) == nil)
        m.set(.spotifyMuteAds, on: true); m.confirm()
        #expect(m.isOn(.spotifyMuteAds) && !m.isOn(.spotifyHideAds) && r.store.consent(.spotifyMuteAds) != nil && !r.store.hasConsent(.adSkip))
    }
}

@Suite("Spotify: content rule list", .serialized) @MainActor struct SpotifyRuleListTests {
    private func rules() throws -> [[String: Any]] { try #require(JSONSerialization.jsonObject(with: Data(SpotifyAdRules.json.utf8)) as? [[String: Any]]) }
    private func matches(_ pattern: String, _ url: String) -> Bool { url.range(of: pattern, options: .regularExpression) != nil }
    private func blocked(_ url: String) -> Bool { SpotifyAdRules.blockedURLPatterns.contains { matches($0, url) } }
    private func tempStore() -> (WKContentRuleListStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spotify-rules-\(UUID().uuidString)")
        return (WKContentRuleListStore(url: dir)!, dir)
    }

    @Test func everyRuleIsScopedToTheSpotifyPageAndIsABlockOrAHide() throws {
        let all = try rules()
        #expect(all.count == SpotifyAdRules.blockedURLPatterns.count + 1)
        for r in all {
            let trigger = try #require(r["trigger"] as? [String: Any]), action = try #require(r["action"] as? [String: Any])
            #expect(trigger["if-domain"] as? [String] == ["*open.spotify.com"])
            #expect(["block", "css-display-none"].contains(action["type"] as? String ?? ""))
        }
    }

    @Test func itCompilesInTheSystemRuleStore() async throws {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let list = await SpotifyAdRules.list(in: store)
        #expect(list != nil && list?.identifier == SpotifyAdRules.identifier)
        #expect(await SpotifyAdRules.list(in: store) != nil, "found again, not recompiled")
    }

    @Test func itBlocksOnlyAdEndpointsNeverMusicLicenceOrCDNRequests() {
        for u in ["https://spclient.wg.spotify.com/ad-logic/v1/ads", "https://gew4-spclient.spotify.com/ad-logic/x", "https://adstudio-assets.scdn.co/a.mp3",
                  "https://creativeservice-production.scdn.co/mp3-ad/abc.mp3", "https://media-us.amillionads.com/a.mp3", "https://cf.adxcel.com/x", "https://s0.2mdn.net/v.mp4",
                  "https://adclick.g.doubleclick.net/pcs/click", "https://www.spotify.com/ads/x"] { #expect(blocked(u), Comment(rawValue: u)) }
        for u in ["https://audio-ak-spotify-com.akamaized.net/audio/abc", "https://audio4-fa.spotifycdn.com/audio/abc", "https://i.scdn.co/image/ab67", "https://open.spotifycdn.com/cdn/js/x.js",
                  "https://spclient.wg.spotify.com/melody/v1/license_url", "https://gew4-spclient.spotify.com/widevine-license/v1/audio/license",
                  "https://spclient.wg.spotify.com/storage-resolve/files/audio/interactive/abc", "https://spclient.wg.spotify.com/gabo-receiver-service/v3/events",
                  "https://open.spotify.com/", "https://api.spotify.com/v1/me/player", "https://dealer.spotify.com/", "https://accounts.spotify.com/login",
                  "https://accounts.google.com/", "https://www.netflix.com/ad-logic/", "https://www.youtube.com/ads/", "https://www.youtube.com/watch?v=x"] { #expect(!blocked(u), Comment(rawValue: u)) }
    }

    @Test func theHiddenElementsAreAdAndUpgradeMarkersOnly() {
        let all = SpotifyAdRules.hiddenSelectors.joined(separator: " ").lowercased()
        for banned in ["audio", "video", "now-playing", "player", "track", "playlist", "play-button", "playbutton", "control"] { #expect(!all.contains(banned), Comment(rawValue: banned)) }
        #expect(SpotifyAdRules.hiddenSelectors.contains(#"div[aria-label="Advertisement"]"#))
    }

    @Test func theInstallerAddsItOnlyWhileOnAndRemovesItWhenOff() async throws {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = EnhancementRig.runtime(); r.store.grant(.spotifyHideAds)
        let c = WKUserContentController()
        let inst = EnhancementInstaller(definition: EnhancementRig.spotify, runtime: r, ruleStore: { store })
        inst.apply(to: c)
        #expect(await ServiceTestSupport.until(90) { inst.hasRuleList })
        r.store.disable(.spotifyHideAds)
        inst.apply(to: c)
        #expect(!inst.hasRuleList && inst.installed.isEmpty, "off removes it")
        // never for another service, even with everything granted
        let g = EnhancementRig.runtime(); EnhancementRig.grantAll(g)
        let yc = WKUserContentController(); let yi = EnhancementInstaller(definition: EnhancementRig.youtube, runtime: g, ruleStore: { store })
        yi.apply(to: yc)
        try? await Task.sleep(for: .milliseconds(500))
        #expect(!yi.hasRuleList)
    }

    @Test func aFailedCompileLeavesThePageAsItWas() async {
        // a store that cannot be written: nothing is added and nothing throws
        let bad = WKContentRuleListStore(url: URL(fileURLWithPath: "/dev/null/none"))!
        #expect(await SpotifyAdRules.list(in: bad) == nil)
    }

    @Test func itHidesAdElementsOnAFixturePageAndLeavesOthers() async throws {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let list = try #require(await SpotifyAdRules.list(in: store))
        let cfg = WKWebViewConfiguration(); cfg.websiteDataStore = .nonPersistent(); cfg.userContentController.add(list)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: cfg)
        let html = ##"<html><body><div id="ad" aria-label="Advertisement">ad</div><a id="adlink" data-context-item-type="ad" href="#">x</a><div id="ok">music</div></body></html>"##
        await EnhancementRig.load(web, html, base: "https://open.spotify.com/")
        let shown = await EnhancementRig.waitFor(web, "getComputedStyle(document.getElementById('ad')).display === 'none' && getComputedStyle(document.getElementById('adlink')).display === 'none'")
        #expect(shown, "ad elements hidden")
        #expect(await EnhancementRig.eval(web, "getComputedStyle(document.getElementById('ok')).display") as? String == "block")
        // another page (other domain) with the same markup is untouched
        let other = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: { let c = WKWebViewConfiguration(); c.websiteDataStore = .nonPersistent(); c.userContentController.add(list); return c }())
        await EnhancementRig.load(other, html, base: "https://example.com/")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await EnhancementRig.eval(other, "getComputedStyle(document.getElementById('ad')).display") as? String == "block")
    }
}

@Suite("Spotify: mute while an ad plays", .serialized) @MainActor struct SpotifyMuteScriptTests {
    private func page(host: String, installing r: EnhancementRuntime) async -> WKWebView {
        let (cfg, _) = EnhancementRig.config(EnhancementRig.spotify, r)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: cfg)
        let html = #"<html><head><title>Some Song</title></head><body><audio id="a"></audio><audio id="b"></audio><video id="v"></video><div data-testid="now-playing-widget" id="w"></div></body></html>"#
        await EnhancementRig.load(web, html, base: host)
        return web
    }
    private func muted(_ web: WKWebView) async -> [Bool] {
        (await EnhancementRig.eval(web, "['a','b','v'].map(function(i){return document.getElementById(i).muted})") as? [Bool]) ?? []
    }

    @Test func mutesOnlyWhileAnAdShowsAndRestoresEachElementsEarlierState() async {
        let r = EnhancementRig.runtime(); r.store.grant(.spotifyMuteAds)
        let web = await page(host: "https://open.spotify.com/", installing: r)
        _ = await EnhancementRig.eval(web, "document.getElementById('b').muted = true; document.getElementById('a').playbackRate = 1.25; 0")
        try? await Task.sleep(for: .milliseconds(700))
        #expect(await muted(web) == [false, true, false], "no ad: nothing changes")
        _ = await EnhancementRig.eval(web, "document.title = 'Advertisement - Spotify'; 0")
        #expect(await EnhancementRig.waitFor(web, "['a','b','v'].every(function(i){return document.getElementById(i).muted})"), "muted while the ad plays")
        _ = await EnhancementRig.eval(web, "document.title = 'Some Song'; 0")
        #expect(await EnhancementRig.waitFor(web, "!document.getElementById('a').muted && !document.getElementById('v').muted && document.getElementById('b').muted"), "restored: b was muted before and stays muted")
        #expect(await EnhancementRig.eval(web, "document.getElementById('a').playbackRate") as? Double == 1.25, "speed untouched")
    }

    @Test func theNowPlayingWidgetMarkerAlsoCounts() async {
        let r = EnhancementRig.runtime(); r.store.grant(.spotifyMuteAds)
        let web = await page(host: "https://open.spotify.com/", installing: r)
        _ = await EnhancementRig.eval(web, "document.getElementById('w').setAttribute('aria-label','Now playing: Advertisement'); 0")
        #expect(await EnhancementRig.waitFor(web, "document.getElementById('a').muted"))
        _ = await EnhancementRig.eval(web, "document.getElementById('w').setAttribute('aria-label','Now playing: A Song'); 0")
        #expect(await EnhancementRig.waitFor(web, "!document.getElementById('a').muted"))
    }

    @Test func doesNothingOnAnyOtherSiteIncludingSignInHostsOrWithoutTheOption() async {
        let r = EnhancementRig.runtime(); r.store.grant(.spotifyMuteAds)
        for host in ["https://example.com/", "https://accounts.google.com/", "https://accounts.spotify.com/"] {
            let web = await page(host: host, installing: r)
            _ = await EnhancementRig.eval(web, "document.title = 'Advertisement'; 0")
            try? await Task.sleep(for: .milliseconds(700))
            #expect(await muted(web) == [false, false, false], Comment(rawValue: host))
        }
        let off = EnhancementRig.runtime()
        let web = await page(host: "https://open.spotify.com/", installing: off)
        _ = await EnhancementRig.eval(web, "document.title = 'Advertisement'; 0")
        try? await Task.sleep(for: .milliseconds(700))
        #expect(await muted(web) == [false, false, false], "option off: no script")
    }
}
