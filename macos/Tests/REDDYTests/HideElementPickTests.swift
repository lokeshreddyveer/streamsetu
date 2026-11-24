import Testing
import WebKit
import AppKit
@testable import REDDY

/// Hide Element's second route (pick mode) and its failure paths. Fixture pages only, loaded from strings under a service's own host name; nothing real.
@MainActor private enum PickRig {
    static func store() -> TidyStore { TidyStore(defaults: UserDefaults(suiteName: "pick-test-" + UUID().uuidString)!) }
    static func def(_ id: ProviderID) -> ProviderDefinition { ProviderCatalog.all.first { $0.id == id }! }
    static func web(zoom: CGFloat = 1) -> WKWebView {
        let cfg = WKWebViewConfiguration(); cfg.websiteDataStore = .nonPersistent()
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: cfg)
        w.pageZoom = zoom
        return w
    }
    static func page(_ body: String, head: String = "", base: String = "https://open.spotify.com/", zoom: CGFloat = 1) async -> WKWebView {
        let w = web(zoom: zoom)
        await EnhancementRig.load(w, "<html><head>\(head)<style>body{margin:0} [style*='left']{position:absolute}</style></head><body>\(body)</body></html>", base: base)
        return w
    }
    static func eval(_ w: WKWebView, _ js: String) async -> Any? { try? await w.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page) }
    /// What the person would do: move over the element, then click it. Dispatched on the element under the point, like a real event.
    static func moveAndClick(_ w: WKWebView, x: Double, y: Double) async {
        _ = await eval(w, "var t = document.elementFromPoint(\(x), \(y)) || document.body; var o = {bubbles:true,cancelable:true,clientX:\(x),clientY:\(y),composed:true}; t.dispatchEvent(new MouseEvent('mousemove', o)); return true;")
        try? await Task.sleep(for: .milliseconds(120))
        _ = await eval(w, "var t = document.elementFromPoint(\(x), \(y)) || document.body; var o = {bubbles:true,cancelable:true,clientX:\(x),clientY:\(y),composed:true}; ['mousedown','mouseup','click'].forEach(function(n){ t.dispatchEvent(new MouseEvent(n, o)); }); return true;")
    }
    static func start(_ w: WKWebView, _ s: TidyStore, id: ProviderID = .spotify, restricted: Bool = false) -> Task<ElementPicker.Outcome, Never> {
        Task { @MainActor in await ElementPicker.pickInteractively(in: w, definition: def(id), store: s, hint: "Click the element to hide. Esc cancels.", restricted: restricted) }
    }
    static let banner = #"<div id="a" class="install-banner" style="left:10px;top:10px;width:200px;height:40px">Install</div><div id="b" class="keep-me" style="left:10px;top:100px;width:200px;height:40px">Keep</div>"#
}

