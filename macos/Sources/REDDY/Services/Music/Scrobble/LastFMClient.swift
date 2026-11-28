import Foundation
import Observation

/// Why one send failed, in the three ways the scrobbler cares about.
enum ScrobbleSendError: Error, Equatable, Sendable {
    /// The network failed; worth a short in-memory retry.
    case network(String)
    /// The service answered and said no; retrying would not help.
    case refused(String)
    /// The service no longer accepts this account.
    case listenBrainz(ListenBrainzProblem)
    case signedOut

    var message: String {
        switch self {
        case .network(let m), .refused(let m): m
        case .listenBrainz(let p): p.message
        case .signedOut: "Sign in again."
        }
    }
}

/// Shared by both service clients: sends a request through the music transport and hands back the status and body whatever the status is,
/// because the services put their error details in the body of 4xx replies.
enum ScrobbleHTTP {
    static func send(_ http: MusicHTTP, url: URL, method: String, headers: [String: String] = [:], body: Data? = nil) async throws -> (status: Int, data: Data) {
        guard url.scheme == "https" || url.scheme == "http" else { throw ScrobbleSendError.network("bad address") }
        var r = URLRequest(url: url, timeoutInterval: 15)
        r.httpMethod = method; r.httpBody = body
        r.setValue(http.userAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        do {
            let (d, resp) = try await http.transport.data(for: r)
            return (resp.statusCode, d)
        } catch let e as ScrobbleSendError { throw e
        } catch let e as MusicError {
            if case .cancelled = e { throw e }
            throw ScrobbleSendError.network(e.localizedDescription)
        } catch { throw ScrobbleSendError.network((error as NSError).localizedDescription) }
    }
}

struct LastFMAPIError: Error, Equatable, Sendable { var code: Int; var message: String }

/// Last.fm with the person's own API key and secret. Writes are signed POSTs, reads are signed GETs.
struct LastFMClient: Sendable {
    static let defaultEndpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!
    static let authorizeURL = "https://www.last.fm/api/auth/"
    static let endpointAccount = "lastfm.endpoint"
    static let credentialsAccount = LastFMProvider.credentialsAccount
    static let usernameAccount = "lastfm.username"
    static let appKeyAccount = "lastfm.appkey"
    static let appSecretAccount = "lastfm.appsecret"

    var http: MusicHTTP = MusicHTTP()
    var store: any ScrobbleSecretStore = ScrobbleKeychainStore()

    // MARK: stored state

    /// An optional Last.fm-compatible server (Libre.fm style). Empty means Last.fm itself. Must be an http(s) address with a host, no query or fragment.
    var endpoint: URL { store.read(Self.endpointAccount).flatMap { URL(string: $0) } ?? Self.defaultEndpoint }
    var usesCustomEndpoint: Bool { store.read(Self.endpointAccount) != nil }

    /// Where the person approves the app: the Last.fm page, or `/api/auth/` on the custom server's own host.
    var authorizeBase: String {
        guard usesCustomEndpoint, var c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return Self.authorizeURL }
        c.path = "/api/auth/"; c.query = nil; c.fragment = nil
        return c.string ?? Self.authorizeURL
    }

    @discardableResult
    func setEndpoint(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { store.remove(Self.endpointAccount); return true }
        guard let c = URLComponents(string: t), let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host, !host.isEmpty, c.query == nil, c.fragment == nil, let u = c.url else { return false }
        store.write(u.absoluteString, account: Self.endpointAccount)
        return true
    }

    /// The person's own API key and secret, from their entry here or from the credentials the Last.fm source already holds.
    func appKeys() -> (key: String, secret: String)? {
        if let k = store.read(Self.appKeyAccount), let s = store.read(Self.appSecretAccount), !k.isEmpty, !s.isEmpty { return (k, s) }
        if let c = credentials(), !c.usesBuiltInApp, !c.apiKey.isEmpty, !c.secret.isEmpty { return (c.apiKey, c.secret) }
        return nil
    }

