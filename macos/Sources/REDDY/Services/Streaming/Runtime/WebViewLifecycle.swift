import WebKit
import AppKit

/// Owns the single web view of one service: makes it, watches it, pauses its media and takes it down. Knows nothing about addresses or policy,
/// and never touches the website data (releasing a web view keeps the sign-in).
@MainActor final class WebViewLifecycle {
    let definition: ProviderDefinition
    private let dataStore: () -> WKWebsiteDataStore
    private let factory: ServiceWebViewFactory
    private(set) var webView: ServiceWebView?
    private var observers: [NSKeyValueObservation] = []
    private var pressureSource: DispatchSourceMemoryPressure?
    private weak var cookieObserver: ServiceWebDelegates?
    private var delegates: ServiceWebDelegates?
    /// Adds the optional page additions a person turned on; does nothing for a service that declares none.
    private(set) lazy var enhancements = EnhancementInstaller(definition: definition)

    /// canGoBack, canGoForward or the full-screen state changed.
    var onNavigationChange: (() -> Void)?
    /// Memory is tight; `critical` is true for the system's critical level.
    var onMemoryPressure: ((_ critical: Bool) -> Void)?
    /// Playback of this view is suspended (set while the service is hidden; cleared when it shows again). Lives and dies with the web view.
    private(set) var isMediaSuspended = false

    init(definition: ProviderDefinition, dataStore: @escaping () -> WKWebsiteDataStore, factory: ServiceWebViewFactory = ServiceWebViewFactory()) {
        self.definition = definition; self.dataStore = dataStore; self.factory = factory
    }

    /// The view: created on first use and kept, so switching away and back does not reload the page. Returns whether it is new.
    @discardableResult func ensureWebView(delegates: ServiceWebDelegates, zoom: Double, menuActions: @escaping () -> ServiceMenuActions) -> (view: ServiceWebView, isNew: Bool) {
        if let webView { return (webView, false) }
        let store = dataStore()
        let v = factory.makeWebView(definition: definition, dataStore: store, zoom: zoom, enhancements: definition.pageEnhancements.isEmpty ? nil : enhancements)
        v.navigationDelegate = delegates; v.uiDelegate = delegates; v.menuActions = menuActions
        self.delegates = delegates
        observers = [
            v.observe(\.canGoBack) { [weak self] _, _ in MainActor.assumeIsolated { self?.onNavigationChange?() } },
            v.observe(\.canGoForward) { [weak self] _, _ in MainActor.assumeIsolated { self?.onNavigationChange?() } },
            // the site's own full-screen player is shown at full size: the page zoom steps aside while it is up
            v.observe(\.fullscreenState) { [weak self] _, _ in MainActor.assumeIsolated { self?.onNavigationChange?() } },
        ]
        store.httpCookieStore.add(delegates); cookieObserver = delegates
        startMemoryWatch()
        webView = v
        return (v, true)
    }


    /// What a change of the person's choices needs: the page additions on this view differ from what is wanted now.
    var enhancementsStale: Bool { webView != nil && !definition.pageEnhancements.isEmpty && enhancements.installed != enhancements.wanted }

    /// Brings the page additions in line with the choices (they take effect with the next load).
    func refreshEnhancements() {
        guard let v = webView, !definition.pageEnhancements.isEmpty else { return }
        enhancements.apply(to: v.configuration.userContentController)
    }

    private func startMemoryWatch() {
        guard pressureSource == nil else { return }
        let s = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        s.setEventHandler { [weak self, weak s] in
            let critical = s?.data.contains(.critical) ?? false
            MainActor.assumeIsolated { self?.onMemoryPressure?(critical) }
        }
        s.resume(); pressureSource = s
    }

    /// Stops sound and closes any full-screen or picture-in-picture video (the supported calls; never resumed by the app).
    func pauseMediaNow() {
        guard let v = webView else { return }
        v.pauseAllMediaPlayback()
        v.closeAllMediaPresentations()
    }

    /// For a hidden service: pause, close presentations, then suspend playback. A pause alone is one-off, so a page's own script (autoplay of
    /// the next title, an ad, a retried play) could start sound again while the retained view is out of sight; suspension is the supported
    /// public setting that keeps the page from playing until it is lifted. The three calls reach the web process in this order.
    func suspendMedia() {
        guard let v = webView else { return }
        v.pauseAllMediaPlayback()
        v.closeAllMediaPresentations()
        v.setAllMediaPlaybackSuspended(true)
        isMediaSuspended = true
    }

    /// Lifts the suspension when the service shows again. Playback stays paused: only the app's person (or the page, after a tap) starts it.
    func resumeMediaPlaybackAllowed() {
        guard isMediaSuspended, let v = webView else { isMediaSuspended = false; return }
        v.setAllMediaPlaybackSuspended(false)
        isMediaSuspended = false
    }

    /// The same, returning only once the page has actually paused and its presentations are closed.
    func pauseMedia() async {
        guard let v = webView else { return }
        await v.pauseAllMediaPlayback()
        await v.closeAllMediaPresentations()
    }

    /// Frees the web view and its share of the web process. The website data is untouched.
    func release() {
        guard let v = webView else { return }
        pauseMediaNow()
        v.stopLoading(); v.navigationDelegate = nil; v.uiDelegate = nil; v.menuActions = nil
        v.removeFromSuperview()
        if let d = cookieObserver { dataStore().httpCookieStore.remove(d) }
        observers = []; webView = nil; delegates = nil; cookieObserver = nil; isMediaSuspended = false
        pressureSource?.cancel(); pressureSource = nil
    }
}
