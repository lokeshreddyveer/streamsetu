import WebKit
import AppKit

/// What the person can do from the context menu of the page (set by the model). The browser action is nil for a service that never leaves the app.
struct ServiceMenuActions {
    var canGoBack: Bool, canGoForward: Bool
    var back: () -> Void, forward: () -> Void, reload: () -> Void
    var openInBrowser: (() -> Void)?
}

/// The one web view of a service destination. It adds Back, Forward and Reload (and Open in Default Browser where the service allows it) to the
/// page's own context menu and removes the items that would download a file or open a new window.
final class ServiceWebView: WKWebView {
    var menuActions: (() -> ServiceMenuActions)?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        for item in menu.items {
            let id = item.identifier?.rawValue ?? ""
            if id.contains("Download") || id.contains("NewWindow") || id.contains("OpenLinkInNewWindow") || id.contains("OpenImageInNewWindow") { menu.removeItem(item) }
        }
        guard let a = menuActions?() else { return }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        func add(_ title: String, _ enabled: Bool, _ run: @escaping () -> Void) {
            let item = ClosureMenuItem(title: Localized.string(title), run: run); item.isEnabled = enabled; menu.addItem(item)
        }
        add("Back", a.canGoBack, a.back); add("Forward", a.canGoForward, a.forward); add("Reload", true, a.reload)
        if let open = a.openInBrowser { add("Open in Default Browser", true, open) }
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

/// Makes the web views. One recipe for every service: plain WebKit, no user scripts, no message handlers (so no bridge to the app), no
/// application or agent string, and the page is never read. Only a service the registry presents as embedded gets a web view.
@MainActor struct ServiceWebViewFactory {
    static func makeConfiguration(dataStore: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = dataStore
        c.preferences.isElementFullscreenEnabled = true               // the site's own full-screen button
        c.preferences.javaScriptCanOpenWindowsAutomatically = false
        c.preferences.isFraudulentWebsiteWarningEnabled = true
        c.defaultWebpagePreferences.allowsContentJavaScript = true
        if #available(macOS 14.5, *) { c.upgradeKnownHostsToHTTPS = true }
        return c
    }

    func makeWebView(definition: ProviderDefinition, dataStore: WKWebsiteDataStore, zoom: Double) -> ServiceWebView {
        assert(definition.presentation == .embedded, "only an embedded service gets a web view")
        let v = ServiceWebView(frame: .zero, configuration: Self.makeConfiguration(dataStore: dataStore))
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
