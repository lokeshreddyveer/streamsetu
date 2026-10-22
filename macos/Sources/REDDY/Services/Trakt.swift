import Foundation
import Observation

/// Trakt keeps a record of what you have watched. The person brings their own Trakt app (a free Client ID and Secret from trakt.tv/oauth/applications), signs in with a short code,
/// and then each movie or episode they finish is marked watched, and their watchlist can be added to Watch Later. Keys and tokens are kept in the Keychain and are sent only to trakt.tv.
/// Nothing is sent for a Watch Privately play or while a kids profile is in use.
struct TraktTokens: Codable, Equatable, Sendable {
    var access: String
    var refresh: String
    /// When the access token stops working.
    var expires: Date
    func isExpiring(now: Date = Date()) -> Bool { expires.timeIntervalSince(now) < 24 * 3600 }
}

struct TraktApp: Equatable, Sendable {
    var clientID = ""
    var secret = ""
    var isComplete: Bool { !clientID.trimmingCharacters(in: .whitespaces).isEmpty && !secret.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// What is being watched, as Trakt wants to hear it: a title and a year, and for an episode the show with its season and number.
enum TraktItem: Equatable, Sendable {
    case movie(title: String, year: Int?)
    case episode(show: String, year: Int?, season: Int, number: Int)

    var payload: [String: Any] {
        switch self {
        case .movie(let title, let year):
            var m: [String: Any] = ["title": title]; if let year { m["year"] = year }
            return ["movie": m]
        case .episode(let show, let year, let season, let number):
            var s: [String: Any] = ["title": show]; if let year { s["year"] = year }
            return ["show": s, "episode": ["season": season, "number": number]]
        }
    }

    /// "John Wick (2014) 4K HEVC" -> "John Wick": a provider's decoration is taken off so Trakt can find the title.
    static func cleanTitle(_ raw: String) -> String {
        var t = raw.replacingOccurrences(of: #"[\(\[][^\)\]]*[\)\]]"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i)\b(2160p|1080p|720p|480p|4k|uhd|fhd|hd|sd|hevc|x26[45]|h26[45]|bluray|brrip|webrip|web-dl|hdrip|dvdrip|dubbed|multi|sub|subs)\b"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^\s*[A-Za-z]{2,3}\s*[:|\-]\s+"#, with: "", options: .regularExpression)          // a language or country prefix, "EN - Title"
        return t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

struct TraktListed: Equatable, Sendable { let title: String; let year: Int?; let isShow: Bool }

enum TraktError: LocalizedError, Equatable {
    case noApp, notSignedIn, denied, expired, network(String), rejected(String)
    var errorDescription: String? {
        switch self {
        case .noApp: "Add your Trakt Client ID and Secret first."
        case .notSignedIn: "Sign in to Trakt first."
        case .denied: "Trakt sign-in was refused."
        case .expired: "The code ran out. Start again."
        case .network(let m): m
        case .rejected(let m): m
        }
    }
}

struct TraktClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    struct DeviceCode: Equatable, Sendable { let deviceCode: String; let userCode: String; let url: String; let expiresIn: Int; let interval: Int }

    static let base = "https://api.trakt.tv"
    let app: TraktApp
    var transport: Transport = TraktClient.live

    static let live: Transport = { request in
        let cfg = URLSessionConfiguration.ephemeral; cfg.timeoutIntervalForRequest = 20
        let (data, response) = try await URLSession(configuration: cfg).data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TraktError.network("No answer from Trakt.") }
        return (data, http)
    }

    private func request(_ path: String, token: String? = nil, body: [String: Any]? = nil) throws -> URLRequest {
        guard let url = URL(string: Self.base + path) else { throw TraktError.network("That address is not valid.") }
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("2", forHTTPHeaderField: "trakt-api-version")
        r.setValue(app.clientID, forHTTPHeaderField: "trakt-api-key")
        r.setValue("StreamSetu", forHTTPHeaderField: "User-Agent")
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { r.httpMethod = "POST"; r.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return r
    }

    private func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do { return try await transport(r) } catch let e as TraktError { throw e } catch { throw TraktError.network(error.localizedDescription) }
    }

    // MARK: signing in

    func startDeviceLogin() async throws -> DeviceCode {
        guard app.isComplete else { throw TraktError.noApp }
        let (data, http) = try await send(request("/oauth/device/code", body: ["client_id": app.clientID]))
        guard http.statusCode == 200, let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let dc = j["device_code"] as? String, let uc = j["user_code"] as? String else { throw TraktError.rejected(http.statusCode == 401 || http.statusCode == 403 ? "Trakt did not accept the Client ID." : "Trakt answered \(http.statusCode).") }
        return DeviceCode(deviceCode: dc, userCode: uc, url: (j["verification_url"] as? String) ?? "https://trakt.tv/activate", expiresIn: (j["expires_in"] as? Int) ?? 600, interval: max(1, (j["interval"] as? Int) ?? 5))
    }

    /// Asks once whether the code has been entered: tokens when it has, nil while Trakt is still waiting.
    func pollDeviceToken(_ code: DeviceCode, now: Date = Date()) async throws -> TraktTokens? {
        let (data, http) = try await send(request("/oauth/device/token", body: ["code": code.deviceCode, "client_id": app.clientID, "client_secret": app.secret]))
        switch http.statusCode {
        case 200: return try Self.tokens(from: data, now: now)
        case 400, 429: return nil                       // waiting for the person / asked too fast
        case 404, 409: throw TraktError.rejected("That code is not valid.")
        case 410, 418: throw http.statusCode == 410 ? TraktError.expired : TraktError.denied
        default: throw TraktError.rejected("Trakt answered \(http.statusCode).")
        }
    }

    func refresh(_ t: TraktTokens, now: Date = Date()) async throws -> TraktTokens {
        let (data, http) = try await send(request("/oauth/token", body: ["refresh_token": t.refresh, "client_id": app.clientID, "client_secret": app.secret,
                                                                          "redirect_uri": "urn:ietf:wg:oauth:2.0:oob", "grant_type": "refresh_token"]))
        guard http.statusCode == 200 else { throw TraktError.notSignedIn }
        return try Self.tokens(from: data, now: now)
    }

    static func tokens(from data: Data, now: Date) throws -> TraktTokens {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let a = j["access_token"] as? String, let r = j["refresh_token"] as? String else { throw TraktError.rejected("Trakt sent an unexpected answer.") }
        let created = (j["created_at"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? now
        let life = (j["expires_in"] as? Double) ?? 7_776_000
        return TraktTokens(access: a, refresh: r, expires: created.addingTimeInterval(life))
    }

    // MARK: scrobbling

    enum Scrobble: String { case start, pause, stop }

    /// Tells Trakt what is playing. `progress` is 0 to 100; a stop at 80 or more is counted as watched.
    func scrobble(_ action: Scrobble, item: TraktItem, progress: Double, tokens: TraktTokens) async throws {
        var body = item.payload
        body["progress"] = max(0, min(100, progress))
        let (_, http) = try await send(request("/scrobble/\(action.rawValue)", token: tokens.access, body: body))
        switch http.statusCode {
        case 200, 201, 409: return                      // 409: already scrobbled recently, which is fine
        case 401: throw TraktError.notSignedIn
        case 404: return                                // Trakt does not know the title: nothing to record
        default: throw TraktError.rejected("Trakt answered \(http.statusCode).")
        }
    }

    // MARK: watchlist

    func watchlist(tokens: TraktTokens) async throws -> [TraktListed] {
        var out: [TraktListed] = []
        for (kind, isShow) in [("movies", false), ("shows", true)] {
            var r = try request("/sync/watchlist/\(kind)", token: tokens.access)
            r.httpMethod = "GET"
            let (data, http) = try await send(r)
            if http.statusCode == 401 { throw TraktError.notSignedIn }
            guard http.statusCode == 200, let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { continue }
            for row in rows {
                guard let node = row[isShow ? "show" : "movie"] as? [String: Any], let title = node["title"] as? String else { continue }
                out.append(TraktListed(title: title, year: node["year"] as? Int, isShow: isShow))
            }
        }
        return out
    }
}

/// Which of the Trakt watchlist titles are in the library.
enum TraktMatching {
    /// A library title matches when its cleaned name is the same, and the years agree when both are known.
    static func matches(listed: TraktListed, title: String, year: Int?) -> Bool {
        let a = MetadataNormalizer.normalize(TraktItem.cleanTitle(listed.title)), b = MetadataNormalizer.normalize(TraktItem.cleanTitle(title))
        guard !a.isEmpty, a == b else { return false }
        if let y1 = listed.year, let y2 = year { return abs(y1 - y2) <= 1 }
        return true
    }
}

/// The Trakt account on this device: sign-in, scrobbling and the watchlist.
@MainActor @Observable
final class TraktService {
    enum State: Equatable { case notConfigured, signedOut, waitingForCode(userCode: String, url: String), signedIn }

    private(set) var state: State = .notConfigured
    private(set) var message: String?
    private let store: CredentialStore
    private let appRef = "trakt.app", tokenRef = "trakt.tokens"
    private var tokens: TraktTokens?
    private var login: Task<Void, Never>?
    private let transport: TraktClient.Transport
    /// Whether anything may be sent right now: false while a kids profile is in use.
    var allowed: () -> Bool = { true }

    init(store: CredentialStore, transport: @escaping TraktClient.Transport = TraktClient.live) {
        self.store = store; self.transport = transport
        tokens = (try? store.load(ref: tokenRef))?.password.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(TraktTokens.self, from: $0) }
        state = tokens != nil ? .signedIn : (app.isComplete ? .signedOut : .notConfigured)
    }

    var app: TraktApp {
        get { guard let c = try? store.load(ref: appRef) else { return TraktApp() }; return TraktApp(clientID: c.username ?? "", secret: c.password ?? "") }
        set {
            if newValue.isComplete { try? store.save(Credentials(username: newValue.clientID.trimmingCharacters(in: .whitespaces), password: newValue.secret.trimmingCharacters(in: .whitespaces)), ref: appRef) }
            else { try? store.delete(ref: appRef) }
            if tokens == nil { state = newValue.isComplete ? .signedOut : .notConfigured }
        }
    }

    private var client: TraktClient { var c = TraktClient(app: app); c.transport = transport; return c }
    var isSignedIn: Bool { tokens != nil }

    // MARK: signing in

    func beginSignIn() {
        message = nil
        login?.cancel()
        login = Task { [weak self] in
            guard let self else { return }
            do {
                let code = try await client.startDeviceLogin()
                state = .waitingForCode(userCode: code.userCode, url: code.url)
                let end = Date().addingTimeInterval(TimeInterval(code.expiresIn))
                while Date() < end, !Task.isCancelled {
                    try await Task.sleep(nanoseconds: UInt64(code.interval) * 1_000_000_000)
                    if let t = try await client.pollDeviceToken(code) { save(t); state = .signedIn; message = nil; return }
                }
                if !Task.isCancelled { state = .signedOut; message = TraktError.expired.errorDescription }
            } catch is CancellationError {
            } catch { state = app.isComplete ? .signedOut : .notConfigured; message = error.localizedDescription }
        }
    }

    func cancelSignIn() { login?.cancel(); state = tokens != nil ? .signedIn : (app.isComplete ? .signedOut : .notConfigured) }

    func signOut() {
        login?.cancel(); tokens = nil
        try? store.delete(ref: tokenRef)
        state = app.isComplete ? .signedOut : .notConfigured
    }

    private func save(_ t: TraktTokens) {
        tokens = t
        if let d = try? JSONEncoder().encode(t), let s = String(data: d, encoding: .utf8) { try? store.save(Credentials(username: "trakt", password: s), ref: tokenRef) }
    }

    /// A valid access token, renewed first when it is about to run out.
    private func freshTokens() async throws -> TraktTokens {
        guard var t = tokens else { throw TraktError.notSignedIn }
        if t.isExpiring() { t = try await client.refresh(t); save(t) }
        return t
    }

    // MARK: scrobbling

    /// Reports playback. It never throws to the player: a failure is only noted, and nothing is sent when signed out, in a kids profile or for a private watch (the caller does not call this then).
    func scrobble(_ action: TraktClient.Scrobble, _ item: TraktItem, progress: Double) {
        guard isSignedIn, allowed() else { return }
        Task { [weak self] in
            guard let self else { return }
            do { try await client.scrobble(action, item: item, progress: progress, tokens: try await freshTokens()) }
            catch TraktError.notSignedIn { signOut(); message = "Trakt asked you to sign in again." }
            catch { message = error.localizedDescription }
        }
    }

    // MARK: watchlist

    func watchlist() async throws -> [TraktListed] {
        guard allowed() else { return [] }
        return try await client.watchlist(tokens: try await freshTokens())
    }
}