@Suite("Hide Element: pick mode", .serialized) @MainActor struct HideElementPickTests {
    @Test func pickModeWorksOnAPageThatCancelsItsOwnContextMenuAndNeverLeaksEventsToIt() async throws {
        let head = "<script>document.addEventListener('contextmenu', function(e){ e.preventDefault(); e.stopPropagation(); }, true); window.__leaks = 0;</script>"
        let w = await PickRig.page(PickRig.banner + "<script>['click','mousedown','mouseup','mousemove'].forEach(function(n){ document.getElementById('a').addEventListener(n, function(){ window.__leaks++; }); });</script>", head: head)
        let s = PickRig.store()
        let before = await PickRig.eval(w, "return document.documentElement.childElementCount;") as? Int
        let task = PickRig.start(w, s)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await PickRig.eval(w, "return typeof window.__ssPick;") as? String == "function", "pick mode is up")
        await PickRig.moveAndClick(w, x: 50, y: 25)
        let out = await task.value
        #expect(out == .hidden("div.install-banner"), Comment(rawValue: "\(out)"))
        #expect(await PickRig.eval(w, "return getComputedStyle(document.getElementById('a')).display;") as? String == "none")
        #expect(await PickRig.eval(w, "return getComputedStyle(document.getElementById('b')).display;") as? String == "block", "only the chosen element")
        #expect(await PickRig.eval(w, "return window.__leaks;") as? Int == 0, "the page never saw the pointer events")
        #expect(await PickRig.eval(w, "return document.documentElement.childElementCount;") as? Int == before, "the overlay removed itself")
        #expect(await PickRig.eval(w, "return window.__ssPick === null || window.__ssPick === undefined;") as? Bool == true)
        #expect(s.hidden(.spotify) == ["div.install-banner"])
    }

    @Test func aStrictContentSecurityPolicyAndTrustedTypesDoNotStopIt() async throws {
        let head = #"<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; require-trusted-types-for 'script'">"#
        let w = await PickRig.page(PickRig.banner, head: head)
        let s = PickRig.store()
        let task = PickRig.start(w, s)
        try await Task.sleep(for: .milliseconds(300))
        await PickRig.moveAndClick(w, x: 50, y: 25)
        #expect(await task.value == .hidden("div.install-banner"))
        #expect(await PickRig.eval(w, "return getComputedStyle(document.getElementById('a')).display;") as? String == "none")
    }

    @Test func escapeCancelsKeepsNothingAndRemovesTheOverlay() async throws {
        let w = await PickRig.page(PickRig.banner)
        let s = PickRig.store()
        let task = PickRig.start(w, s)
        try await Task.sleep(for: .milliseconds(300))
        _ = await PickRig.eval(w, "window.dispatchEvent(new KeyboardEvent('keydown', {key:'Escape', bubbles:true, cancelable:true})); return true;")
        #expect(await task.value == .cancelled)
        #expect(s.hidden(.spotify).isEmpty)
        #expect(await PickRig.eval(w, "return getComputedStyle(document.getElementById('a')).display;") as? String == "block")
    }

    @Test func theAppCanCancelPickModeToo() async throws {
        let w = await PickRig.page(PickRig.banner)
        let task = PickRig.start(w, PickRig.store())
        try await Task.sleep(for: .milliseconds(300))
        await ElementPicker.cancelPickMode(in: w)
        #expect(await task.value == .cancelled)
    }

    @Test func clickingSomethingUnsafeSaysNothingSuitableAndKeepsNothing() async throws {
        let w = await PickRig.page(#"<div style="left:0;top:0;width:100px;height:40px">plain</div>"#)
        let s = PickRig.store()
        let task = PickRig.start(w, s)
        try await Task.sleep(for: .milliseconds(300))
        await PickRig.moveAndClick(w, x: 20, y: 20)
        #expect(await task.value == .nothingSuitable)
        #expect(s.hidden(.spotify).isEmpty)
    }

    @Test func signInPagesLockedAndKidsAreRefusedWithAReasonAndNothingIsInjected() async throws {
        let s = PickRig.store()
        let signIn = await PickRig.page(PickRig.banner, base: "https://accounts.spotify.com/")
        #expect(await PickRig.start(signIn, s).value == .refused(.signInPage))
        let google = await PickRig.page(PickRig.banner, base: "https://accounts.google.com/")
        #expect(await PickRig.start(google, s).value == .refused(.signInPage))
        let normal = await PickRig.page(PickRig.banner)
        #expect(await PickRig.start(normal, s, restricted: true).value == .refused(.restricted))
        #expect(await PickRig.eval(normal, "return typeof window.__ssPick;") as? String == "undefined", "no script ran")
        #expect(await PickRig.start(normal, s, id: .jiohotstar).value == .refused(.unsupported))
        #expect(ElementPicker.Refusal.signInPage.notice == "Not available on sign-in pages")
        #expect(ElementPicker.Refusal.restricted.notice == "Not available while locked or in a kids profile")
        #expect(s.hidden(.spotify).isEmpty)
    }

    @Test func theLimitOfFiftyStillApplies() async throws {
        let s = PickRig.store()
        for i in 0..<HiddenSelector.maxPerService { s.addHidden("div.nag-\(String(UnicodeScalar(UInt8(97 + i % 26))))\(String(UnicodeScalar(UInt8(97 + i / 26))))", for: .spotify) }
        #expect(s.hiddenCount(.spotify) == HiddenSelector.maxPerService)
        let w = await PickRig.page(PickRig.banner)
        #expect(await PickRig.start(w, s).value == .limitReached)
    }

    @Test func aZoomedPageAndAnOffsetLayoutHideTheElementThatWasClicked() async throws {
        // the view point to CSS point conversion, flipped or not
        let p = ServiceWebView.cssPoint(local: CGPoint(x: 150, y: 75), boundsHeight: 400, isFlipped: true, pageZoom: 1.5)
        #expect(p == CGPoint(x: 100, y: 50))
        let q = ServiceWebView.cssPoint(local: CGPoint(x: 150, y: 325), boundsHeight: 400, isFlipped: false, pageZoom: 1.5)
        #expect(q == CGPoint(x: 100, y: 50))
        let body = #"<div id="a" class="top-nag" style="left:60px;top:20px;width:120px;height:60px">A</div><div id="b" class="side-nag" style="left:60px;top:90px;width:120px;height:60px">B</div>"#
        let w = await PickRig.page(body, zoom: 1.5)
        let s = PickRig.store()
        // a click at view (150, 75) is CSS (100, 50): inside A, not B
        let out = await ElementPicker.hide(at: p, in: w, definition: PickRig.def(.spotify), store: s, restricted: false)
        #expect(out == .hidden("div.top-nag"))
        #expect(await PickRig.eval(w, "return getComputedStyle(document.getElementById('b')).display;") as? String == "block")
        // the wrong conversion (no zoom) would have landed on empty page: nothing suitable
        let wrong = await ElementPicker.hide(at: CGPoint(x: 150, y: 75), in: w, definition: PickRig.def(.spotify), store: PickRig.store(), restricted: false)
        #expect(wrong != .hidden("div.top-nag"))
    }

    @Test func generatedClassNamesFallBackToStableDataAttributes() async throws {
        let w = await PickRig.page(#"<div class="css-1x2y3z" data-promo="install-bar" style="left:0;top:0;width:200px;height:40px">x</div>"#)
        let sel = try #require(await ElementPicker.pick(at: CGPoint(x: 20, y: 20), in: w))
        #expect(sel == #"div[data-promo="install-bar"]"#, Comment(rawValue: sel))
        #expect(HiddenSelector.isValid(sel))
    }

    @Test func diagnosticsKeepOnlyTheHostAndAReasonCode() {
        let d = ServiceDiagnostics()
        d.recordPicker(.spotify, url: URL(string: "https://open.spotify.com/search?q=secret#frag"), event: .refused(.signInPage))
        d.recordPicker(.spotify, url: URL(string: "https://open.spotify.com/x"), event: .scriptFailed)
        let e = d.entries(for: .spotify)
        #expect(e.map(\.host) == ["open.spotify.com", "open.spotify.com"])
        #expect(e.map(\.kind) == [.picker(.refused(.signInPage)), .picker(.scriptFailed)])
        #expect(ServiceDiagnostics.PickerEvent.refused(.restricted).code == "refused-restricted" && ServiceDiagnostics.PickerEvent.scriptFailed.code == "script-failed")
        #expect(!d.hostList(for: .spotify).contains("secret"))
    }

    @Test func theOverlayDrawsOnlyFromTheThemeTokens() {
        let css = ElementPicker.themeCSS()
        #expect(Set(css.keys) == ["accent", "accentFill", "panel", "text", "line"])
        #expect(css.values.allSatisfy { $0.hasPrefix("rgba(") })
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/REDDY/Services/Streaming/Enhancements/ElementPicker.swift")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        #expect(!text.contains("#fff") && !text.contains("#000") && !text.contains("'white'") && !text.contains("'black'") && !text.contains("color:white") && !text.contains("color:black"), "no literal colours in the pick overlay script")
    }
}