    func setAppKeys(key: String, secret: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines), s = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty || s.isEmpty { store.remove(Self.appKeyAccount); store.remove(Self.appSecretAccount) }
        else { store.write(k, account: Self.appKeyAccount); store.write(s, account: Self.appSecretAccount) }
    }

    func credentials() -> LastFMProvider.Credentials? {
        store.read(Self.credentialsAccount).flatMap { try? JSONDecoder().decode(LastFMProvider.Credentials.self, from: Data($0.utf8)) }
    }
    var username: String? { store.read(Self.usernameAccount) }
    var isConnected: Bool { credentials() != nil }

    func storeSession(key: String, user: String) -> Bool {
        guard let keys = appKeys() else { return false }
        let c = LastFMProvider.Credentials(apiKey: keys.key, secret: keys.secret, sessionKey: key)
        guard let d = try? JSONEncoder().encode(c) else { return false }
        store.write(String(decoding: d, as: UTF8.self), account: Self.credentialsAccount)
        store.write(user, account: Self.usernameAccount)
        return true
    }

    func disconnect() { store.remove(Self.credentialsAccount); store.remove(Self.usernameAccount) }

    // MARK: payloads (pure)

    static func nowPlayingFields(artist: String, title: String, album: String) -> [String: String] {
        var p = ["artist": artist, "track": title]
        if !album.isEmpty { p["album"] = album }
        return p
    }

    static func scrobbleFields(artist: String, title: String, album: String, start: Date, durationMs: Int64) -> [String: String] {
        var p = nowPlayingFields(artist: artist, title: title, album: album)
        p["timestamp"] = String(Int(start.timeIntervalSince1970))
        if durationMs > 0 { p["duration"] = String(durationMs / 1000) }
        return p
    }

    static func authURL(apiKey: String, token: String, base: String = authorizeURL) -> URL? {
        guard var c = URLComponents(string: base) else { return nil }
        c.queryItems = [URLQueryItem(name: "api_key", value: apiKey), URLQueryItem(name: "token", value: token)]
        guard let u = c.url, u.scheme == "https" || u.scheme == "http" else { return nil }
        return u
    }

    /// The signed parameter set (format added after signing, so it is not part of the signature).
    static func signed(_ fields: [String: String], method: String, apiKey: String, secret: String, sessionKey: String? = nil) -> [String: String] {
        var p = fields
        p["method"] = method; p["api_key"] = apiKey
        if let sessionKey { p["sk"] = sessionKey }
        p["api_sig"] = LastFMProvider.signature(p, secret: secret)
        p["format"] = "json"
        return p
    }

    // MARK: calls

    func nowPlaying(artist: String, title: String, album: String) async throws {
        try await write("track.updateNowPlaying", Self.nowPlayingFields(artist: artist, title: title, album: album))
    }

    func scrobble(artist: String, title: String, album: String, start: Date, durationMs: Int64) async throws {
        try await write("track.scrobble", Self.scrobbleFields(artist: artist, title: title, album: album, start: start, durationMs: durationMs))
    }

    private func write(_ method: String, _ fields: [String: String]) async throws {
        guard let c = credentials(), let keys = c.resolvedKeys() else { throw ScrobbleSendError.signedOut }
        let p = Self.signed(fields, method: method, apiKey: keys.key, secret: keys.secret, sessionKey: c.sessionKey)
        do { _ = try await call(p, post: true) } catch let e as LastFMAPIError {
            switch e.code {
            case 4, 9, 14, 26: throw ScrobbleSendError.signedOut
            case 16, 29: throw ScrobbleSendError.network("Last.fm: \(e.message)")
            default: throw ScrobbleSendError.refused("Last.fm: \(e.message)")
            }
        }
    }

    func getToken() async throws -> String {
        guard let k = appKeys() else { throw LastFMAPIError(code: 10, message: "Enter your Last.fm API key and secret first.") }
        let obj = try await call(Self.signed([:], method: "auth.getToken", apiKey: k.key, secret: k.secret), post: false)
        guard let t = obj["token"] as? String, !t.isEmpty else { throw LastFMAPIError(code: -1, message: "Last.fm sent no token") }
        return t
    }

    enum SessionResult: Equatable, Sendable { case session(name: String, key: String), malformed }

    func getSession(token: String) async throws -> SessionResult {
        guard let k = appKeys() else { throw LastFMAPIError(code: 10, message: "Enter your Last.fm API key and secret first.") }
        let obj = try await call(Self.signed(["token": token], method: "auth.getSession", apiKey: k.key, secret: k.secret), post: false)
        guard let s = obj["session"] as? [String: Any], let name = s["name"] as? String, let key = s["key"] as? String, !name.isEmpty, !key.isEmpty
        else { return .malformed }
        return .session(name: name, key: key)
    }

    struct Profile: Equatable, Sendable { var imageURL: String?; var url: String?; var scrobbles: Int?; var artists: Int?; var tracks: Int?; var since: Date? }

    func profile(user: String) async throws -> Profile {
        guard let k = appKeys() else { return Profile() }
        let obj = try await call(Self.signed(["user": user], method: "user.getInfo", apiKey: k.key, secret: k.secret), post: false)
        let u = obj["user"] as? [String: Any] ?? [:]
        let images = (u["image"] as? [[String: Any]]) ?? []
        func image(_ size: String) -> String? { images.first { ($0["size"] as? String) == size }?["#text"] as? String }
        let pick = [image("large"), image("extralarge"), image("medium")].compactMap { $0 }.first { !$0.isEmpty }
        let since = (u["registered"] as? [String: Any])?.int("unixtime").map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return Profile(imageURL: pick, url: u.str("url"), scrobbles: u.int("playcount"), artists: u.int("artist_count"), tracks: u.int("track_count"), since: since)
    }

    /// One signed call. Error bodies are read whatever the HTTP status is.
    private func call(_ params: [String: String], post: Bool) async throws -> [String: Any] {
        var c = URLComponents(); c.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let query = c.percentEncodedQuery ?? ""
        let reply: (status: Int, data: Data)
        if post {
            reply = try await ScrobbleHTTP.send(http, url: endpoint, method: "POST",
                                                headers: ["Content-Type": "application/x-www-form-urlencoded"], body: Data(query.utf8))
        } else {
            guard let url = URL(string: endpoint.absoluteString + "?" + query) else { throw ScrobbleSendError.network("bad address") }
            reply = try await ScrobbleHTTP.send(http, url: url, method: "GET")
        }
        let obj = (try? JSONSerialization.jsonObject(with: reply.data)) as? [String: Any]
        if let obj, let code = obj.int("error") { throw LastFMAPIError(code: code, message: obj.str("message") ?? "error \(code)") }
        guard (200..<300).contains(reply.status) else { throw ScrobbleSendError.network("HTTP \(reply.status)") }
        // A write answered with something that is not JSON (an older-protocol "FAILED ..." line, a proxy page) did not succeed.
        if post, obj == nil { throw ScrobbleSendError.refused("Last.fm sent an unexpected reply") }
        return obj ?? [:]
    }
}

