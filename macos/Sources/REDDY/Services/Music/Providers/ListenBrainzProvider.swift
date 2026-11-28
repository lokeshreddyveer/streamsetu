import Foundation
import Security

/// Where a scrobbling service keeps the person's own secrets. The real one is the Keychain; tests use memory.
protocol ScrobbleSecretStore: Sendable {
    func read(_ account: String) -> String?
    func write(_ value: String, account: String)
    func remove(_ account: String)
}

struct ScrobbleKeychainStore: ScrobbleSecretStore {
    static let service = MusicKeychain.service
    func read(_ account: String) -> String? { MusicKeychain.shared.read(account) }
    func write(_ value: String, account: String) { MusicKeychain.shared.write(account, value) }
    func remove(_ account: String) { MusicKeychain.shared.remove(account) }
}

/// ListenBrainz: an open scrobbling service. The person pastes their user token (from listenbrainz.org/settings) once.
struct ListenBrainzProvider: MusicScrobbleProvider {
    static let root = URL(string: "https://api.listenbrainz.org/1")!
    static let tokenAccount = "listenbrainz.token"
    private let http: MusicHTTP
    private let store: any ScrobbleSecretStore

    init(http: MusicHTTP = MusicHTTP(), store: any ScrobbleSecretStore = ScrobbleKeychainStore()) {
        self.http = http; self.store = store
    }

    var info: MusicProviderInfo {
        MusicProviderInfo(
            id: "listenbrainz", name: "ListenBrainz", summary: "Open source listening history. Records what you play on your own ListenBrainz profile.",
            requiresSignIn: true,
            privacyNote: "Your ListenBrainz token is kept in this device's Keychain. For each song you finish, its title, artist, album, length and the time you played it are sent to api.listenbrainz.org with your token, and the song now playing is sent while it plays. Nothing is sent unless scrobbling is on.",
            homepage: "https://listenbrainz.org")
    }
    var capabilities: MusicCapabilities { [.scrobble] }
    var isSignedIn: Bool { get async { store.read(Self.tokenAccount) != nil } }
    /// Without a token this source is completely dormant: it makes no network call and raises no error. Settings shows this line instead.
    static let addKeyNote = "Add your key to start"
    var statusNote: String? { store.read(Self.tokenAccount) == nil ? Self.addKeyNote : nil }

    func signIn() async throws { throw MusicError.unsupported("ListenBrainz needs your user token. Paste it in Settings.") }
    func signOut() async { store.remove(Self.tokenAccount) }

    /// Checks the token with the service before keeping it.
    func setToken(_ token: String) async throws {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw MusicError.notSignedIn("ListenBrainz") }
        let data = try await http.get(Self.root.appendingPathComponent("validate-token"), headers: Self.auth(t))
        let valid = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["valid"] as? Bool ?? false
        guard valid else { throw MusicError.notSignedIn("ListenBrainz") }
        store.write(t, account: Self.tokenAccount)
    }

    func scrobble(_ s: MusicScrobble) async throws {
        try await submit(Self.payload(listenType: "single", track: s.track, listenedAt: s.timestamp, playedMs: s.playedMs))
    }

    func nowPlaying(_ track: MusicTrack) async {
        try? await submit(Self.payload(listenType: "playing_now", track: track, listenedAt: nil, playedMs: nil))
    }

    private func submit(_ body: Data) async throws {
        guard let token = store.read(Self.tokenAccount) else { throw MusicError.notSignedIn("ListenBrainz") }
        _ = try await http.postJSON(Self.root.appendingPathComponent("submit-listens"), body: body, headers: Self.auth(token))
    }

    private static func auth(_ token: String) -> [String: String] { ["Authorization": "Token " + token] }

    /// The submit-listens body. `playing_now` carries no timestamp, as the service requires.
    static func payload(listenType: String, track: MusicTrack, listenedAt: Date?, playedMs: Int64?) -> Data {
        var meta: [String: Any] = [
            "artist_name": track.artists.map(\.name).joined(separator: ", "),
            "track_name": track.title,
        ]
        if let album = track.album?.title, !album.isEmpty { meta["release_name"] = album }
        var extra: [String: Any] = ["media_player": "StreamSetu", "submission_client": "StreamSetu"]
        if track.durationMs > 0 { extra["duration_ms"] = track.durationMs }
        if let isrc = track.isrc, !isrc.isEmpty { extra["isrc"] = isrc }
        meta["additional_info"] = extra
        var listen: [String: Any] = ["track_metadata": meta]
        if let at = listenedAt { listen["listened_at"] = Int(at.timeIntervalSince1970) }
        let obj: [String: Any] = ["listen_type": listenType, "payload": [listen]]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}
