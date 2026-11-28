import Foundation
#if canImport(WebKit)
import WebKit
#endif

// Proof-of-origin tokens, produced the way the site itself does it: a hidden web view (a real browser engine) loads YouTube's own attestation
// interpreter, runs it on the challenge YouTube hands out for the current visitor id, asks the attestation service for an integrity token, and
// mints tokens with the minter the script hands back. Nothing is emulated and nothing is stored beyond the app session. The component starts
// lazily, answers within a few seconds or not at all, and the callers fall back to the clients that need no token.

struct YouTubePoTokenTransport: Sendable {
    /// Performs one request and returns the body and status code. Replaceable so tests need no network.
    var send: @Sendable (URLRequest) async throws -> (Data, Int)
    static let live = YouTubePoTokenTransport { request in
        let (data, response) = try await HTTPClient.app.exchangeWithResponse(request, maxBytes: 4_000_000)
        return (data, response?.statusCode ?? 0)
    }
}

/// Runs the interpreter and mints. The real one is a web view; tests supply a stub.
protocol YouTubeBotGuardRunner: Sendable {
    /// Loads the interpreter script and program; returns the BotGuard response string to send to the attestation service.
    func start(interpreterScript: String, program: String, globalName: String) async throws -> String
    /// Gives the integrity token to the minter the VM produced.
    func prepareMinter(integrityToken: [UInt8]) async throws
    /// A token for one binding (video id or visitor id), URL-safe base64.
    func mint(binding: String) async throws -> String
    func shutdown() async
}

