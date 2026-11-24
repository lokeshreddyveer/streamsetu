import Testing
import WebKit
import AppKit
@testable import REDDY

/// Tidy pages (cosmetic install-app banners) and Hide This Element. Synthetic fixtures only: isolated preference suites, a throwaway rule store and
/// pages loaded from strings, never a real service or its session.
@MainActor private enum TidyRig {
    static func store() -> TidyStore { TidyStore(defaults: UserDefaults(suiteName: "tidy-test-" + UUID().uuidString)!) }
    static func ruleStore() -> (WKContentRuleListStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidy-rules-\(UUID().uuidString)")
        return (WKContentRuleListStore(url: dir)!, dir)
    }
    static func def(_ id: ProviderID) -> ProviderDefinition { ProviderCatalog.all.first { $0.id == id }! }
    static func rules(_ id: ProviderID, on: Bool, hidden: [String] = []) throws -> [[String: Any]] {
        let json = try #require(TidyRuleList.json(for: id, tidyOn: on, hidden: hidden))
        return try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    }
    static func web(_ list: WKContentRuleList? = nil) -> WKWebView {
        let cfg = WKWebViewConfiguration(); cfg.websiteDataStore = .nonPersistent()
        if let list { cfg.userContentController.add(list) }
        return WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: cfg)
    }
}

@Suite("Tidy pages: rules, scope and installation") @MainActor struct TidyRulesTests {
    @Test func onByDefaultOnlyWhereThereAreRulesAndAChoiceOfOffIsKept() {
        let s = TidyRig.store()
        for d in ProviderCatalog.all {
            #expect(s.isEnabled(d.id) == !TidyRules.rules(for: d.id).isEmpty && s.hidden(d.id).isEmpty, Comment(rawValue: d.id.rawValue))
            #expect(TidyRuleList.json(for: d.id, tidyOn: false, hidden: []) == nil)
            #expect((TidyRuleList.json(for: d.id, tidyOn: s.isEnabled(d.id), hidden: []) != nil) == !TidyRules.rules(for: d.id).isEmpty)
        }
        #expect([ProviderID.youtube, .crunchyroll, .spotify].allSatisfy { s.isEnabled($0) })
        s.setEnabled(false, for: .youtube)
        #expect(!s.isEnabled(.youtube), "an explicit Off is respected")
        #expect(TidyStore(defaults: s.testDefaults).isEnabled(.youtube) == false, "and kept across launches")
        #expect(s.isEnabled(.spotify) && s.isEnabled(.crunchyroll), "the others are untouched")
    }

    @Test func aStoredChoiceIsNeverOverwrittenByTheNewDefault() {
        let d = UserDefaults(suiteName: "tidy-keep-" + UUID().uuidString)!
        d.set(false, forKey: TidyStore.enabledKey(.crunchyroll)); d.set(true, forKey: TidyStore.enabledKey(.hulu))
        let s = TidyStore(defaults: d)
        #expect(!s.isEnabled(.crunchyroll) && s.isEnabled(.hulu), "existing stored values are untouched; only a never-set default changed")
    }

