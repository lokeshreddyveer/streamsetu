import Foundation

/// YouTube Music: song search through the public InnerTube endpoint, plus audio for those songs.
/// Streams come from InnerTube clients. A format that only offers a `signatureCipher`, or whose URL carries a throttling `n` value, is solved by
/// `YouTubeSignatureService`; when that fails (YouTube changed its player script) those formats are skipped and the other providers take over.
struct YouTubeMusicProvider: MusicMetadataProvider, MusicAudioProvider {
    static let providerID = "youtube-music"
    let http: MusicHTTP
    let signature: YouTubeSignatureService

    init(http: MusicHTTP = MusicHTTP(), signature: YouTubeSignatureService? = nil) {
        self.http = http
        self.signature = signature ?? YouTubeSignatureService(http: http)
    }

    let info = MusicProviderInfo(
        id: YouTubeMusicProvider.providerID, name: "YouTube Music (basic)",
        summary: "Song search and audio from YouTube Music. No account needed.",
        privacyNote: "Google sees the text you search for, which songs you play, and your IP address, the same as using YouTube Music in a browser without signing in. Nothing is sent to Google unless this is switched on.",
        homepage: "https://music.youtube.com")
    var capabilities: MusicCapabilities { [.search, .tracks, .audio] }

    private static let searchURL = URL(string: "https://music.youtube.com/youtubei/v1/search?prettyPrint=false")
    private static let playerURL = URL(string: "https://music.youtube.com/youtubei/v1/player?prettyPrint=false")
    /// Filter parameter that limits a YouTube Music search to songs.
    private static let songsFilter = "EgWKAQIIAWoKEAkQBRAKEAMQBA=="
    /// The same search limited to videos: official videos and lyric videos of songs the song catalogue does not hold.
    private static let videosFilter = "EgWKAQIQAWoKEAMQBBAJEAoQBQ=="
    private static let webVersion = "1.20260213.01.00"
    private let visitor = YTMVisitorBootstrap()

    private struct PlayerClient: Sendable {
        var name: String; var version: String; var userAgent: String; var headerID: String; var extra: [String: String]; var sdk: Int? = nil
    }
    /// VISIONOS first (direct URLs, whole file), then IOS_PRODUCER as the fallback. IOS_PRODUCER serves the whole song and, unlike VISIONOS,
    /// still plays when the anonymous visitor id could not be fetched (a launch-time network blip), so a guest keeps playing. Plain IOS and the
    /// Android VR identity answer but their links stop working after the first MiB — and this provider does not range-probe before use — so they
    /// are deliberately left out here; the main engine keeps IOS behind its own whole-file probe. The identities track one shared table (an
    /// override file can update it), not private copies years out of date, which a bot check would notice.
    private static let playerClients: [PlayerClient] = {
        func client(_ id: YTMClientIdentity) -> PlayerClient {
            var extra: [String: String] = [:]
            if let v = id.deviceMake { extra["deviceMake"] = v }
            if let v = id.deviceModel { extra["deviceModel"] = v }
            if let v = id.osName { extra["osName"] = v }
            if let v = id.osVersion { extra["osVersion"] = v }
            return PlayerClient(name: id.clientName, version: id.clientVersion, userAgent: id.userAgent, headerID: id.clientID, extra: extra, sdk: id.androidSdkVersion)
        }
        return [client(YTMClientTable.builtIn[.visionOS]!), client(YTMClientTable.builtIn[.iosProducer]!)]
    }()

    // MARK: metadata (songs only)