actor YouTubePoTokenProvider: YouTubePoTokenSource {
    static let timeout: TimeInterval = 4
    private struct Session { var visitorData: String; var integrity: YouTubeAttestation.Integrity; var expires: Date; var minterReady: Bool }

    private let transport: YouTubePoTokenTransport
    private let runner: YouTubeBotGuardRunner
    private let now: @Sendable () -> Date
    private var session: Session?
    private var sessionTokens: [String: (token: String, expires: Date)] = [:]
    private var videoTokens: [String: (token: String, expires: Date)] = [:]
    private var lastVisitor: String?
    private var failedAt: Date?
    private var starting: Task<Session?, Never>?
    /// After a failed start the provider is quiet for a while instead of retrying on every song.
    static let retryGap: TimeInterval = 120

    init(transport: YouTubePoTokenTransport = .live, runner: YouTubeBotGuardRunner? = nil, pageConfig: String = "", now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        #if canImport(WebKit)
        self.runner = runner ?? YouTubeWebViewBotGuard(pageConfig: pageConfig)
        #else
        self.runner = runner ?? YouTubeNoBotGuard()
        #endif
        self.now = now
    }

    // MARK: YouTubePoTokenSource

    func sessionToken(visitorData: String) async -> String? {
        lastVisitor = visitorData
        if let t = sessionTokens[visitorData], t.expires > now() { return t.token }
        guard let s = await ensureSession(visitorData: visitorData) else { return nil }
        guard let token = await bounded({ try await self.runner.mint(binding: YouTubeAttestation.visitorBinding(visitorData)) }) else { return nil }
        sessionTokens[visitorData] = (token, s.expires)
        return token
    }

    func streamingToken(videoID: String) async -> String? {
        if let t = videoTokens[videoID], t.expires > now() { return t.token }
        guard let visitor = lastVisitor, let s = await ensureSession(visitorData: visitor) else { return nil }
        guard let token = await bounded({ try await self.runner.mint(binding: videoID) }) else { return nil }
        if videoTokens.count > 200 { videoTokens.removeAll() }
        videoTokens[videoID] = (token, s.expires)
        return token
    }

    /// Drops everything (sign-out, identity change).
    func reset() async {
        session = nil; sessionTokens = [:]; videoTokens = [:]; failedAt = nil; starting = nil
        await runner.shutdown()
    }

    // MARK: session

    private func ensureSession(visitorData: String) async -> Session? {
        if let s = session, s.visitorData == visitorData, s.expires > now() { return s }
        if let f = failedAt, now().timeIntervalSince(f) < Self.retryGap { return nil }
        if let t = starting { return await t.value }
        let task = Task<Session?, Never> { await self.startSession(visitorData: visitorData) }
        starting = task
        let result = await task.value
        starting = nil
        if result == nil { failedAt = now() } else { failedAt = nil }
        session = result
        if result != nil { sessionTokens = [:]; videoTokens = [:] }
        return result
    }

    /// The whole start (challenge, script, VM, integrity token) shares one budget a little longer than a single mint, since it runs once.
    private func startSession(visitorData: String) async -> Session? {
        await bounded(total: Self.timeout * 2) { [transport, runner, now] in
            var challengeData: Data?
            for u in YouTubeAttestation.challengeURLs {
                guard let url = URL(string: u) else { continue }
                var r = URLRequest(url: url)
                r.httpMethod = "POST"; r.httpBody = YouTubeAttestation.challengeBody(visitorData: visitorData)
                r.setValue("application/json", forHTTPHeaderField: "content-type")
                r.setValue(visitorData, forHTTPHeaderField: "x-goog-visitor-id")
                if let (d, code) = try? await transport.send(r), code == 200 { challengeData = d; break }
            }
            guard let cd = challengeData, let challenge = YouTubeAttestation.parseChallenge(cd), let scriptURL = URL(string: challenge.interpreterURL) else { return nil }
            let (scriptData, scriptCode) = try await transport.send(URLRequest(url: scriptURL))
            guard scriptCode == 200, let script = String(data: scriptData, encoding: .utf8) else { return nil }
            let response = try await runner.start(interpreterScript: script, program: challenge.program, globalName: challenge.globalName)
            var g = URLRequest(url: URL(string: YouTubeAttestation.generateURL)!)
            g.httpMethod = "POST"; g.httpBody = YouTubeAttestation.generateBody(botguardResponse: response)
            g.setValue("application/json+protobuf", forHTTPHeaderField: "content-type")
            g.setValue(YouTubeAttestation.apiKey, forHTTPHeaderField: "x-goog-api-key")
            g.setValue("grpc-web-javascript/0.1", forHTTPHeaderField: "x-user-agent")
            let (idata, icode) = try await transport.send(g)
            guard icode == 200, let integrity = YouTubeAttestation.parseIntegrity(idata), let bytes = YouTubeAttestation.decodeWebsafe(integrity.token) else { return nil }
            try await runner.prepareMinter(integrityToken: bytes)
            return Session(visitorData: visitorData, integrity: integrity, expires: now().addingTimeInterval(integrity.ttl), minterReady: true)
        }
    }

    private func bounded<T: Sendable>(total: TimeInterval = YouTubePoTokenProvider.timeout, _ op: @escaping @Sendable () async throws -> T?) async -> T? {
        let r: T?? = try? await ytmWithTimeout(total) { try await op() }
        return r ?? nil
    }
}

struct YouTubeNoBotGuard: YouTubeBotGuardRunner {
    func start(interpreterScript: String, program: String, globalName: String) async throws -> String { throw YTMCipherRunnerError.unavailable }
    func prepareMinter(integrityToken: [UInt8]) async throws { throw YTMCipherRunnerError.unavailable }
    func mint(binding: String) async throws -> String { throw YTMCipherRunnerError.unavailable }
    func shutdown() async {}
}

#if canImport(WebKit)
@MainActor private final class BotGuardPage: NSObject, WKNavigationDelegate {
    private var web: WKWebView?
    private var loaded: CheckedContinuation<Void, Error>?

