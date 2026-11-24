import WebKit
import AppKit

/// What the person can do from the context menu of the page (set by the model). The browser action is nil for a service that never leaves the app.
struct ServiceMenuActions {
    var canGoBack: Bool, canGoForward: Bool
    var back: () -> Void, forward: () -> Void, reload: () -> Void
    var openInBrowser: (() -> Void)?
    /// "Hide This Element": nil where the picker is not offered (a sign-in or account page, locked, kids profile). Gets the click point in CSS pixels.
    var hideElement: ((CGPoint) -> Void)?
}

/// The one web view of a service destination. It adds Back, Forward and Reload (and Open in Default Browser where the service allows it) to the
/// page's own context menu and removes the items that would download a file or open a new window.
final class ServiceWebView: WKWebView {
    var menuActions: (() -> ServiceMenuActions)?

    /// A point in the view (AppKit coordinates) as CSS pixels from the page's top-left: flipped when the view is not, divided by the page zoom.
    static func cssPoint(local: CGPoint, boundsHeight: CGFloat, isFlipped: Bool, pageZoom: CGFloat) -> CGPoint {
        let zoom = max(pageZoom, 0.1)
        return CGPoint(x: local.x / zoom, y: (isFlipped ? local.y : boundsHeight - local.y) / zoom)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        for item in menu.items {
            let id = item.identifier?.rawValue ?? ""
            if id.contains("Download") || id.contains("NewWindow") || id.contains("OpenLinkInNewWindow") || id.contains("OpenImageInNewWindow") { menu.removeItem(item) }
        }
        guard let a = menuActions?() else { return }
        let cssPoint = Self.cssPoint(local: convert(event.locationInWindow, from: nil), boundsHeight: bounds.height, isFlipped: isFlipped, pageZoom: pageZoom)
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        func add(_ title: String, _ enabled: Bool, _ run: @escaping () -> Void) {
            let item = ClosureMenuItem(title: Localized.string(title), run: run); item.isEnabled = enabled; menu.addItem(item)
        }
        add("Back", a.canGoBack, a.back); add("Forward", a.canGoForward, a.forward); add("Reload", true, a.reload)
        if let open = a.openInBrowser { add("Open in Default Browser", true, open) }
        if let hide = a.hideElement { add("Hide This Element", true) { hide(cssPoint) } }
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

/// The application-name part that makes WebKit's own default user agent read as Safari
/// ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/<N> Safari/605.1.15"). Only this part is set;
/// the rest of the string is WebKit's. The version comes from the Safari installed on this Mac, read once.
enum SafariUserAgent {
    /// Newest Safari known when written (a public format reference: Safari 26 sends "Version/26.x Safari/605.1.15"); used only if the installed one cannot be read.
    static let fallbackVersion = "27.2"
    static let suffix = "Safari/605.1.15"

    /// Pure: a Safari version string in, the application name out. A value that is not a plain dotted number falls back.
    static func applicationName(forSafariVersion v: String?) -> String {
        let t = (v ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = !t.isEmpty && t.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
        let parts = t.split(separator: ".").prefix(2).joined(separator: ".")
        return "Version/\(ok ? parts : fallbackVersion) \(suffix)"
    }

    static func installedVersion(paths: [String] = ["/System/Cryptexes/App/System/Applications/Safari.app", "/Applications/Safari.app"]) -> String? {
        for p in paths { if let v = Bundle(path: p)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String { return v } }
        return nil
    }

    /// Computed once.
    static let applicationName: String = applicationName(forSafariVersion: installedVersion())
}

/// Makes the web views. One recipe for every service: plain WebKit, no page code and no message handlers (so no bridge to the app) unless the definition declares an optional enhancement that the person turned on and agreed to (see EnhancementInstaller; the only place that adds any), the
/// application name follows the provider's userAgentProfile, and the page is never read. Only a service the registry presents as embedded gets a web view.
@MainActor struct ServiceWebViewFactory {
    static func makeConfiguration(dataStore: WKWebsiteDataStore, userAgent: UserAgentProfile = .safari) -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        if userAgent == .safari { c.applicationNameForUserAgent = SafariUserAgent.applicationName }
        c.websiteDataStore = dataStore
        c.preferences.isElementFullscreenEnabled = true               // the site's own full-screen button
        c.preferences.javaScriptCanOpenWindowsAutomatically = false
        c.preferences.isFraudulentWebsiteWarningEnabled = true
        c.defaultWebpagePreferences.allowsContentJavaScript = true
        if #available(macOS 14.5, *) { c.upgradeKnownHostsToHTTPS = true }
        return c
    }

    /// `enhancements` adds the page additions a person turned on (YouTube only); nil or nothing wanted leaves the plain recipe untouched.
    func makeWebView(definition: ProviderDefinition, dataStore: WKWebsiteDataStore, zoom: Double, enhancements: EnhancementInstaller? = nil) -> ServiceWebView {
        assert(definition.presentation == .embedded, "only an embedded service gets a web view")
        let v = ServiceWebView(frame: .zero, configuration: Self.makeConfiguration(dataStore: dataStore, userAgent: definition.userAgentProfile))
        enhancements?.apply(to: v.configuration.userContentController)
        v.allowsBackForwardNavigationGestures = true
        v.allowsMagnification = false          // no pinch zoom; the size is the page zoom
        v.pageZoom = CGFloat(zoom)
        v.underPageBackgroundColor = NSColor(white: 0.07, alpha: 1)       // no white flash while the page loads
        v.setAccessibilityLabel(definition.displayName)
        #if DEBUG
        v.isInspectable = true
        #endif
        return v
    }
}