    func searchTracks(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> {
        MusicPage(items: try await searchSongs(query))
    }

    func track(id: String) async throws -> MusicTrack { throw MusicError.unsupported("track lookup on YouTube Music") }

    private func searchSongs(_ query: String, filter: String? = nil) async throws -> [MusicTrack] {
        guard let url = Self.searchURL, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        var client: [String: Any] = ["clientName": "WEB_REMIX", "clientVersion": Self.webVersion, "hl": "en", "gl": "US"]
        let vid = await visitor.value(http: http, now: Date())
        if let vid { client["visitorData"] = vid }
        let body: [String: Any] = ["context": ["client": client], "query": query, "params": filter ?? Self.songsFilter]
        var headers = ["Origin": "https://music.youtube.com", "Referer": "https://music.youtube.com/"]
        if let vid { headers["X-Goog-Visitor-Id"] = vid }
        let data = try await http.postJSON(url, body: try JSONSerialization.data(withJSONObject: body), headers: headers)
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { throw MusicError.network("unexpected reply") }
        return Self.parseSongs(obj)
    }

    // MARK: audio

    func sources(for track: MusicTrack) async throws -> [MusicAudioSource] {
        if YouTubeBotGate.shared.isClosed { throw MusicError.rateLimited(retryAfter: YouTubeBotGate.shared.secondsLeft) }
        let q = YouTubeAudio.query(for: track)
        let songs = try await searchSongs(q)
        let candidates = songs.map {
            YouTubeCandidate(videoID: $0.id, title: $0.title, channel: $0.artists.first.map { a in a.name + " - Topic" },
                             durationMs: $0.durationMs > 0 ? $0.durationMs : nil, thumbnail: $0.thumbnails.first?.url)
        }
        // YouTube Music songs are the official audio uploads, so the channel is treated like a "Topic" channel.
        var ranked = YouTubeAudio.rank(candidates, for: track, providerID: Self.providerID)
        for i in ranked.indices { ranked[i].artist = songs.first { $0.id == ranked[i].id }?.artistLine ?? ranked[i].artist }
        // Not every song is in the song catalogue (a label may keep its new releases off it). When nothing there is good enough (no song whose title fits, however well its singer and length do), the official videos of the same name are
        // searched too, and judged by the same title, artist and length rules, so a promo, a cover or another song never takes its place.
        if !ranked.contains(where: { $0.confidence >= MusicStreamResolver.minimumScore && MusicTextMatch.titleFits(track.title, $0.title) }), let videos = try? await searchSongs(q, filter: Self.videosFilter), !videos.isEmpty {
            let more = videos.map {
                YouTubeCandidate(videoID: $0.id, title: $0.title, channel: $0.artists.first?.name, durationMs: $0.durationMs > 0 ? $0.durationMs : nil, thumbnail: $0.thumbnails.first?.url)
            }
            var extra = YouTubeAudio.rank(more, for: track, providerID: Self.providerID)
            for i in extra.indices { extra[i].artist = videos.first { $0.id == extra[i].id }?.artistLine ?? extra[i].artist }
            ranked = Array((ranked + extra).sorted { $0.confidence > $1.confidence }.prefix(6))
        }
        return ranked
    }

    func streams(for source: MusicAudioSource) async throws -> [MusicStream] {
        if let s = source.streams, !s.isEmpty { return s }
        guard let url = Self.playerURL, source.id.range(of: "^[A-Za-z0-9_-]{6,20}$", options: .regularExpression) != nil else { throw MusicError.notFound }
        if YouTubeBotGate.shared.isClosed { throw MusicError.rateLimited(retryAfter: YouTubeBotGate.shared.secondsLeft) }
        // The visitor id is what makes VISIONOS play as a guest; a request without it is refused for a missing identity, not a real bot block.
        let hadVisitor = await visitor.value(http: http, now: Date()) != nil
        for client in Self.playerClients {
            let timestamp = await signature.cachedTimestamp()
            guard var obj = await requestPlayer(url, client: client, videoID: source.id, timestamp: timestamp) else { continue }
            // YouTube's "confirm you're not a bot" answer is counted only when a visitor id was sent; otherwise it is a missing-identity refusal
            // (a failed bootstrap), which must not close the gate and stop the lookups that work once the visitor id is back.
            if hadVisitor {
                YouTubeBotGate.shared.observe(obj, videoID: source.id)
                if YouTubeBotGate.shared.isClosed { throw MusicError.rateLimited(retryAfter: YouTubeBotGate.shared.secondsLeft) }
            }
            var formats = Self.rawFormats(obj)
            // A ciphered reply must be paired with the player version that solves it, so ask again with that version's timestamp.
            if timestamp == nil, formats.contains(where: { $0.cipher != nil }), let ts = await signature.signatureTimestamp() {
                if let again = await requestPlayer(url, client: client, videoID: source.id, timestamp: ts) { obj = again; formats = Self.rawFormats(again) }
            }
            let list = await resolve(formats, headers: ["User-Agent": client.userAgent])
            if !list.isEmpty { YouTubeBotGate.shared.reset(); return list }
        }
        throw MusicError.noPlayableSource(source.title)
    }

    private func requestPlayer(_ url: URL, client: PlayerClient, videoID: String, timestamp: Int?) async -> Any? {
        await YouTubeRequestPacer.shared.wait()
        var ctx: [String: Any] = ["clientName": client.name, "clientVersion": client.version, "hl": "en", "gl": "US"]
        let vid = await visitor.value(http: http, now: Date())
        if let vid { ctx["visitorData"] = vid }
        for (k, v) in client.extra { ctx[k] = v }
        if let sdk = client.sdk { ctx["androidSdkVersion"] = sdk }
        var body: [String: Any] = ["context": ["client": ctx], "videoId": videoID, "contentCheckOk": true, "racyCheckOk": true]
        if let timestamp { body["playbackContext"] = ["contentPlaybackContext": ["signatureTimestamp": timestamp]] }
        var headers = ["User-Agent": client.userAgent, "X-YouTube-Client-Name": client.headerID, "X-YouTube-Client-Version": client.version,
                       "Origin": "https://music.youtube.com", "Referer": "https://music.youtube.com/"]
        if let vid { headers["X-Goog-Visitor-Id"] = vid }
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let raw = try? await http.postJSON(url, body: data, headers: headers) else { return nil }
        return try? JSONSerialization.jsonObject(with: raw)
    }

    /// Turns raw formats into streams: direct URLs get the throttling fix, ciphered ones are solved. A format that cannot be solved is dropped.
    private func resolve(_ formats: [RawFormat], headers: [String: String]) async -> [MusicStream] {
        var out: [MusicStream] = []
        for f in formats {
            guard f.mime.lowercased().hasPrefix("audio/") else { continue }
            guard let finalURL = try? await signature.playableURL(url: f.cipher == nil ? f.url : nil, cipher: f.cipher) else { continue }
            if let s = YouTubeAudio.stream(url: finalURL, mimeType: f.mime, bitrateBps: f.bitrate, sampleRate: f.sampleRate, headers: headers) { out.append(s) }
        }
        return YouTubeAudio.sortedByBitrate(out)
    }

    // MARK: parsing

    struct RawFormat: Sendable, Equatable {
        var url: String?; var cipher: String?; var mime: String; var bitrate: Int?; var sampleRate: Int?
    }

    /// Every adaptive format with a mime type and either a plain URL or a cipher.
    static func rawFormats(_ obj: Any) -> [RawFormat] {
        guard let root = obj as? [String: Any], let sd = root.dict("streamingData") else { return [] }
        return sd.array("adaptiveFormats").compactMap { f in
            guard let mime = f.str("mimeType") else { return nil }
            let url = f.str("url"), cipher = f.str("signatureCipher") ?? f.str("cipher")
            guard url != nil || cipher != nil else { return nil }
            return RawFormat(url: url, cipher: cipher, mime: mime, bitrate: f.int("averageBitrate") ?? f.int("bitrate"), sampleRate: f.int("audioSampleRate"))
        }
    }

    static func parseSongs(_ obj: Any) -> [MusicTrack] {
        var items: [[String: Any]] = []
        collect("musicResponsiveListItemRenderer", in: obj, into: &items)
        return items.compactMap(song)
    }

    /// Finds every value stored under `key`, however deep, so small layout changes on YouTube's side do not break parsing.
    private static func collect(_ key: String, in node: Any, into out: inout [[String: Any]], depth: Int = 0) {
        guard depth < 24 else { return }
        if let d = node as? [String: Any] {
            for (k, v) in d {
                if k == key, let m = v as? [String: Any] { out.append(m) } else { collect(key, in: v, into: &out, depth: depth + 1) }
            }
        } else if let a = node as? [Any] {
            for v in a { collect(key, in: v, into: &out, depth: depth + 1) }
        }
    }

    private static func runs(_ column: [String: Any]) -> [[String: Any]] {
        column.dict("musicResponsiveListItemFlexColumnRenderer")?.dict("text")?.array("runs") ?? []
    }

    private static func song(_ item: [String: Any]) -> MusicTrack? {
        let columns = item.array("flexColumns").map(runs)
        guard let titleRuns = columns.first, let title = titleRuns.first?.str("text") else { return nil }
        let videoID = item.dict("playlistItemData")?.str("videoId")
            ?? titleRuns.compactMap({ $0.dict("navigationEndpoint")?.dict("watchEndpoint")?.str("videoId") }).first
        guard let videoID else { return nil }

        var artists: [MusicArtistRef] = []
        var album: MusicAlbumRef?
        var durationMs: Int64 = 0
        var loose: [String] = []
        let skip: Set<String> = ["\u{2022}", "&", ",", "Song", "Video", "Single", "EP", "Album"]
        for col in columns.dropFirst() {
            for run in col {
                let text = (run.str("text") ?? "").trimmingCharacters(in: .whitespaces)
                let browse = run.dict("navigationEndpoint")?.dict("browseEndpoint")?.str("browseId") ?? ""
                if browse.hasPrefix("MPRE") { album = MusicAlbumRef(id: browse, title: text) }
                else if browse.hasPrefix("UC") { artists.append(MusicArtistRef(id: browse, name: text)) }
                else if let ms = YouTubeAudio.clock(text) { durationMs = ms }
                else if !text.isEmpty, !skip.contains(text) { loose.append(text) }
            }
        }
        if artists.isEmpty, let first = loose.first { artists = [MusicArtistRef(id: first, name: first)] }

        let thumbs = (item.dict("thumbnail")?.dict("musicThumbnailRenderer")?.dict("thumbnail")?.array("thumbnails") ?? []).compactMap { t -> MusicThumbnail? in
            guard let u = t.str("url") else { return nil }
            return MusicThumbnail(url: u, width: t.int("width") ?? 0, height: t.int("height") ?? 0)
        }
        // The search is filtered to songs, so none of these rows is a music video.
        var track = MusicTrack(id: videoID, providerID: providerID, title: title, durationMs: durationMs, artists: artists, album: album, thumbnails: thumbs,
                               externalURL: "https://music.youtube.com/watch?v=\(videoID)")
        track.isVideo = false
        return track
    }

    static func parseStreams(_ obj: Any, headers: [String: String]) -> [MusicStream] {
        guard let root = obj as? [String: Any], let sd = root.dict("streamingData") else { return [] }
        let formats = sd.array("adaptiveFormats")
        let out: [MusicStream] = formats.compactMap { f in
            // Plain-URL formats only; ciphered ones go through `rawFormats` and the signature service.
            guard let url = f.str("url"), let mime = f.str("mimeType") else { return nil }
            return YouTubeAudio.stream(url: url, mimeType: mime, bitrateBps: f.int("averageBitrate") ?? f.int("bitrate"),
                                       sampleRate: f.int("audioSampleRate"), headers: headers)
        }
        return YouTubeAudio.sortedByBitrate(out)
    }
}