    @Test func onlyServicesWithAStableMarkerHaveRulesAndJioHotstarHasNothingAtAll() {
        #expect(Set(TidyRules.rules.keys) == [.youtube, .crunchyroll, .spotify])
        for id in [ProviderID.netflix, .primevideo, .disneyplus, .hulu, .hbomax, .peacock, .paramountplus, .appletv] { #expect(TidyRules.rules(for: id).isEmpty && TidyRules.supports(id)) }
        #expect(!TidyRules.supports(.jiohotstar) && TidyRules.hosts(for: .jiohotstar).isEmpty && TidyRules.rules(for: .jiohotstar).isEmpty)
        #expect(TidyRuleList.json(for: .jiohotstar, tidyOn: true, hidden: [".x"]) == nil)
        for (_, list) in TidyRules.rules { for r in list { #expect(!r.hides.isEmpty && !r.source.isEmpty && !r.selector.isEmpty) } }
    }

    @Test func everyRuleIsAHideScopedToThatServicesOwnExactHostsOnly() throws {
        for id in ProviderCatalog.all.map(\.id) where !TidyRules.rules(for: id).isEmpty {
            let rules = try TidyRig.rules(id, on: true)
            #expect(rules.count == 1)
            for r in rules {
                let trigger = try #require(r["trigger"] as? [String: Any]), action = try #require(r["action"] as? [String: Any])
                #expect(action["type"] as? String == "css-display-none", "hide only, never block or script")
                #expect(trigger["if-domain"] as? [String] == TidyRules.hosts(for: id))
                #expect(trigger["unless-domain"] == nil && trigger["resource-type"] == nil)
            }
        }
    }

    @Test func hostsAreExactHostsOfTheServiceNeverAuthGoogleOrAnotherService() {
        var seen = Set<String>()
        for (id, hosts) in TidyRules.hosts {
            let policy = TidyRig.def(id).urlPolicy
            for h in hosts {
                #expect(!h.contains("*") && h == h.lowercased(), "exact host, no wildcard: \(h)")
                #expect(seen.insert(h).inserted, "no host shared by two services: \(h)")
                #expect(policy.isAllowedHost(h), "\(h) is one of the service's own site hosts")
                for rule in policy.hostRules where rule.role == .auth { #expect(!(h == rule.suffix || h.hasSuffix("." + rule.suffix)), "auth host \(rule.suffix)") }
                #expect(!HostRule.googleSignInHosts.contains(h))
            }
        }
        for h in ["accounts.google.com", "accounts.youtube.com", "accounts.spotify.com", "auth.max.com", "appleid.apple.com", "idmsa.apple.com", "disneyid.com"] {
            #expect(!TidyRules.hosts.values.joined().contains(h), Comment(rawValue: h))
        }
    }

    @Test func noRuleTouchesMusicVideoLicenceKeyOrCDNRequestsOrAConsentDialog() throws {
        let banned = ["video", "audio", "player", "license", "licence", "key", "cdn", "drm", "consent", "cookie", "privacy", "gdpr", "login", "signin", "sign-in", "paywall", "now-playing"]
        for (_, list) in TidyRules.rules { for r in list {
            let l = r.selector.lowercased()
            for b in banned { #expect(!l.contains(b), Comment(rawValue: "\(r.selector) has \(b)")) }
        } }
        for id in TidyRules.rules.keys {
            let rules = try TidyRig.rules(id, on: true, hidden: [".something"])
            #expect(rules.allSatisfy { ($0["action"] as? [String: Any])?["type"] as? String == "css-display-none" })
        }
        // the listed hosts are page hosts, so no request pattern for music, video, licence or CDN hosts exists in any list
        let spotify = try TidyRig.rules(.spotify, on: true)
        #expect(!String(describing: spotify).contains("scdn.co") && !String(describing: spotify).contains("spclient"))
    }

    @Test func spotifyInstallAppIsInTidyAndNotInTheAdOptionWhichIsUnchanged() {
        #expect(TidyRules.rules(for: .spotify).contains { $0.selector.contains("/download") })
        #expect(!SpotifyAdRules.hiddenSelectors.contains { $0.contains("/download") })
        #expect(SpotifyAdRules.hiddenSelectors.count == 9 && SpotifyAdRules.identifier == "setu.spotify.ads.v1" && SpotifyAdRules.domain == "*open.spotify.com")
        #expect(SpotifyAdRules.hiddenSelectors.contains(".main-topBar-UpgradeButton") && SpotifyAdRules.hiddenSelectors.contains(#"[aria-label="Upgrade to Premium"]"#))
    }

    @Test func tidyAndHiddenElementsMergeIntoOneListAndEachStandsAlone() throws {
        let hidden = ["div.cookie-free-nag"]
        let both = try TidyRig.rules(.youtube, on: true, hidden: hidden)
        let sel = try #require((both[0]["action"] as? [String: Any])?["selector"] as? String)
        for r in TidyRules.rules(for: .youtube) { #expect(sel.contains(r.selector)) }
        #expect(sel.contains("div.cookie-free-nag") && both.count == 1)
        let onlyHidden = try TidyRig.rules(.netflix, on: false, hidden: hidden)
        #expect(((onlyHidden[0]["action"] as? [String: Any])?["selector"] as? String) == "div.cookie-free-nag")
        let noHidden = try TidyRig.rules(.youtube, on: true)
        let plainSel = ((noHidden[0]["action"] as? [String: Any])?["selector"] as? String) ?? ""
        #expect(!plainSel.isEmpty && !plainSel.contains("cookie-free-nag"), Comment(rawValue: plainSel))
        #expect(TidyRuleList.json(for: .youtube, tidyOn: false, hidden: []) == nil)
        let a = TidyRuleList.identifier(for: .youtube, json: TidyRuleList.json(for: .youtube, tidyOn: true, hidden: [])!)
        let b = TidyRuleList.identifier(for: .youtube, json: TidyRuleList.json(for: .youtube, tidyOn: true, hidden: hidden)!)
        #expect(a != b && a.hasPrefix(TidyRuleList.prefix(for: .youtube)))
        // a hand-edited bad selector never reaches the list
        let bad = try TidyRig.rules(.netflix, on: false, hidden: ["a}{b", "div.ok"])
        #expect(((bad[0]["action"] as? [String: Any])?["selector"] as? String) == "div.ok")
    }

    @Test func theListCompilesAndTheInstallerAddsItWhileOnAndRemovesItWhenOff() async throws {
        let (rs, dir) = TidyRig.ruleStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = TidyRig.store()
        let c = WKUserContentController()
        let inst = TidyInstaller(definition: TidyRig.def(.youtube), store: s, restricted: { false }, ruleStore: { rs })
        inst.apply(to: c)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(await ServiceTestSupport.until(60) { inst.hasRuleList } && inst.wanted, "on by default for a service with rules: installed")
        s.setEnabled(false, for: .youtube); inst.apply(to: c)
        #expect(await ServiceTestSupport.until(60) { !inst.hasRuleList } && !inst.wanted, "an explicit Off removes it")
        s.setEnabled(true, for: .youtube); inst.apply(to: c)
        #expect(await ServiceTestSupport.until(60) { inst.hasRuleList })
        let first = inst.identifier
        s.addHidden("div.extra-nag", for: .youtube); inst.apply(to: c)
        #expect(await ServiceTestSupport.until(60) { inst.hasRuleList && inst.identifier != first }, "a changed list replaces the old one")
        let ids: [String] = await withCheckedContinuation { k in rs.getAvailableContentRuleListIdentifiers { k.resume(returning: $0 ?? []) } }
        #expect(ids.filter { $0.hasPrefix(TidyRuleList.prefix(for: .youtube)) }.count == 1, "the old compiled list is forgotten")
        s.setEnabled(false, for: .youtube); inst.apply(to: c)
        #expect(await ServiceTestSupport.until(60) { inst.hasRuleList && inst.identifier != first }, "off with a hidden element left: only the hidden list")
        s.resetHidden(for: .youtube); inst.apply(to: c)
        #expect(!inst.hasRuleList, "off and nothing hidden: removed")
    }

    @Test func nothingIsInstalledWhenRestrictedForAnotherServiceOrAfterACompileFailure() async throws {
        let (rs, dir) = TidyRig.ruleStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = TidyRig.store(); s.setEnabled(true, for: .youtube)
        let restricted = TidyInstaller(definition: TidyRig.def(.youtube), store: s, restricted: { true }, ruleStore: { rs })
        restricted.apply(to: WKUserContentController()); try? await Task.sleep(for: .milliseconds(400))
        #expect(!restricted.hasRuleList)
        let netflix = TidyInstaller(definition: TidyRig.def(.netflix), store: s, restricted: { false }, ruleStore: { rs })     // rules exist for YouTube only; Netflix is off
        netflix.apply(to: WKUserContentController()); try? await Task.sleep(for: .milliseconds(400))
        #expect(!netflix.hasRuleList)
        let jio = TidyInstaller(definition: TidyRig.def(.jiohotstar), store: s, restricted: { false }, ruleStore: { rs })
        #expect(!jio.wanted)
        let bad = WKContentRuleListStore(url: URL(fileURLWithPath: "/dev/null/none"))!
        let broken = TidyInstaller(definition: TidyRig.def(.youtube), store: s, restricted: { false }, ruleStore: { bad })
        broken.apply(to: WKUserContentController()); try? await Task.sleep(for: .milliseconds(600))
        #expect(!broken.hasRuleList, "a failed compile does nothing")
    }

    @Test func aFixtureInstallBannerIsHiddenOnTheServiceHostAndNothingElseIsTouched() async throws {
        let (rs, dir) = TidyRig.ruleStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let list = try #require(await TidyRuleList.list(for: .youtube, tidyOn: true, hidden: [], in: rs))
        let html = "<html><body><ytd-statement-banner-renderer id='nag'>Get the app</ytd-statement-banner-renderer><div id='ok'>content</div><video id='v'></video></body></html>"
        let web = TidyRig.web(list)
        await EnhancementRig.load(web, html, base: "https://www.youtube.com/")
        #expect(await EnhancementRig.waitFor(web, "getComputedStyle(document.getElementById('nag')).display === 'none'"), "install-app banner hidden")
        #expect(await EnhancementRig.eval(web, "getComputedStyle(document.getElementById('ok')).display") as? String == "block")
        #expect(await EnhancementRig.eval(web, "getComputedStyle(document.getElementById('v')).display") as? String != "none")
        // the sign-in host of the same company and another service: the same page is left exactly as it was
        for base in ["https://accounts.youtube.com/", "https://www.netflix.com/", "https://music.youtube.com/"] {
            let other = TidyRig.web(list)
            await EnhancementRig.load(other, html, base: base)
            try? await Task.sleep(for: .milliseconds(300))
            #expect(await EnhancementRig.eval(other, "getComputedStyle(document.getElementById('nag')).display") as? String != "none", Comment(rawValue: base))
        }
        // without the list (toggle off) the banner shows
        let plain = TidyRig.web()
        await EnhancementRig.load(plain, html, base: "https://www.youtube.com/")
        #expect(await EnhancementRig.eval(plain, "getComputedStyle(document.getElementById('nag')).display") as? String != "none")
    }

    @Test func spotifyInstallAppButtonIsHiddenByTidyAndOnlyOnOpenSpotify() async throws {
        let (rs, dir) = TidyRig.ruleStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let list = try #require(await TidyRuleList.list(for: .spotify, tidyOn: true, hidden: [], in: rs))
        let html = #"<html><body><a id="install" href="/download">Install App</a><a id="home" href="/">Home</a></body></html>"#
        let web = TidyRig.web(list)
        await EnhancementRig.load(web, html, base: "https://open.spotify.com/")
        #expect(await EnhancementRig.waitFor(web, "getComputedStyle(document.getElementById('install')).display === 'none'"))
        #expect(await EnhancementRig.eval(web, "getComputedStyle(document.getElementById('home')).display") as? String == "inline")
        let accounts = TidyRig.web(list)
        await EnhancementRig.load(accounts, html, base: "https://accounts.spotify.com/")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await EnhancementRig.eval(accounts, "getComputedStyle(document.getElementById('install')).display") as? String == "inline")
    }
}

@Suite("Hide This Element: selectors, storage and gating") @MainActor struct HiddenElementTests {
    // MARK: validation

    @Test func onlyAPlainSelectorIsAccepted() {
        for ok in ["div.install-banner", #"div[data-testid="promo-bar"]"#, "ytd-foo .bar", "section.promo > div.card", "header#top-nag", #"aside[role="complementary"]"#] {
            #expect(HiddenSelector.isValid(ok), Comment(rawValue: ok))
        }
        let bad = ["", "}{", "a}{b", "div{display:none}", "div; color:red", "div.a;", "url(x)", "div[style=url(x)]", "@import 'x'", "@media x", "div:not(.a)", "div, span", "div\\.a",
                   "div/*x*/", "body", "html", "main", "*", "div", "a", " div.a", "div.a ", "> div.a", "div.a >", "div[a=\"b]", "div[a", "javascript:x", "div.font-face-x", String(repeating: "a", count: 201)]
        for b in bad { #expect(!HiddenSelector.isValid(b), Comment(rawValue: b)) }
    }

    @Test func storedValuesAreCheckedAgainWhenRead() throws {
        let suite = UserDefaults(suiteName: "tidy-read-" + UUID().uuidString)!
        suite.set(try JSONEncoder().encode(["div.ok", "}{", "div.ok", "url(x)", "@import x", "body", "div.second"]), forKey: TidyStore.hiddenKey(.hulu))
        #expect(TidyStore(defaults: suite).hidden(.hulu) == ["div.ok", "div.second"])
        suite.set(Data("not json".utf8), forKey: TidyStore.hiddenKey(.hulu))
        #expect(TidyStore(defaults: suite).hidden(.hulu).isEmpty)
    }

    @Test func persistenceLimitDuplicatesAndPerServiceReset() {
        let suite = UserDefaults(suiteName: "tidy-persist-" + UUID().uuidString)!
        let s = TidyStore(defaults: suite)
        #expect(s.addHidden("div.one", for: .hulu) == .added && s.addHidden("div.one", for: .hulu) == .alreadyThere)
        #expect(s.addHidden("}{", for: .hulu) == .invalid && s.addHidden("div.x", for: .jiohotstar) == .unsupported)
        #expect(TidyStore(defaults: suite).hidden(.hulu) == ["div.one"], "kept across a restart")
        #expect(s.hidden(.netflix).isEmpty, "per service")
        for i in 2...50 { #expect(s.addHidden("div.item\(["a","b","c","d","e","f","g","h","i","j"][i % 10])\(["a","b","c","d","e"][i / 10 % 5])", for: .hulu) != .invalid) }
        #expect(s.hiddenCount(.hulu) <= 50)
        while s.hiddenCount(.hulu) < 50 { _ = s.addHidden("div.fill\(UUID().uuidString.prefix(6).filter(\.isLetter))", for: .hulu) }
        #expect(s.addHidden("div.overflow", for: .hulu) == .limitReached && s.hiddenCount(.hulu) == 50)
        s.addHidden("div.other", for: .netflix)
        s.setEnabled(true, for: .hulu)
        s.resetHidden(for: .hulu)
        #expect(s.hidden(.hulu).isEmpty && s.isEnabled(.hulu) && s.hidden(.netflix) == ["div.other"], "Reset removes hidden elements only, for that service only")
        s.removeHidden("div.other", for: .netflix); #expect(s.hidden(.netflix).isEmpty)
        s.setEnabled(true, for: .jiohotstar); #expect(!s.isEnabled(.jiohotstar), "no toggle for a service without page hosts")
    }

    @Test func clearingWebsiteDataIsNotWhatRemovesHiddenElements() throws {
        let src = try ServiceSources.text(["Services/Streaming/Session"])
        #expect(!src.contains("Tidy") && !src.contains("hidden("), "hidden elements are app preferences; Clear Data never touches them")
    }

    // MARK: gating

    @Test func thePickerIsOfferedOnlyOnTheServicesOwnHttpsPageWhileNothingRestrictsTheApp() {
        let sp = TidyRig.def(.spotify)
        func ok(_ u: String, _ d: ProviderDefinition = sp, restricted: Bool = false) -> Bool { ElementPicker.isAllowed(definition: d, pageURL: URL(string: u), restricted: restricted) }
        #expect(ok("https://open.spotify.com/playlist/x"))
        #expect(!ok("https://open.spotify.com/", restricted: true), "locked or kids")
        #expect(!ok("http://open.spotify.com/"))
        for u in ["https://accounts.spotify.com/login", "https://accounts.google.com/gsi/x", "https://accounts.youtube.com/", "https://evil.example/", "https://open.spotify.com.evil.example/"] { #expect(!ok(u), Comment(rawValue: u)) }
        #expect(!ElementPicker.isAllowed(definition: sp, pageURL: nil, restricted: false))
        #expect(ok("https://www.netflix.com/", TidyRig.def(.netflix)))
        #expect(!ok("https://auth.max.com/x", TidyRig.def(.hbomax)) && ok("https://www.max.com/", TidyRig.def(.hbomax)))
        #expect(!ok("https://www.hotstar.com/in", TidyRig.def(.jiohotstar)))
    }

    @Test func theRuntimeRestrictionIsTheSameOneThePageOptionsUse() {
        let r = EnhancementRuntime.shared
        #expect(r.isRestricted() == true, "restricted until the app wires it up")
        #expect(!ElementPicker.isAllowed(definition: TidyRig.def(.spotify), pageURL: URL(string: "https://open.spotify.com/"), restricted: r.isRestricted()))
    }

    // MARK: the picker on a fixture page

    private func page(_ body: String) async -> WKWebView {
        let web = TidyRig.web()
        await EnhancementRig.load(web, "<html><head><style>body{margin:0} [style*='left']{position:absolute}</style></head><body>\(body)</body></html>", base: "https://open.spotify.com/")
        return web
    }

    @Test func aStableClassIsPreferredAndTheSelectorNeverContainsText() async throws {
        let web = await page(#"<div class="install-banner" style="left:10px;top:10px;width:200px;height:40px"><span>Install the Spotify app now</span></div><div id="rest" style="left:10px;top:200px;width:50px;height:50px">x</div>"#)
        let sel = try #require(await ElementPicker.pick(at: CGPoint(x: 50, y: 25), in: web))
        #expect(sel == "div.install-banner", Comment(rawValue: sel))
        #expect(!sel.lowercased().contains("install the") && !sel.contains("app now"))
        #expect(HiddenSelector.isValid(sel))
    }

    @Test func aTestIdBeatsGeneratedClassesAndHashedClassesAreIgnored() async throws {
        let web = await page(#"<div class="css-1x2y3z Xk9Qa7" data-testid="promo-bar" style="left:0;top:0;width:300px;height:40px">promo</div>"#)
        let sel = try #require(await ElementPicker.pick(at: CGPoint(x: 20, y: 20), in: web))
        #expect(sel == #"div[data-testid="promo-bar"]"#, Comment(rawValue: sel))
        let hashed = await page(#"<div class="sc-aXyZ1 css-9f8e7d" style="left:0;top:0;width:300px;height:40px">promo</div>"#)
        #expect(await ElementPicker.pick(at: CGPoint(x: 20, y: 20), in: hashed) == nil, "nothing stable to name: refused, never guessed")
    }

    @Test func pageBodyMainTooBroadAndMediaAreRefused() async throws {
        let empty = await page("")
        #expect(await ElementPicker.pick(at: CGPoint(x: 100, y: 100), in: empty) == nil, "html/body")
        let main = await page(#"<main class="shell"><div style="left:0;top:0;width:100px;height:40px">in main</div></main>"#)
        #expect(await ElementPicker.pick(at: CGPoint(x: 20, y: 20), in: main) == nil, "main is never named")
        let big = await page(#"<div class="hero" style="left:0;top:0;width:600px;height:400px"></div>"#)
        #expect(await ElementPicker.pick(at: CGPoint(x: 100, y: 100), in: big) == nil, "covers the window")
        let rows = await page((0..<12).map { #"<div class="row" style="left:0;top:\#($0 * 30)px;width:100px;height:20px">r</div>"# }.joined())
        #expect(await ElementPicker.pick(at: CGPoint(x: 20, y: 10), in: rows) == nil, "twelve matches is not a small number")
        let player = await page(#"<div class="player-shell" style="left:0;top:0;width:300px;height:100px"><video></video></div>"#)
        #expect(await ElementPicker.pick(at: CGPoint(x: 20, y: 20), in: player) == nil, "never something that holds a video")
    }

    @Test func aContainerWithAStableNameIsFoundWhenTheClickedChildHasNone() async throws {
        let web = await page(#"<div class="top-nag" style="left:0;top:0;width:300px;height:40px"><div><p>words</p></div></div>"#)
        let sel = try #require(await ElementPicker.pick(at: CGPoint(x: 20, y: 20), in: web))
        #expect(sel == "div.top-nag" || sel.hasSuffix("p") || sel.contains("top-nag"), Comment(rawValue: sel))
        #expect(!sel.contains("words"))
    }

    @Test func hideAppliesNowKeepsOnlyTheSelectorAndUndoPutsItBack() async throws {
        let s = TidyRig.store()
        let web = await page(#"<div id="a" class="install-banner" style="left:10px;top:10px;width:200px;height:40px">Install</div><div id="b" class="keep-me" style="left:10px;top:100px;width:50px;height:30px">keep</div>"#)
        let d = TidyRig.def(.spotify)
        #expect(await ElementPicker.hide(at: CGPoint(x: 50, y: 20), in: web, definition: d, store: s, restricted: true) == .refused(.restricted))
        #expect(s.hidden(.spotify).isEmpty, "locked or kids: nothing read, nothing kept")
        let out = await ElementPicker.hide(at: CGPoint(x: 50, y: 20), in: web, definition: d, store: s, restricted: false)
        #expect(out == .hidden("div.install-banner"))
        #expect(s.hidden(.spotify) == ["div.install-banner"])
        #expect(await EnhancementRig.eval(web, "getComputedStyle(document.getElementById('a')).display") as? String == "none")
        #expect(await EnhancementRig.eval(web, "getComputedStyle(document.getElementById('b')).display") as? String == "block")
        let stored = String(describing: UserDefaults.standard.dictionaryRepresentation().keys)
        #expect(!stored.contains("Install"))
        await ElementPicker.undo("div.install-banner", in: web, definition: d, store: s)
        #expect(s.hidden(.spotify).isEmpty)
        #expect(await EnhancementRig.eval(web, "getComputedStyle(document.getElementById('a')).display") as? String == "block")
        // a click that finds nothing suitable keeps nothing
        let none = await ElementPicker.hide(at: CGPoint(x: 400, y: 300), in: web, definition: d, store: s, restricted: false)
        #expect(none == .nothingSuitable && s.hidden(.spotify).isEmpty)
    }

    @Test func aHiddenElementIsAppliedOnLaterLoadsThroughTheSameListAndMergesWithTidy() async throws {
        let (rs, dir) = TidyRig.ruleStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let list = try #require(await TidyRuleList.list(for: .spotify, tidyOn: true, hidden: ["div.install-banner"], in: rs))
        let web = TidyRig.web(list)
        await EnhancementRig.load(web, #"<html><body><div id="a" class="install-banner">x</div><a id="dl" href="/download">Install App</a><div id="k">keep</div></body></html>"#, base: "https://open.spotify.com/")
        #expect(await EnhancementRig.waitFor(web, "getComputedStyle(document.getElementById('a')).display === 'none' && getComputedStyle(document.getElementById('dl')).display === 'none'"))
        #expect(await EnhancementRig.eval(web, "getComputedStyle(document.getElementById('k')).display") as? String == "block")
    }

    @Test func scriptsStayInsideTheEnhancementsFolderAndThePickerIsNeverPersistent() throws {
        let src = try String(contentsOf: ServiceSources.root.appendingPathComponent("Services/Streaming/Enhancements/ElementPicker.swift"), encoding: .utf8)
        #expect(!src.contains("WKUserScript") && !src.contains("addUserScript") && !src.contains("WKScriptMessageHandler"), "one-off scripts only")
        let tidy = try ServiceSources.text(["Services/Streaming/Enhancements"], excluding: ["ElementPicker.swift", "EnhancementInstaller.swift", "SponsorSkipScript.swift", "SponsorBlockClient.swift", "YouTubeAdRules.swift", "SpotifyAdOptions.swift", "EnhancementStore.swift"])
        #expect(!tidy.contains("WKUserScript") && !tidy.contains("evaluateJavaScript"), "the rule list code creates no script")
    }

    // MARK: Settings

    @Test func settingsOffersTheToggleAndCountOnEveryEmbeddedServiceAndResetAsksFirst() {
        let s = TidyRig.store()
        let m = StreamingServicesSettingsModel(defaults: EnhancementRig.suite(), tidy: s)
        let embedded = m.rows.filter { $0.availability.presentation == .embedded }
        #expect(!embedded.isEmpty && embedded.allSatisfy { $0.tidy.supported && $0.tidy.on == $0.tidy.hasRules && $0.tidy.hiddenCount == 0 })
        #expect(!m.rows.contains { $0.id == .jiohotstar })
        #expect(m.rows.first { $0.id == .youtube }?.tidy.hasRules == true && m.rows.first { $0.id == .hulu }?.tidy.hasRules == false)
        EnhancementRuntime.shared.isRestricted = { false }
        defer { EnhancementRuntime.shared.isRestricted = { true } }
        m.setTidy(.hulu, on: true)
        #expect(m.rows.first { $0.id == .hulu }?.tidy.on == true && m.tidyReloadHint.contains(.hulu))
        s.addHidden("div.a-nag", for: .hulu); s.addHidden("div.b-nag", for: .hulu)
        #expect(m.rows.first { $0.id == .hulu }?.tidy.hiddenCount == 2)
        m.requestReset(.hulu); #expect(m.pendingReset == .hulu && s.hiddenCount(.hulu) == 2, "asks first, nothing removed yet")
        m.cancelReset(); #expect(s.hiddenCount(.hulu) == 2)
        m.requestReset(.hulu); m.confirmReset()
        #expect(s.hiddenCount(.hulu) == 0 && s.isEnabled(.hulu))
        m.requestReset(.hulu); #expect(m.pendingReset == nil, "nothing to reset")
        EnhancementRuntime.shared.isRestricted = { true }
        m.setTidy(.hulu, on: false); #expect(s.isEnabled(.hulu), "kids or locked cannot change it")
    }

    @Test func newWordingHasHindiAndTelugu() throws {
        let keys = ["Tidy pages", "On by default. Hides banners that ask you to install the app. Page layout can change at any time.", "Nothing to hide yet for this service. Use Hide This Element on the page.",
                    "Hidden elements: %lld", "Reset", "Reset hidden elements for %@", "Reset hidden elements?", "This shows again the elements you hid on %@. Tidy pages and your sign-in are not changed.",
                    "Right-click an element on the page and choose Hide This Element, or use Services, Hide Element on This Page… if the page has its own right-click menu. Clear Data removes website data only; elements you hid are kept until you reset them.",
                    "Click the element to hide. Esc cancels.", "Not available on sign-in pages", "Not available while locked or in a kids profile", "Hiding elements isn't available for this service", "Couldn't read this page. Try again once it has finished loading.", "Hide Element on This Page…",
                    "Hide This Element", "Element hidden.", "Nothing safe to hide there.", "Too many hidden elements for this service. Reset them in Settings.", "Undo", "Dismiss"]
        for code in ["hi", "te"] {
            let url = ServiceSources.root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Localization/\(code).lproj/Localizable.strings")
            let table = try #require(NSDictionary(contentsOf: url) as? [String: String])
            for k in keys { #expect((table[k] ?? "").isEmpty == false, Comment(rawValue: "\(code): \(k.prefix(50))")) }
        }
    }
}
