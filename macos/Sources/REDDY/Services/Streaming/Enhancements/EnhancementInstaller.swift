import WebKit

/// The ONLY place in the service runtime that creates user scripts, registers a message handler or runs a script in a page. A service's web view
/// gets these only for the enhancements its definition declares AND the person turned on AND agreed to, never while a kids profile is in use
/// or the app is locked, and only for a service whose address is https. Every other service keeps the plain recipe: no scripts, no handlers.
@MainActor
final class EnhancementInstaller {
    private let runtime: EnhancementRuntime
    private let definition: ProviderDefinition
    private weak var controller: WKUserContentController?
    private var handler: SponsorMessageHandler?
    /// What is installed in the web view right now.
    private(set) var installed: Set<PageEnhancement> = []

    init(definition: ProviderDefinition, runtime: EnhancementRuntime = .shared) { self.definition = definition; self.runtime = runtime }

    /// What would be installed now.
    var wanted: Set<PageEnhancement> { runtime.active(for: definition) }

    /// Makes the content controller match what is wanted now. Removes everything this installer put there first, so turning one off takes
    /// effect at the next load. Safe to call again at any time. Returns what is installed.
    @discardableResult
    func apply(to controller: WKUserContentController) -> Set<PageEnhancement> {
        remove(from: controller)
        self.controller = controller
        let wanted = self.wanted
        if wanted.contains(.adSkip) {
            controller.addUserScript(WKUserScript(source: YouTubeAdRules.bundled().script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        }
        if wanted.contains(.sponsorSkip) {
            let world = WKContentWorld.world(name: SponsorSkipScript.worldName)
            let h = SponsorMessageHandler(runtime: runtime, definition: definition)
            handler = h
            controller.add(h, contentWorld: world, name: SponsorSkipScript.handlerName)
            controller.addUserScript(WKUserScript(source: SponsorSkipScript.source(skippedLabel: Localized.string("Skipped sponsor"), undoLabel: Localized.string("Undo")),
                                                  injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        }
        installed = wanted
        return wanted
    }

    private func remove(from controller: WKUserContentController) {
        guard !installed.isEmpty else { return }
        controller.removeAllUserScripts()          // this installer is the only thing that ever adds scripts to a service's view
        controller.removeScriptMessageHandler(forName: SponsorSkipScript.handlerName, contentWorld: WKContentWorld.world(name: SponsorSkipScript.worldName))
        handler = nil
        installed = []
    }
}

/// Receives the one message the sponsor script sends (an 11-character video identifier) and answers with checked segments. It re-checks, at
/// every message and again after the answer arrives, that the enhancement is still on and allowed, and that the message came from the
/// service's own main frame over https.
@MainActor
final class SponsorMessageHandler: NSObject, WKScriptMessageHandler {
    private let runtime: EnhancementRuntime
    private let definition: ProviderDefinition
    private var cache: [String: (spans: [SponsorSpan], date: Date)] = [:]
    private var task: Task<Void, Never>?
    static let hitLifetime: TimeInterval = 6 * 3600
    static let emptyLifetime: TimeInterval = 3600

    init(runtime: EnhancementRuntime, definition: ProviderDefinition) { self.runtime = runtime; self.definition = definition }
    deinit { task?.cancel() }

    private var allowed: Bool { runtime.active(for: definition).contains(.sponsorSkip) }

    /// Only the service's own https main frame may ask.
    static func originAllowed(host: String, scheme: String, isMainFrame: Bool, policy: ProviderURLPolicy) -> Bool {
        isMainFrame && scheme == "https" && policy.isAllowedHost(host)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let origin = message.frameInfo.securityOrigin
        guard message.name == SponsorSkipScript.handlerName, allowed,
              Self.originAllowed(host: origin.host, scheme: origin.protocol, isMainFrame: message.frameInfo.isMainFrame, policy: definition.urlPolicy),
              let id = message.body as? String, SponsorVideoID.valid(id), let web = message.webView else { return }
        handle(videoID: id, reply: { [weak web] json in
            guard let web else { return }
            Task { @MainActor in
                _ = try? await web.callAsyncJavaScript("window.__ssSponsor && window.__ssSponsor.set(id, JSON.parse(list));", arguments: ["id": id, "list": json],
                                                       in: nil, contentWorld: WKContentWorld.world(name: SponsorSkipScript.worldName))
            }
        })
    }

    /// Looks up (or remembers) the segments and hands them back as JSON; nothing at all happens unless still allowed.
    func handle(videoID id: String, reply: @escaping @MainActor (String) -> Void) {
        guard allowed else { return }
        task?.cancel()
        if let hit = cache[id], Date().timeIntervalSince(hit.date) < (hit.spans.isEmpty ? Self.emptyLifetime : Self.hitLifetime) {
            if !hit.spans.isEmpty, let json = Self.json(hit.spans) { reply(json) }
            return
        }
        let client = runtime.client
        task = Task { [weak self] in
            guard let spans = await client.segments(forVideoID: id) else { return }          // a failure or a timeout is silent
            guard let self, !Task.isCancelled, self.allowed else { return }
            if self.cache.count >= 100 { self.cache.removeAll() }
            self.cache[id] = (spans, Date())
            if !spans.isEmpty, let json = Self.json(spans) { reply(json) }
        }
    }

    /// For tests: waits for the lookup in flight.
    func settle() async { await task?.value }

    private static func json(_ spans: [SponsorSpan]) -> String? {
        (try? JSONEncoder().encode(spans)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
