import Foundation
import CryptoKit

/// Last.fm scrobbling with the person's own API account: they create a key and secret at last.fm/api and paste them with a session key.
/// Nothing is embedded in the app.
struct LastFMProvider: MusicScrobbleProvider {
    static let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!
    static let credentialsAccount = "lastfm.credentials"
    private let http: MusicHTTP
    private let store: any ScrobbleSecretStore

    init(http: MusicHTTP = MusicHTTP(), store: any ScrobbleSecretStore = ScrobbleKeychainStore()) {
        self.http = http; self.store = store
    }

    /// `usesBuiltInApp` marks a session made with the app's own Last.fm application: the key and secret are then not stored at all
    /// (empty) and are resolved from `BuiltInLastFM` at request time. Older stored credentials decode with the defaults.
    struct Credentials: Codable, Equatable, Sendable {
        var apiKey: String; var secret: String; var sessionKey: String
        var username: String = ""
        var usesBuiltInApp: Bool = false

        init(apiKey: String, secret: String, sessionKey: String, username: String = "", usesBuiltInApp: Bool = false) {
            self.apiKey = apiKey; self.secret = secret; self.sessionKey = sessionKey; self.username = username; self.usesBuiltInApp = usesBuiltInApp
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
            secret = try c.decodeIfPresent(String.self, forKey: .secret) ?? ""
            sessionKey = try c.decode(String.self, forKey: .sessionKey)
            username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
            usesBuiltInApp = try c.decodeIfPresent(Bool.self, forKey: .usesBuiltInApp) ?? false
        }

        /// The key and secret to sign with right now: the built-in application when the marker is set, otherwise the person's own.
        func resolvedKeys(builtIn: () -> (key: String, secret: String)? = LastFMKeys.builtIn) -> (key: String, secret: String)? {
            if usesBuiltInApp { return builtIn() }
            return apiKey.isEmpty || secret.isEmpty ? nil : (apiKey, secret)
        }
    }

    var info: MusicProviderInfo {
        MusicProviderInfo(
            id: "lastfm", name: "Last.fm", summary: "Records what you play on your own Last.fm profile, using your own API key.",
            requiresSignIn: true,
            privacyNote: "Your API key, secret and session key are kept in this device's Keychain. For each song you finish, its title, artist, album, length and the time you played it are sent to ws.audioscrobbler.com, signed with your secret (the secret itself is never sent). Nothing is sent unless scrobbling is on.",
            homepage: "https://www.last.fm/api")
    }
    var capabilities: MusicCapabilities { [.scrobble] }
    var isSignedIn: Bool { get async { credentials()?.resolvedKeys() != nil } }
    /// Without credentials this source is completely dormant: it makes no network call and raises no error. Settings shows this line instead.
    static let addKeyNote = "Add your key to start"
    var statusNote: String? { credentials()?.resolvedKeys() == nil ? Self.addKeyNote : nil }

    func signIn() async throws { throw MusicError.unsupported("Last.fm needs your own API key, secret and session key. Enter them in Settings.") }
    func signOut() async { store.remove(Self.credentialsAccount) }

    func setCredentials(apiKey: String, secret: String, sessionKey: String) async {
        let c = Credentials(apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                            secret: secret.trimmingCharacters(in: .whitespacesAndNewlines),
                            sessionKey: sessionKey.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !c.apiKey.isEmpty, !c.secret.isEmpty, !c.sessionKey.isEmpty, let d = try? JSONEncoder().encode(c) else {
            store.remove(Self.credentialsAccount); return
        }
        store.write(String(decoding: d, as: UTF8.self), account: Self.credentialsAccount)
    }

    private func credentials() -> Credentials? {
        store.read(Self.credentialsAccount).flatMap { try? JSONDecoder().decode(Credentials.self, from: Data($0.utf8)) }
    }

    func scrobble(_ s: MusicScrobble) async throws {
        var p = Self.trackFields(s.track)
        p["timestamp"] = String(Int(s.timestamp.timeIntervalSince1970))
        try await call("track.scrobble", p)
    }

    func nowPlaying(_ track: MusicTrack) async {
        try? await call("track.updateNowPlaying", Self.trackFields(track))
    }

    private func call(_ method: String, _ fields: [String: String]) async throws {
        guard let c = credentials(), let keys = c.resolvedKeys() else { throw MusicError.notSignedIn("Last.fm") }
        var p = fields
        p["method"] = method; p["api_key"] = keys.key; p["sk"] = c.sessionKey
        p["api_sig"] = Self.signature(p, secret: keys.secret)
        p["format"] = "json"
        let data = try await http.postForm(Self.endpoint, fields: p)
        if let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let code = d.int("error") {
            switch code {
            case 4, 9, 14, 26: throw MusicError.notSignedIn("Last.fm")
            case 29: throw MusicError.rateLimited(retryAfter: nil)
            default: throw MusicError.network(d.str("message") ?? "Last.fm error \(code)")
            }
        }
    }

    static func trackFields(_ t: MusicTrack) -> [String: String] {
        var p = ["artist": t.artists.first?.name ?? "", "track": t.title]
        if let a = t.album?.title, !a.isEmpty { p["album"] = a }
        if t.durationMs > 0 { p["duration"] = String(Int(t.durationMs / 1000)) }
        return p
    }

    /// Last.fm's request signature: parameters sorted by name, written as name then value with no separators, the secret added at the
    /// end, then MD5. `format` and `callback` are never part of it.
    static func signature(_ params: [String: String], secret: String) -> String {
        let body = params.filter { $0.key != "format" && $0.key != "callback" && $0.key != "api_sig" }
            .sorted { $0.key < $1.key }.map { $0.key + $0.value }.joined()
        return md5Hex(body + secret)
    }

    static func md5Hex(_ s: String) -> String {
        MusicHash.md5(s)
    }
}
