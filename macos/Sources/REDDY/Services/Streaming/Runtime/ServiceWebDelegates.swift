import WebKit
import AppKit

/// What the delegates tell the model. Every address decision is made here from the definition (and its adapter, if any); the model only reacts.
@MainActor protocol ServiceWebEvents: AnyObject {
    var definition: ProviderDefinition { get }
    func addressAllowed(_ url: URL)
    func addressOffSite(_ url: URL)
    func downloadBlocked()
    func openInPlace(_ url: URL)
    func mainResponse(statusCode: Int?)
    func loadStarted()
    func loadCommitted(_ url: URL?)
    func loadFinished()
    func loadFailed(_ error: Error)
    func processTerminated()
    /// The provider's own server redirected the load to one of its regional pages (an exact host the definition names). The load was cancelled.
    func regionRestricted(host: String, label: String?)
    func cookiesChanged()
    /// A sign-in window (Google's) was opened by the page; show it over the service.
    func presentAuthPopup(_ popup: AuthPopup)
}

/// Navigation, window, permission and panel delegates of a service's web view, in one object that is held by the web view's lifecycle (WebKit
/// holds delegates weakly) and talks back through `ServiceWebEvents`.
@MainActor final class ServiceWebDelegates: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
    /// At most this many JavaScript alerts per page load; the rest are ignored.
    static let alertsPerLoad = 3

    private weak var events: ServiceWebEvents?
    private let definition: ProviderDefinition
    private var alertCount = 0
    /// A main-frame navigation has started and not yet committed: another main-frame request in that time is a redirect.
    private var navigating = false
    /// The host the in-flight main-frame load began on (set when that first request was allowed; cleared when the load commits, finishes or fails).
    private var loadOriginHost: String?
    /// Host-only hops of the in-flight load, in order, each host once in a row (a same-host redirect adds no hop).
    private var chainHosts: [String] = []
    /// How many times WebKit reported a server redirect that this app had allowed to continue. The callback carries no address and is never
    /// called for a redirect the app cancelled, so this is a count only.
    private(set) var confirmedServerRedirects = 0

    private let diagnostics: ServiceDiagnostics

    init(events: ServiceWebEvents, diagnostics: ServiceDiagnostics = .shared) { self.events = events; definition = events.definition; self.diagnostics = diagnostics }

    private func decide(_ url: URL?, isMainFrame: Bool, isRedirect: Bool = false, record: Bool = true, originHost: String? = nil) -> ProviderURLPolicy.Decision {
        let d = AdapterRegistry.decide(definition, url, isMainFrame: isMainFrame, context: NavigationContext(fromHost: originHost, userInitiated: false, isRedirect: isRedirect))
        #if DEBUG
        DebugHostLog.record(service: definition.id, url: url, decision: d, isMainFrame: isMainFrame)
        #endif
        if record && d != .allowInApp && !d.isProviderRegionRestriction {
            if isMainFrame { diagnostics.recordBlocked(definition.id, url: url) } else { diagnostics.recordSubframeBlocked(definition.id, url: url) }
        }
        return d
    }

    // MARK: redirect chain (host only)

    private func endChain() { loadOriginHost = nil; chainHosts = [] }

    /// Starts a chain on a new main-frame load and appends a host when a redirect arrives at a new host. The first redirect to another host
    /// records both the origin (index 0) and the target (index 1); only a host name and its order index are kept.
    private func noteHop(_ url: URL?, isRedirect: Bool) {
        guard let scheme = url?.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = ServiceDiagnostics.host(of: url) else { return }
        if !isRedirect || chainHosts.isEmpty { chainHosts = [host]; return }
        guard host != chainHosts.last else { return }
        if chainHosts.count == 1 { diagnostics.recordRedirectHop(definition.id, host: chainHosts[0], index: 0) }
        chainHosts.append(host)
        diagnostics.recordRedirectHop(definition.id, host: host, index: chainHosts.count - 1)
    }

    // MARK: navigation

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.shouldPerformDownload { events?.downloadBlocked(); return .cancel }
        let url = navigationAction.request.url
        let isMain = navigationAction.targetFrame?.isMainFrame ?? true
        // Known limit: WebKit documents no public flag for "this request is a server redirect" (the callback for it comes after this decision).
        // The best public signal is a main-frame request that arrives while a main-frame load is still in progress and that no link, form or
        // reload caused (`.other`). A script that navigates in that same window of time looks the same; it can only ever reach the extra
        // hosts of a redirect-only rule (the service's own short-link or old-brand hosts), never any other site, and the response is checked again.
        let isRedirect = isMain && navigating && navigationAction.navigationType == .other
        // What the public API can say about a redirect chain (host only, in memory): every main-frame request this callback sees, in order. A
        // redirect target is seen here BEFORE it is requested (so a cancelled hop is never fetched), but its HTTP status (301/302) is not exposed.
        if isMain { noteHop(url, isRedirect: isRedirect) }
        let origin = isRedirect ? loadOriginHost : nil
        switch decide(url, isMainFrame: isMain, isRedirect: isRedirect, originHost: origin) {
        case .allowInApp:
            if isMain, let url, url.scheme != "about" { events?.addressAllowed(url); if !isRedirect { loadOriginHost = ServiceDiagnostics.host(of: url) } }
            return .allow
        case .providerRegionRestriction(let host, let label):
            // The provider's own server sent this connection to its regional page. That host is NOT loaded (policy unchanged); the person is told the truth.
            diagnostics.recordRegionalPage(definition.id, host: host)
            events?.regionRestricted(host: host, label: label)
            return .cancel
        case .openExternally:
            if let url { events?.addressOffSite(url) }          // never opened here: the model asks first, or says it was blocked
            return .cancel
        case .block:
            return .cancel
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let http = navigationResponse.response as? HTTPURLResponse
        let disposition = http?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        if disposition.hasPrefix("attachment") || !navigationResponse.canShowMIMEType { events?.downloadBlocked(); return .cancel }
        if navigationResponse.isForMainFrame {
            switch decide(navigationResponse.response.url, isMainFrame: true, isRedirect: true, originHost: loadOriginHost) {
            case .allowInApp: break
            case .providerRegionRestriction(let host, let label): events?.regionRestricted(host: host, label: label); return .cancel
            default: return .cancel
            }
            diagnostics.recordHTTPStatus(definition.id, url: navigationResponse.response.url, status: http?.statusCode)
            events?.mainResponse(statusCode: http?.statusCode)
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { alertCount = 0; navigating = true; events?.loadStarted() }
    /// Public API: called when the server redirected the provisional load and the app's policy allowed the target to continue. No address is given.
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) { confirmedServerRedirects += 1 }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { navigating = false; endChain(); events?.loadCommitted(webView.url) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { navigating = false; endChain(); events?.loadFinished() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigating = false; endChain(); diagnostics.recordFailure(definition.id, error: error, fallbackURL: webView.url); events?.loadFailed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigating = false; endChain(); diagnostics.recordFailure(definition.id, error: error, fallbackURL: webView.url); events?.loadFailed(error) }

    /// The server's certificate is judged by the system; nothing here overrides it and no credentials are ever supplied.
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? (.performDefaultHandling, nil) : (.cancelAuthenticationChallenge, nil)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { navigating = false; endChain(); diagnostics.recordProcessTerminated(definition.id, url: webView.url); events?.processTerminated() }

    // MARK: windows, permissions, panels

    /// A new window never opens, except a sign-in window on Google's sign-in hosts (above). An address on the site loads in this view; any other is handled like an off-site link.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let url = navigationAction.request.url
        let d = decide(url, isMainFrame: true, record: false)
        // Only a sign-in window for one of Google's exact sign-in hosts, over https, becomes a real window; every other request is handled as before.
        if d == .allowInApp, let url, url.scheme?.lowercased() == "https", definition.urlPolicy.isGoogleSignInHost(url.host), let events {
            let popup = AuthPopup(configuration: configuration, definition: definition)
            let id = definition.id, diagnostics = diagnostics
            diagnostics.recordAuthPopup(id, url: url, opened: true)
            popup.onClose { diagnostics.recordAuthPopup(id, url: url, opened: false) }
            events.presentAuthPopup(popup)
            return popup.webView
        }
        switch d {
        case .allowInApp: if let url, url.scheme != "about" { events?.openInPlace(url) }
        case .openExternally: if let url { events?.addressOffSite(url) }
        case .block, .providerRegionRestriction: break
        }
        if d != .allowInApp { diagnostics.recordPopupRefused(definition.id, url: url) }
        return nil
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision { .deny }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? { nil }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        alertCount += 1
        guard alertCount <= Self.alertsPerLoad else { return }
        let a = NSAlert(); a.messageText = frame.request.url?.host ?? definition.displayName; a.informativeText = message; a.addButton(withTitle: Localized.string("OK")); a.runModal()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        alertCount += 1
        guard alertCount <= Self.alertsPerLoad else { return false }
        let a = NSAlert(); a.messageText = frame.request.url?.host ?? definition.displayName; a.informativeText = message
        a.addButton(withTitle: Localized.string("OK")); a.addButton(withTitle: Localized.string("Cancel"))
        return a.runModal() == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? { nil }

    // MARK: cookies

    /// Only a signal to look again at whether a session exists; the page-finished refresh covers the case where WebKit does not call.
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in self.events?.cookiesChanged() }
    }
}

extension ProviderURLPolicy.Decision {
    var isProviderRegionRestriction: Bool { if case .providerRegionRestriction = self { true } else { false } }
}