// MARK: auth flow

/// The desktop sign-in: ask for a token, open the browser, then poll every 5 seconds (up to 60 times) until the person approves.
/// Every connect and every disconnect bumps a counter, so a second click cancels the first and a stale poll never overwrites a newer session.
@MainActor @Observable
final class LastFMAuthFlow {
    enum State: Equatable { case idle, connecting, connected(String), failed(String) }

    static let pollSeconds: TimeInterval = 5
    static let maxPolls = 60

    private(set) var state: State
    /// Set by the screen (it owns the environment's URL opener).
    @ObservationIgnored var openURL: @MainActor (URL) -> Void = { _ in }
    @ObservationIgnored private let client: LastFMClient
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async -> Void
    @ObservationIgnored private var generation = 0

    init(client: LastFMClient = LastFMClient(), sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.client = client; self.sleep = sleep
        state = client.username.flatMap { client.isConnected ? .connected($0) : nil } ?? .idle
    }

    var hasAppKeys: Bool { client.appKeys() != nil }

    /// Re-reads the stored sign-in after another flow (the one-click connect) has changed it.
    func refresh() {
        generation += 1
        state = client.username.flatMap { client.isConnected ? .connected($0) : nil } ?? .idle
    }

    func connect() async {
        generation += 1
        let mine = generation
        state = .connecting
        guard let keys = client.appKeys() else { state = .failed("Enter your Last.fm API key and secret first."); return }
        let token: String
        do { token = try await client.getToken() } catch {
            if mine == generation { state = .failed("Last.fm: \(Self.text(error))") }
            return
        }
        guard mine == generation else { return }
        guard let url = LastFMClient.authURL(apiKey: keys.key, token: token, base: client.authorizeBase) else { state = .failed("Last.fm sent a bad address"); return }
        openURL(url)

        for _ in 0..<Self.maxPolls {
            await sleep(Self.pollSeconds)
            guard mine == generation else { return }
            do {
                switch try await client.getSession(token: token) {
                case .session(let name, let key):
                    guard client.storeSession(key: key, user: name) else { state = .failed("Enter your Last.fm API key and secret first."); return }
                    state = .connected(name); return
                case .malformed:
                    state = .failed("Last.fm sent a malformed session"); return
                }
            } catch let e as LastFMAPIError {
                if e.code == 14 || e.code == 16 { continue }
                guard mine == generation else { return }
                state = .failed("Last.fm: \(e.message)"); return
            } catch { continue }
        }
        if mine == generation { state = .failed("Last.fm authorization timed out - try again") }
    }

    /// Ends a pending sign-in without signing out.
    func cancel() {
        generation += 1
        if state == .connecting { state = client.username.flatMap { client.isConnected ? .connected($0) : nil } ?? .idle }
    }

    func disconnect() {
        generation += 1
        client.disconnect()
        state = .idle
    }

    private static func text(_ e: Error) -> String {
        if let a = e as? LastFMAPIError { return a.message }
        if let s = e as? ScrobbleSendError { return s.message }
        return e.localizedDescription
    }
}
