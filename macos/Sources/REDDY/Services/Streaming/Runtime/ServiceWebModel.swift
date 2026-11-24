import WebKit
import AppKit
import Observation

extension ProviderDefinition {
    /// The same service with another address policy and start page (local fixtures; the UI-test override).
    func replacing(urlPolicy: ProviderURLPolicy, homeURL: URL, availability newAvailability: ServiceAvailability? = nil) -> ProviderDefinition {
        ProviderDefinition(id: id, displayName: displayName, homeURL: homeURL, availability: newAvailability ?? availability, distributionAuthorization: distributionAuthorization,
                           termsNote: termsNote, externalLinks: externalLinks, platforms: platforms, storeIdentity: storeIdentity, urlPolicy: urlPolicy,
                           capabilities: capabilities, authentication: authentication, sessionCookieDomains: sessionCookieDomains, zoomDefault: zoomDefault,
                           zoomDefaultsKey: zoomDefaultsKey, regionNote: regionNote, releaseNote: releaseNote, userAgentProfile: userAgentProfile, pageEnhancements: pageEnhancements, regionProfile: regionProfile)
    }
}

/// The one model behind every service destination, driven only by its `ProviderDefinition` (hosts, links, store, zoom) and by the configuration
/// of the runtime types it uses: `ServiceNavigationState` (what is shown), `WebViewLifecycle` (the web view), `ServiceWebDelegates` (WebKit's
/// callbacks). Plain WebKit only: no user scripts, no message handlers (so no bridge to the app), no agent string, and the page is never read.
@MainActor @Observable
final class ServiceWebModel: NSObject, ExternalServiceHost, ServiceWebEvents {
    typealias Phase = ServiceNavigationState.Phase
    typealias Notice = ServiceNavigationState.Notice

    let definition: ProviderDefinition
    let state = ServiceNavigationState()

    // What a view reads (forwarded from the navigation state).
    var phase: Phase { state.phase }
    var isSlow: Bool { state.isSlow }
    var canGoBack: Bool { state.canGoBack }
    var canGoForward: Bool { state.canGoForward }
    var notice: Notice? { state.notice }
    var pendingExternal: URL? { state.pendingExternal }
    var blockedLinkHost: String? { state.blockedLinkHost }
    var authPopup: AuthPopup? { state.authPopup }
    var lastStatusCode: Int? { state.lastStatusCode }
    var hasContent: Bool { state.hasContent }
    var hasSession: Bool { state.hasSession }
    var webView: ServiceWebView? { lifecycle.webView }
    var policy: ProviderURLPolicy { definition.urlPolicy }
    var homeURL: URL { definition.homeURL }

    private(set) var terminationCount = 0
    private(set) var releaseCount = 0
    private(set) var isVisible = false
    /// The page size (WebKit page zoom), kept between launches. Pinch zoom is off.
    private(set) var zoom: PageZoom

    /// Made on first use, so an app that never opens the service never creates its store.
    @ObservationIgnored private let storeBox: LazyDataStore
    var dataStore: WKWebsiteDataStore { storeBox.value }
    @ObservationIgnored private let lifecycle: WebViewLifecycle
    /// Where an address that must leave the app goes. Present only for a service whose links are confirmed first; nil means nothing here can launch another app.
    var openExternal: ((URL) -> Void)? {
        get { opener }
        set { opener = definition.externalLinks == .confirmThenOpen ? newValue : nil }          // a service that never leaves the app cannot be given one
    }
    @ObservationIgnored private var opener: ((URL) -> Void)?
    /// Told when this service is shown, hidden or its web content process stops (the host registry listens).
    @ObservationIgnored var onBecameVisible: ((ProviderID) -> Void)?
    @ObservationIgnored var onBecameHidden: ((ProviderID) -> Void)?
    /// Memory pressure: the registry applies one shared retention plan; without a registry the model frees itself while hidden.
    @ObservationIgnored var onMemoryPressure: ((Bool) -> Void)?
    /// Cross-provider check on a termination: answers whether an automatic reload is still allowed.
    @ObservationIgnored var onTermination: ((ProviderID, Date) -> TerminationAction)?
    @ObservationIgnored private let defaults: UserDefaults
    /// Tidy pages and the hidden elements of this service (shared preferences; tests pass their own).
    @ObservationIgnored var tidyStore: TidyStore = .shared
    @ObservationIgnored private var tidyObserver: NSObjectProtocol?
    @ObservationIgnored private var undoTask: Task<Void, Never>?
    @ObservationIgnored private let releaseAfter: Duration
    @ObservationIgnored private let slowAfter: Duration
    @ObservationIgnored private let recovery: RecoveryPolicy
    @ObservationIgnored private var delegates: ServiceWebDelegates?
    /// Where blocked hosts, redirect hops and failures are recorded (in memory). Set before the first web view is made (tests use their own).
    @ObservationIgnored var diagnostics: ServiceDiagnostics = .shared
    /// True while `clearServiceData` runs: no web view is made on the store until it has finished.
    @ObservationIgnored private var isClearing = false
    @ObservationIgnored private var releaseTask: Task<Void, Never>?
    @ObservationIgnored private var slowTask: Task<Void, Never>?
    @ObservationIgnored private var statusFailure: ServiceFailure?
    @ObservationIgnored private var terminationTimes: [Date] = []
    @ObservationIgnored private var lastExternalOpen: Date?
    /// An address the page asks to open outside the app: only while StreamSetu is the active app, and not more than once every two seconds, because WebKit does not tell the app whether a person's click or a script caused it.
    @ObservationIgnored var isAppActive: () -> Bool = { NSApp.isActive }
    @ObservationIgnored var now: () -> Date = { Date() }

