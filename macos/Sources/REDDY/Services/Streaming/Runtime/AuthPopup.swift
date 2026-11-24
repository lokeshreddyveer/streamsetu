import WebKit
import AppKit

/// The window a "Sign in with Google" button opens, shown as a small sheet over the service. Made only when the page asks for an address on one of
/// Google's sign-in hosts (see `ProviderURLPolicy.isGoogleSignInHost`); every other new window is refused as before. It is built from the
/// configuration WebKit hands over (same website data store and web process group, so the result of signing in reaches the page that opened it),
/// but with an EMPTY content controller: no page option script and no content rule list ever runs here. Its address policy is the service's own:
/// only the service's hosts and Google's sign-in hosts load, over https, and nothing leaves the app. It closes when the page calls window.close()
/// and when the person dismisses it. It never opens another window.
@MainActor final class AuthPopup: NSObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    let id = UUID()
    let webView: WKWebView
    private let definition: ProviderDefinition
    private var closeHandlers: [() -> Void] = []
    private(set) var isClosed = false

    init(configuration: WKWebViewConfiguration, definition: ProviderDefinition) {
        configuration.userContentController = WKUserContentController()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        self.definition = definition
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func onClose(_ handler: @escaping () -> Void) { closeHandlers.append(handler) }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        webView.stopLoading()
        webView.navigationDelegate = nil; webView.uiDelegate = nil
        let handlers = closeHandlers; closeHandlers = []
        handlers.forEach { $0() }
    }

    // MARK: navigation (the service's own policy, nothing opens outside the app)

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.shouldPerformDownload { return .cancel }
        let isMain = navigationAction.targetFrame?.isMainFrame ?? true
        return definition.urlPolicy.decide(navigationAction.request.url, isMainFrame: isMain, isRedirect: false) == .allowInApp ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let http = navigationResponse.response as? HTTPURLResponse
        let disposition = http?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        if disposition.hasPrefix("attachment") || !navigationResponse.canShowMIMEType { return .cancel }
        if navigationResponse.isForMainFrame, definition.urlPolicy.decide(navigationResponse.response.url, isMainFrame: true, isRedirect: true) != .allowInApp { return .cancel }
        return .allow
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? (.performDefaultHandling, nil) : (.cancelAuthenticationChallenge, nil)
    }

    // MARK: windows and permissions

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webViewDidClose(_ webView: WKWebView) { close() }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision { .deny }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? { nil }
}
