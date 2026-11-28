import Foundation

// Watch history. YouTube Music records a play when the app reports it: one GET to the playback-tracking address the player answer carries.
// Nothing is sent unless the person switched this on AND an account is signed in.

enum YTMHistoryPing {
    /// The position after which a play counts: half the track, at most 30 seconds; 30 seconds when the length is unknown or about a second.
    static func threshold(durationSeconds: Double) -> Double {
        durationSeconds > 1 ? min(durationSeconds / 2, 30) : 30
    }

    /// True the first time the position reaches the threshold in a play. `sent` is the per-play latch: it is set even if the ping later fails.
    static func shouldPing(position: Double, durationSeconds: Double, sent: Bool) -> Bool {
        !sent && position >= threshold(durationSeconds: durationSeconds)
    }

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    /// A fresh 16 character content-playback nonce for one play. It only has to be unique.
    static func makeCPN<G: RandomNumberGenerator>(using g: inout G) -> String {
        String((0..<16).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &g)] })
    }
    static func makeCPN() -> String { var g = SystemRandomNumberGenerator(); return makeCPN(using: &g) }

    /// The tracking address from a `/player` answer.
    static func baseURL(inPlayerResponse root: Any?) -> String? {
        guard let d = root as? [String: Any] else { return nil }
        return d.dict("playbackTracking")?.dict("videostatsPlaybackUrl")?.str("baseUrl")
    }

    /// The ping request. The base may already hold a query, so parameters chain with `&`. A brand channel goes to music.youtube.com with
    /// `X-Goog-PageId`, because a GET cannot carry the delegated id in a body.
    static func request(baseURL: String, clientName: String, cpn: String, playlistID: String? = nil, pageID: String?) -> (url: URL, extraHeaders: [String: String])? {
        guard var comps = URLComponents(string: baseURL) else { return nil }
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "c", value: clientName))
        items.append(URLQueryItem(name: "cpn", value: cpn))
        items.append(URLQueryItem(name: "ver", value: "2"))
        if let playlistID, !playlistID.isEmpty {
            items.append(URLQueryItem(name: "list", value: playlistID))
            items.append(URLQueryItem(name: "referrer", value: playlistID))
        }
        comps.queryItems = items
        var headers: [String: String] = [:]
        if let pageID, !pageID.isEmpty {
            headers["X-Goog-PageId"] = pageID
            if comps.host == "s.youtube.com" { comps.host = "music.youtube.com" }
        }
        guard let url = comps.url, url.scheme == "https" else { return nil }
        return (url, headers)
    }
}

/// Reports plays to the signed-in account's history. One latch per play.
@MainActor
final class YTMHistoryReporter {
    static let defaultsKey = "music.ytm.history"

    private let client: YouTubeMusicClient
    private let defaults: UserDefaults
    private var currentVideoID: String?
    private var sent = false
    private var cpn = YTMHistoryPing.makeCPN()
    private var inFlight = false

    init(client: YouTubeMusicClient, defaults: UserDefaults = .standard) { self.client = client; self.defaults = defaults }

    /// Off until the person turns it on.
    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.defaultsKey) }
        set { defaults.set(newValue, forKey: Self.defaultsKey) }
    }

    /// A new play begins: the latch and the nonce reset.
    func begin(videoID: String) {
        currentVideoID = videoID
        sent = false
        cpn = YTMHistoryPing.makeCPN()
    }

    /// Feed the playing position. Sends at most one ping per play.
    func progress(videoID: String, position: Double, durationSeconds: Double, playlistID: String? = nil) async {
        if currentVideoID != videoID { begin(videoID: videoID) }
        guard isEnabled, YTMHistoryPing.shouldPing(position: position, durationSeconds: durationSeconds, sent: sent), !inFlight else { return }
        sent = true   // latched even when the ping fails
        inFlight = true
        defer { inFlight = false }
        await send(videoID: videoID, playlistID: playlistID)
    }

    func send(videoID: String, playlistID: String?) async {
        await YTMHistorySender(client: client).send(videoID: videoID, cpn: cpn, playlistID: playlistID)
    }
}

struct YTMHistorySender: Sendable {
    let client: YouTubeMusicClient

    func send(videoID: String, cpn: String, playlistID: String?) async {
        guard await client.isSignedIn else { return }
        let snap = await client.session.snapshot()
        guard let resp = try? await client.player(videoID: videoID, client: .webRemix, signatureTimestamp: nil, poToken: nil),
              let base = YTMHistoryPing.baseURL(inPlayerResponse: resp.root) else { return }
        let identity = client.identity(.webRemix)
        guard let ping = YTMHistoryPing.request(baseURL: base, clientName: identity.clientName, cpn: cpn, playlistID: playlistID, pageID: snap.pageID) else { return }
        var headers = YTMContext.headers(client: identity, locale: client.locale, session: snap, now: client.now())
        for (k, v) in ping.extraHeaders { headers[k] = v }
        _ = try? await client.http.get(ping.url, headers: headers)
    }
}

/// Lets the existing scrobbler send the history ping: it is just another place a finished play is reported. Off until switched on.
struct YouTubeMusicHistoryProvider: MusicScrobbleProvider {
    let client: YouTubeMusicClient
    let info = MusicProviderInfo(
        id: "ytmusic-history", name: "YouTube Music history",
        summary: "Adds songs you play to your YouTube Music account's history, which also tunes its recommendations.",
        requiresSignIn: true,
        privacyNote: "Tells Google which songs you played, under your account. Needs a YouTube Music sign-in.",
        homepage: "https://music.youtube.com")
    var capabilities: MusicCapabilities { [.scrobble] }
    var isSignedIn: Bool { get async { await client.isSignedIn } }

    func scrobble(_ s: MusicScrobble) async throws {
        guard s.track.providerID == YTM.providerID, await client.isSignedIn else { return }
        let vid = s.track.videoID ?? s.track.id
        let seconds = Double(s.track.durationMs) / 1000
        guard YTMHistoryPing.shouldPing(position: Double(s.playedMs) / 1000, durationSeconds: seconds, sent: false) else { return }
        await YTMHistorySender(client: client).send(videoID: vid, cpn: YTMHistoryPing.makeCPN(), playlistID: nil)
    }
}