    static var alertsPerLoad: Int { ServiceWebDelegates.alertsPerLoad }
    static var isRunningUnderTests: Bool { TestProcess.isRunning }

    init(definition: ProviderDefinition, dataStoreProvider: DataStoreProvider = ProductionDataStoreProvider(), dataStore: (() -> WKWebsiteDataStore)? = nil,
         defaults: UserDefaults = .standard, releaseAfter: Duration = MemoryBudget.standard.hiddenTTL, slowAfter: Duration = .seconds(20),
         recovery: RecoveryPolicy = .standard, openExternal: ((URL) -> Void)? = nil) {
        self.definition = definition; self.defaults = defaults; self.releaseAfter = releaseAfter; self.slowAfter = slowAfter; self.recovery = recovery
        zoom = PageZoom(defaults: defaults, baseline: definition.zoomDefault, storageKey: definition.zoomDefaultsKey)
        let box = LazyDataStore(dataStore ?? { dataStoreProvider.store(for: definition) })
        storeBox = box
        lifecycle = WebViewLifecycle(definition: definition, dataStore: { box.value })
        // The opener exists only for a definition whose links are confirmed first; the others hold none.
        super.init()
        self.openExternal = openExternal ?? { NSWorkspace.shared.open($0) }          // dropped unless the definition confirms links first
        let rawID = definition.id.rawValue
        tidyObserver = NotificationCenter.default.addObserver(forName: TidyStore.didChange, object: nil, queue: .main) { [weak self] note in
            guard (note.object as? String) == rawID else { return }
            MainActor.assumeIsolated { self?.lifecycle.refreshTidy() }
        }
        lifecycle.onNavigationChange = { [weak self] in self?.syncNavigationState(); self?.applyZoom() }
        lifecycle.onMemoryPressure = { [weak self] critical in
            guard let self else { return }
            if let h = self.onMemoryPressure { h(critical) } else { self.releaseResources() }
        }
    }

    /// With the first service's definition, adjusted by an address policy and start page (the original initialiser the fixtures use).
    convenience init(policy: ProviderURLPolicy? = nil, homeURL: URL? = nil, dataStore: (() -> WKWebsiteDataStore)? = nil,
                     releaseAfter: Duration = MemoryBudget.standard.hiddenTTL, slowAfter: Duration = .seconds(20), defaults: UserDefaults = .standard) {
        let base = ProviderCatalog.netflix
        self.init(definition: base.replacing(urlPolicy: policy ?? base.urlPolicy, homeURL: homeURL ?? base.homeURL), dataStore: dataStore,
                  defaults: defaults, releaseAfter: releaseAfter, slowAfter: slowAfter)
    }

