import Foundation
import CryptoKit
import Network
import Security
#if os(macOS)
import AppKit
#endif

// Spotify access, in three optional layers. Nothing is needed to open a pasted link (that uses the public embed pages, see SpotifyEmbed.swift).
//  1. App-only: the person pastes the client id AND client secret of their own developer app; the client-credentials token then enables search,
//     albums, artists and public playlists. No account is involved.
//  2. Sign in: Authorization Code with PKCE and the same client id, for the person's own library. No secret is used.
// Nothing is embedded in the app. Ids, secret and tokens live in the Keychain only. Web player tokens and cookies are never read.

// MARK: secrets

protocol SpotifySecretStore: Sendable {
    func read(_ key: String) -> String?
    func write(_ value: String?, for key: String)
}

struct SpotifyKeychainStore: SpotifySecretStore {
    func read(_ key: String) -> String? { MusicKeychain.shared.read(key) }
    func write(_ value: String?, for key: String) { MusicKeychain.shared.write(key, value) }
}

/// In memory store for tests and previews.
final class MemorySpotifySecretStore: SpotifySecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    init(_ initial: [String: String] = [:]) { values = initial }
    func read(_ key: String) -> String? { lock.withLock { values[key] } }
    func write(_ value: String?, for key: String) { lock.withLock { values[key] = value } }
}

// MARK: PKCE

enum SpotifyPKCE {
    /// 86 random URL safe characters (RFC 7636 allows 43 to 128).
    static func makeVerifier() -> String { base64URL(randomBytes(64)) }

    /// BASE64URL(SHA256(verifier)) without padding.
    static func challenge(for verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    static func makeState() -> String { base64URL(randomBytes(16)) }

    static func base64URL(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func randomBytes(_ n: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: n)
        if SecRandomCopyBytes(kSecRandomDefault, n, &bytes) != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        }
        return Data(bytes)
    }
}

// MARK: loopback listener

/// A one shot HTTP listener on 127.0.0.1 that catches the redirect from Spotify, answers with a small page, then goes away.
final class LoopbackCallbackServer: @unchecked Sendable {
    let port: UInt16
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "streamsetu.music.loopback")
    private var listener: NWListener?
    private var outcome: Result<URL, Error>?
    private var waiter: CheckedContinuation<URL, Error>?
    private var readyWaiter: CheckedContinuation<Void, Error>?
    private var isReady = false

    init(port: UInt16) { self.port = port }

    func start() async throws {
        guard let p = NWEndpoint.Port(rawValue: port) else { throw MusicError.network("bad port") }
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let l: NWListener
        do { l = try NWListener(using: params, on: p) } catch { throw MusicError.network("port \(port) is in use") }
        l.stateUpdateHandler = { [weak self] st in self?.stateChanged(st) }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        lock.withLock { listener = l }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.withLock {
                if isReady { c.resume() } else { readyWaiter = c }
            }
            l.start(queue: queue)
        }
    }

    func stop() {
        let l = lock.withLock { () -> NWListener? in let x = listener; listener = nil; return x }
        l?.cancel()
        deliver(.failure(MusicError.cancelled))
    }

    /// Waits for the browser to come back, up to `timeout` seconds.
    func waitForCallback(timeout: TimeInterval) async throws -> URL {
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.deliver(.failure(MusicError.network("sign in timed out"))) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
                let done = lock.withLock { () -> Result<URL, Error>? in
                    if let o = outcome { return o }
                    waiter = c
                    return nil
                }
                if let done { c.resume(with: done) }
            }
        } onCancel: { [weak self] in self?.deliver(.failure(MusicError.cancelled)) }
    }

    private func deliver(_ r: Result<URL, Error>) {
        let w = lock.withLock { () -> CheckedContinuation<URL, Error>? in
            guard outcome == nil else { return nil }
            outcome = r
            let x = waiter; waiter = nil
            return x
        }
        w?.resume(with: r)
    }

    private func stateChanged(_ st: NWListener.State) {
        switch st {
        case .ready:
            let w = lock.withLock { () -> CheckedContinuation<Void, Error>? in isReady = true; let x = readyWaiter; readyWaiter = nil; return x }
            w?.resume()
        case .failed(let e):
            let w = lock.withLock { () -> CheckedContinuation<Void, Error>? in let x = readyWaiter; readyWaiter = nil; return x }
            if let w { w.resume(throwing: MusicError.network(e.localizedDescription)) } else { deliver(.failure(MusicError.network(e.localizedDescription))) }
        default: break
        }
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { c.cancel(); return }
            let target = data.flatMap { String(data: $0, encoding: .utf8) }.flatMap(Self.requestTarget)
            let isCallback = target?.hasPrefix("/callback") == true
            let page = isCallback
                ? "<html><body style=\"font-family:-apple-system,sans-serif;text-align:center;padding:60px\"><h2>Signed in</h2><p>You can close this tab and go back to StreamSetu.</p></body></html>"
                : "Not found"
            let head = "HTTP/1.1 \(isCallback ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n"
            c.send(content: Data((head + page).utf8), completion: .contentProcessed { _ in c.cancel() })
            if isCallback, let target, let url = URL(string: "http://127.0.0.1:\(self.port)" + target) { self.deliver(.success(url)) }
        }
    }

    /// "GET /callback?code=x HTTP/1.1" gives "/callback?code=x".
    static func requestTarget(_ request: String) -> String? {
        guard let line = request.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: true).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return String(parts[1])
    }
}

