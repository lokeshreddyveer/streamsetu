import Foundation

/// Why ListenBrainz is refusing listens even though the token checked out.
enum ListenBrainzProblem: String, Sendable, Equatable {
    case email, rejected
    var message: String {
        switch self {
        case .email: "Verify your MetaBrainz email so ListenBrainz accepts your listens."
        case .rejected: "ListenBrainz no longer accepts this token. Connect again with a new one."
        }
    }
}

struct ListenBrainzClient: Sendable {
    static let defaultRoot = "https://api.listenbrainz.org"
    static let tokenAccount = ListenBrainzProvider.tokenAccount
    static let urlAccount = "listenbrainz.url"
    static let usernameAccount = "listenbrainz.username"
    static let badServerText = "server URL must be http(s)://host[/path], without ? or #"

    var http: MusicHTTP = MusicHTTP()
    var store: any ScrobbleSecretStore = ScrobbleKeychainStore()
    var clientVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"

    // MARK: stored state

    var token: String? { store.read(Self.tokenAccount) }
    var username: String? { store.read(Self.usernameAccount) }
    var isConnected: Bool { token != nil }
    var root: URL { store.read(Self.urlAccount).flatMap { URL(string: $0) } ?? URL(string: Self.defaultRoot)! }

    func disconnect() { [Self.tokenAccount, Self.urlAccount, Self.usernameAccount].forEach(store.remove) }

    /// Empty means the official server. A custom address is trimmed, loses trailing slashes, and must be http(s) with a host and no query or fragment.
    static func normalizedRoot(_ text: String) -> Result<URL, ScrobbleSendError> {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .success(URL(string: defaultRoot)!) }
        var s = t
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty, let c = URLComponents(string: s), let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host, !host.isEmpty, c.query == nil, c.fragment == nil, !s.contains("?"), !s.contains("#"), let url = c.url
        else { return .failure(.refused(badServerText)) }
        return .success(url)
    }

    static func endpoint(_ root: URL, _ path: String) -> URL { URL(string: root.absoluteString + "/1/" + path) ?? root }

    // MARK: connect

    /// Checks the token against the server and keeps token, username and server together. Nothing is stored on an error.
    @discardableResult
    func connect(token rawToken: String, server: String) async throws -> String {
        let t = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw ScrobbleSendError.refused("Paste your ListenBrainz user token first.") }
        let root: URL
        switch Self.normalizedRoot(server) { case .success(let u): root = u; case .failure(let e): throw e }
        let r = try await ScrobbleHTTP.send(http, url: Self.endpoint(root, "validate-token"), method: "GET", headers: ["Authorization": "Token " + t])
        guard let obj = (try? JSONSerialization.jsonObject(with: r.data)) as? [String: Any] else {
            throw ScrobbleSendError.refused("no ListenBrainz API answered at \(root.absoluteString) (is this the API address?)")
        }
        guard r.status == 200 || r.status == 401 else { throw ScrobbleSendError.refused("ListenBrainz answered HTTP \(r.status)") }
        guard (obj["valid"] as? Bool) == true else { throw ScrobbleSendError.refused(obj.str("message") ?? "ListenBrainz does not accept this token.") }
        guard let user = obj.str("user_name") else { throw ScrobbleSendError.refused("ListenBrainz did not say whose token this is.") }
        store.write(t, account: Self.tokenAccount)
        store.write(user, account: Self.usernameAccount)
        store.write(root.absoluteString, account: Self.urlAccount)
        return user
    }

    func listenCount(user: String) async -> Int? {
        guard let r = try? await ScrobbleHTTP.send(http, url: Self.endpoint(root, "user/\(user)/listen-count"), method: "GET"),
              let o = (try? JSONSerialization.jsonObject(with: r.data)) as? [String: Any] else { return nil }
        return o.dict("payload")?.int("count")
    }

    func profileURL(user: String) -> URL? {
        let r = root.absoluteString
        return URL(string: r == Self.defaultRoot ? "https://listenbrainz.org/user/\(user)/" : "\(r)/user/\(user)/")
    }

    // MARK: send

    func playingNow(_ t: ScrobblePayloadTrack) async throws { try await submit(Self.payload(listenType: "playing_now", t, listenedAt: nil, version: clientVersion)) }
    func listen(_ t: ScrobblePayloadTrack, start: Date) async throws { try await submit(Self.payload(listenType: "single", t, listenedAt: start, version: clientVersion)) }

    private func submit(_ body: Data) async throws {
        guard let token else { throw ScrobbleSendError.signedOut }
        let r = try await ScrobbleHTTP.send(http, url: Self.endpoint(root, "submit-listens"), method: "POST",
                                            headers: ["Authorization": "Token " + token, "Content-Type": "application/json"], body: body)
        switch r.status {
        case 200..<300: return
        case 401: throw ScrobbleSendError.listenBrainz(Self.classify401(body: r.data))
        case 429, 500...599: throw ScrobbleSendError.network("ListenBrainz answered HTTP \(r.status)")
        default: throw ScrobbleSendError.refused("ListenBrainz answered HTTP \(r.status)")
        }
    }

    /// Only the English body text tells the two 401 cases apart; if the wording changes the email case degrades to "rejected".
    static func classify401(body: Data) -> ListenBrainzProblem {
        String(decoding: body, as: UTF8.self).localizedCaseInsensitiveContains("verified email") ? .email : .rejected
    }

    /// The submit-listens body, written by a real JSON encoder. A playing-now listen carries no timestamp. Local files carry no service or address.
    static func payload(listenType: String, _ t: ScrobblePayloadTrack, listenedAt: Date?, version: String) -> Data {
        var info = Submission.Listen.Meta.Info(media_player: "StreamSetu", submission_client: "StreamSetu", submission_client_version: version)
        if t.durationMs > 0 { info.duration_ms = t.durationMs }
        if let isrc = t.isrc, !isrc.isEmpty { info.isrc = isrc }
        if let o = t.originURL, let u = URL(string: o), let host = u.host, u.scheme == "https" || u.scheme == "http" {
            info.music_service = host; info.origin_url = o
        }
        let meta = Submission.Listen.Meta(artist_name: t.artist, track_name: t.title, release_name: t.album.isEmpty ? nil : t.album, additional_info: info)
        let body = Submission(listen_type: listenType, payload: [Submission.Listen(listened_at: listenedAt.map { Int($0.timeIntervalSince1970) }, track_metadata: meta)])
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(body)) ?? Data("{}".utf8)
    }

    /// The wire shape of submit-listens. Optional fields that are nil are left out of the JSON.
    struct Submission: Encodable {
        struct Listen: Encodable {
            struct Meta: Encodable {
                struct Info: Encodable {
                    var media_player: String
                    var submission_client: String
                    var submission_client_version: String
                    var duration_ms: Int64?
                    var isrc: String?
                    var music_service: String?
                    var origin_url: String?
                }
                var artist_name: String
                var track_name: String
                var release_name: String?
                var additional_info: Info
            }
            var listened_at: Int?
            var track_metadata: Meta
        }
        var listen_type: String
        var payload: [Listen]
    }
}

/// The cleaned values plus the few extra facts each service payload uses.
struct ScrobblePayloadTrack: Sendable, Equatable {
    var artist: String
    var title: String
    var album: String
    var durationMs: Int64
    var isrc: String?
    var originURL: String?
}