    /// The model the app uses. Debug builds started by the UI tests (STREAMSETU_TESTING) may point a service at a page on this computer
    /// (`STREAMSETU_SERVICE_TEST_URL`, or `STREAMSETU_<ID>_TEST_URL` for one service), so no test ever contacts a real site.
    static func forApp(_ definition: ProviderDefinition, environment: [String: String] = ProcessInfo.processInfo.environment) -> ServiceWebModel {
        #if DEBUG
        let keys = ["STREAMSETU_\(definition.id.rawValue.uppercased())_TEST_URL", "STREAMSETU_SERVICE_TEST_URL"]
        if environment["STREAMSETU_TESTING"] != nil, let raw = keys.lazy.compactMap({ environment[$0] }).first, let url = URL(string: raw), url.host == "127.0.0.1", url.scheme == "http" {
            let local = definition.replacing(urlPolicy: ProviderURLPolicy(hostSuffixes: ["127.0.0.1"], inAppSchemes: ["http"], allowsAnyPort: true), homeURL: url)
            return ServiceWebModel(definition: local, dataStore: { .nonPersistent() })
        }
        // A test run never touches a real session: with no test address the service still gets an in-memory store.
        if environment["STREAMSETU_TESTING"] != nil { return ServiceWebModel(definition: definition, dataStore: { .nonPersistent() }) }
        #endif
        return ServiceWebModel(definition: definition)
    }

    static func makeConfiguration(dataStore: WKWebsiteDataStore, userAgent: UserAgentProfile = .safari) -> WKWebViewConfiguration { ServiceWebViewFactory.makeConfiguration(dataStore: dataStore, userAgent: userAgent) }

    // MARK: web view

    @discardableResult private func ensureWebView() -> ServiceWebView {
        let d = delegates ?? ServiceWebDelegates(events: self, diagnostics: diagnostics)
        delegates = d
        let (v, isNew) = lifecycle.ensureWebView(delegates: d, zoom: zoom.value, menuActions: { [weak self] in self?.menuActions() ?? ServiceMenuActions(canGoBack: false, canGoForward: false, back: {}, forward: {}, reload: {}) })
        if isNew { state.webViewGeneration += 1; Task { await refreshSessionFlag() } }
        return v
    }

    private func menuActions() -> ServiceMenuActions {
        ServiceMenuActions(canGoBack: canGoBack, canGoForward: canGoForward, back: { [weak self] in self?.goBack() }, forward: { [weak self] in self?.goForward() },
                           reload: { [weak self] in self?.reload() }, openInBrowser: openExternal == nil ? nil : { [weak self] in self?.openInDefaultBrowser() },
                           hideElement: canHideElement ? { [weak self] point in self?.hideElement(at: point) } : nil)
    }

    // MARK: Hide This Element

    /// The context-menu item exists only on the service's own page and while nothing restricts the app.
    var canPickElement: Bool { webView != nil && TidyRules.supports(definition.id) }
    var canHideElement: Bool { ElementPicker.isAllowed(definition: definition, pageURL: webView?.url, restricted: EnhancementRuntime.shared.isRestricted()) }