// MARK: auth

/// What the person has set up, readable without waiting (provider capabilities are read from views).
struct SpotifyAccessState: Sendable, Equatable {
    /// Client id and secret are both saved: search and public catalogue calls work.
    var hasAppKeys = false
    /// A sign in is saved: the person's own library works.
    var signedIn = false
}

/// A small locked copy of `SpotifyAccessState`, refreshed whenever the actor changes a secret.
final class SpotifyAccessCache: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SpotifyAccessState?
    private let compute: @Sendable () -> SpotifyAccessState
    init(_ compute: @escaping @Sendable () -> SpotifyAccessState) { self.compute = compute }
    var state: SpotifyAccessState {
        lock.lock(); defer { lock.unlock() }
        if let v = value { return v }
        let v = compute(); value = v; return v
    }
    func invalidate() { lock.lock(); value = nil; lock.unlock() }
}

actor SpotifyAuth {
    static let defaultPort: UInt16 = 43821
    static let scopes = ["user-library-read", "user-library-modify", "playlist-read-private", "playlist-read-collaborative", "user-follow-read", "user-read-private"]

    private enum Key {
        static let clientID = "spotify.clientID", access = "spotify.accessToken", refresh = "spotify.refreshToken"
        static let expiry = "spotify.expiry", port = "spotify.port", secret = "spotify.clientSecret"
    }
    struct TokenSet: Sendable { var access: String; var refresh: String?; var expiresIn: Double }

    private let http: MusicHTTP
    private let store: SpotifySecretStore
    private let openURL: @Sendable (URL) async -> Bool
    private var refreshing: Task<TokenSet, Error>?
    private var appTokenTask: Task<TokenSet, Error>?
    private var appToken: (value: String, expires: Date)?
    nonisolated private let cache: SpotifyAccessCache

    init(http: MusicHTTP = MusicHTTP(), store: SpotifySecretStore = SpotifyKeychainStore(), openURL: (@Sendable (URL) async -> Bool)? = nil) {
        self.http = http
        self.store = store
        self.openURL = openURL ?? Self.systemOpen
        self.cache = SpotifyAccessCache {
            func has(_ k: String) -> Bool { !(store.read(k) ?? "").isEmpty }
            return SpotifyAccessState(hasAppKeys: has(Key.clientID) && has(Key.secret), signedIn: has(Key.refresh))
        }
    }

    /// What is set up right now, without waiting.
    nonisolated var access: SpotifyAccessState { cache.state }

    private static let systemOpen: @Sendable (URL) async -> Bool = { url in
        #if os(macOS)
        return await MainActor.run { NSWorkspace.shared.open(url) }
        #else
        return false
        #endif
    }

    // MARK: settings

    var clientID: String? { store.read(Key.clientID).flatMap { $0.isEmpty ? nil : $0 } }
    func setClientID(_ id: String) {
        let t = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if t != clientID { clearTokens(); appToken = nil }
        store.write(t.isEmpty ? nil : t, for: Key.clientID)
        cache.invalidate()
    }

    var clientSecret: String? { store.read(Key.secret).flatMap { $0.isEmpty ? nil : $0 } }

    /// Saves the person's own developer app (id and secret) for app-only access. An empty secret removes only the secret.
    func setAppKeys(clientID id: String, secret: String) {
        setClientID(id)
        let s = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        store.write(s.isEmpty ? nil : s, for: Key.secret)
        appToken = nil
        cache.invalidate()
    }

    func clearAppKeys() {
        store.write(nil, for: Key.secret); appToken = nil; cache.invalidate()
    }

    /// True when Spotify accepts the saved id and secret. Used by Settings after the person pastes them; nothing else calls it.
    func verifyAppKeys() async -> Bool {
        appToken = nil
        return (try? await appOnlyToken()) != nil
    }
    var port: UInt16 { store.read(Key.port).flatMap(UInt16.init) ?? Self.defaultPort }
    func setPort(_ p: UInt16) { store.write(String(p), for: Key.port) }
    /// The exact address the person must add under "Redirect URIs" in their Spotify app.
    var redirectURI: String { "http://127.0.0.1:\(port)/callback" }
    var isSignedIn: Bool { store.read(Key.refresh) != nil }
    var hasAppKeys: Bool { clientID != nil && clientSecret != nil }

    // MARK: sign in / out

    static func authorizeURL(clientID: String, redirectURI: String, challenge: String, state: String, scopes: [String] = SpotifyAuth.scopes) -> URL? {
        var c = URLComponents(string: "https://accounts.spotify.com/authorize")
        c?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID), URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI), URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge), URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " "))
        ]
        return c?.url
    }

    func signIn() async throws {
        guard let cid = clientID else { throw MusicError.unsupported("signing in needs your own Spotify client ID (add it in Settings first)") }
        let verifier = SpotifyPKCE.makeVerifier(), state = SpotifyPKCE.makeState()
        let redirect = redirectURI
        guard let url = Self.authorizeURL(clientID: cid, redirectURI: redirect, challenge: SpotifyPKCE.challenge(for: verifier), state: state) else {
            throw MusicError.network("bad address")
        }
        let server = LoopbackCallbackServer(port: port)
        try await server.start()
        defer { server.stop() }
        guard await openURL(url) else { throw MusicError.unsupported("opening the browser for Spotify sign in on this device") }
        let cb = try await server.waitForCallback(timeout: 180)
        let items = URLComponents(url: cb, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ n: String) -> String? { items.first { $0.name == n }?.value }
        if value("error") != nil { throw MusicError.cancelled }
        guard value("state") == state, let code = value("code") else { throw MusicError.network("sign in reply did not match") }
        let t = try await Self.tokenRequest(http, [
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirect, "client_id": cid, "code_verifier": verifier
        ])
        save(t, previousRefresh: nil)
    }

    func signOut() { clearTokens() }

    private func clearTokens() {
        store.write(nil, for: Key.access); store.write(nil, for: Key.refresh); store.write(nil, for: Key.expiry)
        cache.invalidate()
    }

    // MARK: tokens

    /// The token a catalogue call should use, or nil when the person set nothing up. A signed in person's own token is preferred; if it was revoked the
    /// app-only token takes over, and with neither the answer is nil (callers skip quietly instead of raising a sign-in error).
    func apiToken() async -> String? {
        if isSignedIn, let t = try? await validAccessToken() { return t }
        return try? await appOnlyToken()
    }

    /// Client-credentials token for the person's own developer app. Lasts about an hour; one request serves every caller that asks meanwhile.
    func appOnlyToken() async throws -> String {
        if let t = appToken, t.expires > Date().addingTimeInterval(60) { return t.value }
        guard let cid = clientID, let secret = clientSecret else { throw MusicError.notSignedIn("spotify") }
        if let running = appTokenTask { return try await running.value.access }
        let http = self.http
        let basic = Data("\(cid):\(secret)".utf8).base64EncodedString()
        let task = Task { try await Self.tokenRequest(http, ["grant_type": "client_credentials"], headers: ["Authorization": "Basic " + basic]) }
        appTokenTask = task
        defer { appTokenTask = nil }
        do {
            let t = try await task.value
            appToken = (t.access, Date().addingTimeInterval(t.expiresIn))
            return t.access
        } catch MusicError.network(let m) where m == "HTTP 400" {
            // invalid_client: the id or secret is wrong. Callers treat it as "not set up", never as a sign-in error.
            throw MusicError.notSignedIn("spotify")
        } catch MusicError.notSignedIn {
            throw MusicError.notSignedIn("spotify")
        }
    }

    func validAccessToken() async throws -> String {
        if let t = store.read(Key.access), let e = store.read(Key.expiry).flatMap(Double.init),
           Date(timeIntervalSince1970: e) > Date().addingTimeInterval(90) { return t }
        return try await refresh()
    }

    private func refresh() async throws -> String {
        if let running = refreshing { return try await running.value.access }
        guard let rt = store.read(Key.refresh), let cid = clientID else { throw MusicError.notSignedIn("spotify") }
        let http = self.http
        let task = Task { try await Self.tokenRequest(http, ["grant_type": "refresh_token", "refresh_token": rt, "client_id": cid]) }
        refreshing = task
        defer { refreshing = nil }
        do {
            let t = try await task.value
            save(t, previousRefresh: rt)
            return t.access
        } catch MusicError.notSignedIn {
            clearTokens(); throw MusicError.notSignedIn("spotify")
        } catch MusicError.network(let m) where m == "HTTP 400" {
            // The refresh token was revoked or expired: the person has to sign in again.
            clearTokens(); throw MusicError.notSignedIn("spotify")
        }
    }

    private func save(_ t: TokenSet, previousRefresh: String?) {
        store.write(t.access, for: Key.access)
        store.write(String(Date().addingTimeInterval(t.expiresIn).timeIntervalSince1970), for: Key.expiry)
        if let r = t.refresh ?? previousRefresh { store.write(r, for: Key.refresh) }
        cache.invalidate()
    }

    private static func tokenRequest(_ http: MusicHTTP, _ fields: [String: String], headers: [String: String] = [:]) async throws -> TokenSet {
        guard let url = URL(string: "https://accounts.spotify.com/api/token") else { throw MusicError.network("bad address") }
        let data = try await http.postForm(url, fields: fields, headers: headers)
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let access = o.str("access_token") else {
            throw MusicError.network("unexpected reply")
        }
        return TokenSet(access: access, refresh: o.str("refresh_token"), expiresIn: Double(o.int("expires_in") ?? 3600))
    }
}
