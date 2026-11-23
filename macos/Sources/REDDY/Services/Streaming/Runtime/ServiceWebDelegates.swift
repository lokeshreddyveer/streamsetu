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
    func cookiesChanged()
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

    init(events: ServiceWebEvents) { self.events = events; definition = events.definition }

    private func decide(_ url: URL?, isMainFrame: Bool, isRedirect: Bool = false) -> ProviderURLPolicy.Decision {
        let d = AdapterRegistry.decide(definition, url, isMainFrame: isMainFrame, context: NavigationContext(fromHost: nil, userInitiated: false, isRedirect: isRedirect))
        #if DEBUG
        DebugHostLog.record(service: definition.id, url: url, decision: d, isMainFrame: isMainFrame)
        #endif
        return d
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
        switch decide(url, isMainFrame: isMain, isRedirect: isRedirect) {
        case .allowInApp:
            if isMain, let url, url.scheme != "about" { events?.addressAllowed(url) }
            return .allow
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
            if decide(navigationResponse.response.url, isMainFrame: true, isRedirect: true) != .allowInApp { return .cancel }
            events?.mainResponse(statusCode: http?.statusCode)
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { alertCount = 0; navigating = true; events?.loadStarted() }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { navigating = false; events?.loadCommitted(webView.url) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { navigating = false; events?.loadFinished() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigating = false; events?.loadFailed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigating = false; events?.loadFailed(error) }

    /// The server's certificate is judged by the system; nothing here overrides it and no credentials are ever supplied.
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? (.performDefaultHandling, nil) : (.cancelAuthenticationChallenge, nil)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { navigating = false; events?.processTerminated() }

    // MARK: windows, permissions, panels

    /// A new window never opens. An address on the site loads in this view; any other is handled like an off-site link.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let url = navigationAction.request.url
        switch decide(url, isMainFrame: true) {
        case .allowInApp: if let url, url.scheme != "about" { events?.openInPlace(url) }
        case .openExternally: if let url { events?.addressOffSite(url) }
        case .block: break
        }
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