    /// Runs the one-off picker at a point (CSS pixels) and offers Undo for a few seconds.
    func hideElement(at point: CGPoint) {
        guard let v = webView else { return }
        record(.pickStarted, v)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await ElementPicker.hide(at: point, in: v, definition: self.definition, store: self.tidyStore)
            self.finishPick(outcome, v)
        }
    }

    /// Why Hide Element is not available on this page right now, or nil when it is.
    var pickRefusal: ElementPicker.Refusal? { ElementPicker.refusal(definition: definition, pageURL: webView?.url, restricted: EnhancementRuntime.shared.isRestricted()) }

    /// The second route (a Services menu command and a button on the page): pick mode, which does not depend on the page's own context menu.
    func startPickMode() {
        guard let v = webView else { return }
        guard !state.picking else { Task { await ElementPicker.cancelPickMode(in: v) }; return }
        if let r = pickRefusal { finishPick(.refused(r), v); return }
        state.picking = true; state.hiddenUndo = nil; state.pickerMessage = nil
        record(.pickStarted, v)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await ElementPicker.pickInteractively(in: v, definition: self.definition, store: self.tidyStore, hint: Localized.string("Click the element to hide. Esc cancels."))
            self.state.picking = false
            self.finishPick(outcome, v)
        }
    }

    func cancelPickMode() { guard state.picking, let v = webView else { return }; Task { await ElementPicker.cancelPickMode(in: v) } }

    private func record(_ event: ServiceDiagnostics.PickerEvent, _ v: WKWebView) {
        diagnostics.recordPicker(definition.id, url: v.url, event: event)
    }

    /// Every outcome ends in a visible notice (or the Undo bar) and one diagnostics event: the host and a reason code, never the address or the selector.
    private func finishPick(_ outcome: ElementPicker.Outcome, _ v: WKWebView) {
        undoTask?.cancel()
        func notice(_ text: String, _ event: ServiceDiagnostics.PickerEvent) {
            state.hiddenUndo = nil; state.pickerMessage = text; record(event, v)
            undoTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                self?.state.pickerMessage = nil
            }
        }
        switch outcome {
        case .hidden(let selector):
            state.pickerMessage = nil; state.hiddenUndo = selector; record(.hidden, v)
            undoTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                self?.state.hiddenUndo = nil
            }
        case .nothingSuitable: notice("Nothing safe to hide there.", .nothingSuitable)
        case .limitReached: notice("Too many hidden elements for this service. Reset them in Settings.", .limitReached)
        case .refused(let r): notice(r.notice, .refused(r))
        case .scriptFailed: notice("Couldn't read this page. Try again once it has finished loading.", .scriptFailed)
        case .cancelled: state.pickerMessage = nil; record(.cancelled, v)
        }
    }

    func undoHideElement() {
        guard let selector = state.hiddenUndo else { return }
        state.hiddenUndo = nil; undoTask?.cancel()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await ElementPicker.undo(selector, in: self.webView, definition: self.definition, store: self.tidyStore)
        }
    }
    func dismissPickerNotice() { undoTask?.cancel(); state.hiddenUndo = nil; state.pickerMessage = nil }

    private func applyZoom() {
        guard let v = webView else { return }
        let inFullscreen = v.fullscreenState != .notInFullscreen
        let target = inFullscreen ? 1.0 : zoom.value
        if abs(Double(v.pageZoom) - target) > 0.0001 { v.pageZoom = CGFloat(target) }
    }

    func zoomIn() { zoom.zoomIn(); zoom.save(to: defaults); applyZoom() }
    func zoomOut() { zoom.zoomOut(); zoom.save(to: defaults); applyZoom() }
    func resetZoom() { zoom.reset(); zoom.save(to: defaults); applyZoom() }

    private func syncNavigationState() { state.canGoBack = webView?.canGoBack ?? false; state.canGoForward = webView?.canGoForward ?? false }

    // MARK: lifecycle (ExternalServiceHost)

    func hostedView() -> ServiceWebView { ensureWebView() }

    func serviceBecameVisible() {
        onBecameVisible?(definition.id)
        isVisible = true
        releaseTask?.cancel(); releaseTask = nil
        guard !isClearing else { return }          // the data is being cleared: the page is made when that finishes
        let v = ensureWebView()
        lifecycle.resumeMediaPlaybackAllowed()
        if v.url == nil && phase != .loading { load(state.pendingURL ?? state.lastURL ?? homeURL) }
        else if phase == .terminated { reload() }
    }

    func serviceBecameHidden() {
        isVisible = false
        pauseMedia()
        releaseTask?.cancel()
        releaseTask = Task { [weak self, releaseAfter] in
            try? await Task.sleep(for: releaseAfter)
            guard !Task.isCancelled else { return }
            self?.releaseResources()
        }
        onBecameHidden?(definition.id)
    }

    /// Stops sound and closes any full-screen video. Used when the destination is hidden and when the app's own player starts. Never resumed by
    /// the app. A service that is not showing is also suspended, so its page cannot start sound again; the suspension lifts when it shows.
    func pauseMedia() { if isVisible { lifecycle.pauseMediaNow() } else { lifecycle.suspendMedia() } }
    var isMediaSuspended: Bool { lifecycle.isMediaSuspended }
    /// The same, returning once the page has actually paused.
    func pauseMediaAndWait() async { await lifecycle.pauseMedia() }

    /// Frees the web view and its web process while hidden. The last page address is kept, the website data is not touched, so coming back
    /// loads the page again and the sign-in is still there.
    func releaseResources() {
        guard !isVisible else { return }
        releaseWebView()
    }

    private func releaseWebView() {
        guard let v = webView else { return }
        if let u = v.url, policy.decide(u, isMainFrame: true) == .allowInApp { state.lastURL = u }
        lifecycle.release(); delegates = nil
        state.authPopup?.close()
        slowTask?.cancel(); state.resetForReleasedView(); releaseCount += 1
    }

    // MARK: actions

    func load(_ url: URL) {
        guard policy.decide(url, isMainFrame: true) == .allowInApp else { return }
        let v = ensureWebView()
        state.pendingURL = url; statusFailure = nil; state.notice = nil; state.blockedLinkHost = nil
        v.load(URLRequest(url: url))
    }

    /// The person changed a page addition after this page loaded: reloading applies it (or removes it).
    var enhancementsStale: Bool { _ = EnhancementRuntime.shared.store.revision; return lifecycle.enhancementsStale }
    func applyEnhancementChanges() { lifecycle.refreshEnhancements(); reload() }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }

    func reload() {
        guard let v = webView else { load(state.lastURL ?? homeURL); return }
        state.notice = nil; state.blockedLinkHost = nil; statusFailure = nil
        switch phase {
        case .failed, .terminated, .idle: load(state.pendingURL ?? state.lastURL ?? homeURL)
        default: if v.url != nil { v.reload() } else { load(state.pendingURL ?? state.lastURL ?? homeURL) }
        }
    }

    /// The error card's button: the same as a reload from a failed or stopped state.
    func retry() { reload() }

    /// Whether Open in Default Browser does anything for this service (only a service whose links are confirmed first has an opener).
    var canOpenInBrowser: Bool { openExternal != nil }

    func openInDefaultBrowser() {
        guard let openExternal else { return }
        let candidate = webView?.url ?? state.pendingURL ?? state.lastURL ?? homeURL
        openExternal(policy.decide(candidate, isMainFrame: true) == .allowInApp ? candidate : homeURL)
    }

    /// Only the host of the destination is shown to the person, never the path or query.
    static func destinationLabel(_ url: URL) -> String {
        switch url.scheme?.lowercased() {
        case "mailto": return Localized.string("an email address")
        case "tel": return Localized.string("a phone number")
        default: return url.host ?? Localized.string("another website")
        }
    }

    /// The person said Open. Secondary guards: StreamSetu must be the active app, and not more than one open every two seconds.
    func confirmExternal() {
        guard let url = state.pendingExternal, let openExternal, isAppActive() else { return }
        state.pendingExternal = nil
        let t = now()
        if let last = lastExternalOpen, t.timeIntervalSince(last) < 2 { return }
        lastExternalOpen = t
        openExternal(url)
    }
    func cancelExternal() { state.pendingExternal = nil }
    func dismissBlockedLink() { blockedLinkTask?.cancel(); state.blockedLinkHost = nil }
    func dismissNotice() { state.notice = nil }

    /// What the error card offers, from the definition (see `ServiceFailureScreen`).
    var failureScreen: ServiceFailureScreen? { ServiceFailureScreen(phase: phase, definition: definition) }

    /// Removes the cookies, storage and caches of this service's store only (nothing else uses it): the web view is released first, then the
    /// store is cleared and checked, and the home page loads again if the service was showing. Other services are untouched.
    func clearServiceData() async { _ = await clearServiceDataReporting() }

    /// The same, saying how many records the store still holds afterwards (none when it all went).
    func clearServiceDataReporting() async -> SessionClearing.ClearReport {
        isClearing = true
        releaseWebView()
        let report = await SessionClearing.clear(dataStore)
        state.lastURL = nil; state.pendingURL = nil
        await refreshSessionFlag()
        isClearing = false
        if isVisible { load(homeURL) }
        return report
    }

    // MARK: load state

    private func beginLoading() {
        state.phase = .loading; state.isSlow = false
        slowTask?.cancel()
        slowTask = Task { [weak self, slowAfter] in
            try? await Task.sleep(for: slowAfter)
            guard !Task.isCancelled, let self, self.phase == .loading else { return }
            self.state.isSlow = true
        }
    }

    /// Whether the service's store holds cookie data at all, from the website-data records (a domain name and the kinds of data held). No
    /// cookie object is fetched, so no cookie name, value or flag is ever in memory here.
    func refreshSessionFlag() async {
        let records = await dataStore.dataRecords(ofTypes: [WKWebsiteDataTypeCookies])
        state.hasSession = records.contains { Self.recordBelongs($0.displayName, to: definition) }
    }

    /// A record's name is the site it belongs to (usually the registrable domain, e.g. "apple.com"): it counts when it is one of the service's
    /// session domains or a host the service's own policy allows.
    static func recordBelongs(_ name: String, to d: ProviderDefinition) -> Bool {
        let n = name.lowercased().hasPrefix(".") ? String(name.dropFirst()).lowercased() : name.lowercased()
        if d.sessionCookieDomains.contains(where: { n == $0 || n.hasSuffix("." + $0) }) { return true }
        return d.urlPolicy.isAllowedHost(n) && !HostRule.googleSignInHosts.contains(n)          // signing in at Google is not a session with the service
    }

    private func endLoading() { slowTask?.cancel(); state.isSlow = false }

    // MARK: ServiceWebEvents

    func addressAllowed(_ url: URL) { state.pendingURL = url }

    /// The page asked to open an address outside the site (a link, a pop-up or a redirect). By configuration it is held until the person
    /// answers, or cancelled with a notice; it never opens by itself.
    func addressOffSite(_ url: URL) {
        guard policy.decide(url, isMainFrame: true) == .openExternally else { return }
        switch definition.externalLinks {
        case .confirmThenOpen: state.pendingExternal = url
        case .blockWithNotice: state.blockedLinkHost = Self.destinationLabel(url); scheduleBlockedLinkDismissal()
        }
    }

    /// The "link blocked" note goes away by itself after a few seconds (and sooner if the person dismisses it or the page changes).
    static var blockedLinkLifetime: Duration = .seconds(6)
    @ObservationIgnored private var blockedLinkTask: Task<Void, Never>?
    private func scheduleBlockedLinkDismissal() {
        blockedLinkTask?.cancel()
        let shown = state.blockedLinkHost
        blockedLinkTask = Task { [weak self] in
            try? await Task.sleep(for: Self.blockedLinkLifetime)
            guard !Task.isCancelled, let self, self.state.blockedLinkHost == shown else { return }
            self.state.blockedLinkHost = nil
        }
    }

    func presentAuthPopup(_ popup: AuthPopup) {
        state.authPopup?.close()
        state.authPopup = popup
        popup.onClose { [weak self, weak popup] in if let self, self.state.authPopup === popup { self.state.authPopup = nil } }
    }
    func closeAuthPopup() { state.authPopup?.close() }

    func downloadBlocked() { state.notice = .downloadBlocked }
    func openInPlace(_ url: URL) { load(url) }

    func mainResponse(statusCode: Int?) {
        state.lastStatusCode = statusCode
        if let s = statusCode, (500...599).contains(s) { statusFailure = .siteUnavailable(status: s) } else { statusFailure = nil }
    }

    func loadStarted() { beginLoading() }

    func loadCommitted(_ url: URL?) {
        if let u = url, policy.decide(u, isMainFrame: true) == .allowInApp, !policy.isGoogleSignInHost(u.host) { state.lastURL = u }          // a sign-in page is never the place to resume
        state.hasContent = true; applyZoom(); syncNavigationState()
    }

    func loadFinished() {
        endLoading(); syncNavigationState()
        Task { await refreshSessionFlag() }
        state.phase = statusFailure.map { .failed($0) } ?? .ready
    }

    /// The provider's own server sent the load to its regional page: a state of its own (not a network failure, not the app's address policy).
    /// The cancelled load reports a policy cancellation right after; `loadFailed` leaves this state in place.
    func regionRestricted(host: String, label: String?) {
        endLoading(); statusFailure = nil; state.blockedLinkHost = nil; state.pendingExternal = nil; state.notice = nil
        state.phase = .failed(.regionRestricted(host: host, label: label))
    }

    func loadFailed(_ error: Error) {
        if case .failed(.regionRestricted) = state.phase, ServiceFailure.from(domain: (error as NSError).domain, code: (error as NSError).code) == nil { return }
        endLoading()
        let e = error as NSError
        guard let failure = ServiceFailure.from(domain: e.domain, code: e.code) else {
            state.phase = webView?.url == nil ? .idle : .ready; return          // cancelled on purpose
        }
        state.phase = .failed(failure)
    }

    func processTerminated() { webViewWebContentProcessDidTerminate(webView) }

    /// A web content process stopped. Reloads by itself at most twice a minute (and only while this service shows, and the other services have
    /// not also been stopping); after that the page stays stopped until the person asks again.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView?) {
        terminationCount += 1
        let t = Date()
        terminationTimes = recovery.recent(terminationTimes, now: t) + [t]
        endLoading()
        state.phase = .terminated
        let shared = onTermination?(definition.id, t) ?? .reload
        guard isVisible else { return }          // a hidden service is reloaded when it is shown again
        if recovery.action(terminations: terminationTimes, now: t) == .reload && shared == .reload { load(state.pendingURL ?? state.lastURL ?? homeURL) }
    }

    func cookiesChanged() { Task { await refreshSessionFlag() } }
}