    func ensure() async throws -> WKWebView {
        if let web { return web }
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 4, height: 4), configuration: WKWebViewConfiguration())
        w.navigationDelegate = self
        web = w
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            loaded = c
            // The page lives on the site's own origin so the script sees the environment it expects. No content of the site is fetched.
            w.loadHTMLString("<!doctype html><html><head><meta charset=utf-8></head><body></body></html>", baseURL: URL(string: "https://www.youtube.com/"))
        }
        return w
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { Task { @MainActor in self.loaded?.resume(); self.loaded = nil } }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { Task { @MainActor in self.loaded?.resume(throwing: error); self.loaded = nil } }

    func run(_ body: String, args: [String: Any]) async throws -> String {
        let w = try await ensure()
        let result = try await w.callAsyncJavaScript(body, arguments: args, in: nil, contentWorld: .page)
        guard let s = result as? String else { throw YTMCipherRunnerError.exportsMissing }
        return s
    }

    func teardown() { web?.stopLoading(); web = nil }
}

final class YouTubeWebViewBotGuard: YouTubeBotGuardRunner, @unchecked Sendable {
    private nonisolated(unsafe) var stored: BotGuardPage?
    /// The site's page configuration (the JSON the home page hands to its config object), set into the page before the interpreter runs.
    private let pageConfig: String
    init(pageConfig: String = "") { self.pageConfig = pageConfig }
    @MainActor private func page() -> BotGuardPage {
        if let stored { return stored }
        let p = BotGuardPage(); stored = p; return p
    }

    private static let startJS = """
    const g = window; g.__bg = {po: []};
    if (pageConfig) {
      const c = JSON.parse(pageConfig);
      g.yt = g.yt || {}; g.yt.config_ = c;
      g.ytcfg = { data_: c, get: function (k, d) { return (k in c) ? c[k] : d; }, set: function () {} };
    }
    const tag = document.createElement('script'); tag.textContent = interpreter; document.head.appendChild(tag);
    const vm = g[globalName];
    if (!vm || !vm.a) throw new Error('no vm');
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('vm setup timed out')), 3000);
      try {
        const r = vm.a(program, function (snapshot) { g.__bg.snapshot = snapshot; clearTimeout(timer); resolve(); }, true, undefined, function () {}, [[], []], undefined, false, undefined);
        g.__bg.sync = r && r[0];
      } catch (e) { clearTimeout(timer); reject(e); }
    });
    return await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('snapshot timed out')), 3000);
      g.__bg.snapshot(function (resp) { clearTimeout(timer); resolve(String(resp)); }, [undefined, undefined, g.__bg.po, undefined]);
    });
    """
    private static let prepareJS = """
    const bytes = Uint8Array.from(atob(b64), c => c.charCodeAt(0));
    const getMinter = window.__bg && window.__bg.po && window.__bg.po[0];
    if (typeof getMinter !== 'function') throw new Error('no minter factory');
    const minter = await getMinter(bytes);
    if (typeof minter !== 'function') throw new Error('no minter');
    window.__bg.minter = minter;
    return 'ok';
    """
    private static let mintJS = """
    if (!window.__bg || !window.__bg.minter) throw new Error('not ready');
    const out = await window.__bg.minter(new TextEncoder().encode(binding));
    const arr = Array.from(out instanceof Uint8Array ? out : new Uint8Array(out));
    return btoa(String.fromCharCode.apply(null, arr)).replace(/\\+/g, '-').replace(/\\//g, '_').replace(/=+$/, '');
    """

    func start(interpreterScript: String, program: String, globalName: String) async throws -> String {
        try await MainActor.run { self.page() }.run(Self.startJS, args: ["interpreter": interpreterScript, "program": program, "globalName": globalName, "pageConfig": pageConfig])
    }
    func prepareMinter(integrityToken: [UInt8]) async throws {
        _ = try await MainActor.run { self.page() }.run(Self.prepareJS, args: ["b64": Data(integrityToken).base64EncodedString()])
    }
    func mint(binding: String) async throws -> String {
        try await MainActor.run { self.page() }.run(Self.mintJS, args: ["binding": binding])
    }
    func shutdown() async { await MainActor.run { self.page().teardown() } }
}
#endif
