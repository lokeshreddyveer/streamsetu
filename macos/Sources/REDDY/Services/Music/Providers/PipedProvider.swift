import Foundation

/// Audio from YouTube through public Piped servers. Piped does the extraction, so the app never talks to Google directly.
struct PipedProvider: MusicAudioProvider {
    static let providerID = "piped"
    let http: MusicHTTP
    let instances: YouTubeInstances

    init(http: MusicHTTP = MusicHTTP(), instances: YouTubeInstances? = nil) {
        self.http = http
        self.instances = instances ?? YouTubeInstances(http: http)
    }

    let info = MusicProviderInfo(
        id: PipedProvider.providerID, name: "Piped (YouTube audio)",
        summary: "Finds the song on YouTube Music through a public Piped server and plays its audio.",
        privacyNote: "A public Piped server sees the song name you search for and your IP address, and the audio is fetched through it or from Google. Servers are run by volunteers and can be slow or go offline; the app tries the next one.",
        homepage: "https://github.com/TeamPiped/Piped")
    var capabilities: MusicCapabilities { [.audio] }

    func sources(for track: MusicTrack) async throws -> [MusicAudioSource] {
        let q = YouTubeAudio.query(for: track)
        let http = self.http
        let found: [YouTubeCandidate] = try await instances.perform(.piped) { base in
            let songs = Self.parseSearch(try await http.getObject(base.appendingPathComponent("search"), query: ["q": q, "filter": "music_songs"]))
            if !songs.isEmpty { return songs }
            // Some servers have no music index; their plain video search still finds the upload.
            return Self.parseSearch(try await http.getObject(base.appendingPathComponent("search"), query: ["q": q, "filter": "videos"]))
        }
        return YouTubeAudio.rank(found, for: track, providerID: Self.providerID)
    }

    func streams(for source: MusicAudioSource) async throws -> [MusicStream] {
        if let s = source.streams, !s.isEmpty { return s }
        let id = source.id
        guard id.range(of: "^[A-Za-z0-9_-]{6,20}$", options: .regularExpression) != nil else { throw MusicError.notFound }
        let http = self.http
        let list: [MusicStream] = try await instances.perform(.piped) { base in
            let obj = try await http.getObject(base.appendingPathComponent("streams").appendingPathComponent(id))
            return Self.parseStreams(obj)
        }
        if list.isEmpty { throw MusicError.noPlayableSource(source.title) }
        return list
    }

    // MARK: parsing

    static func parseSearch(_ obj: Any) -> [YouTubeCandidate] {
        guard let root = obj as? [String: Any] else { return [] }
        return root.array("items").compactMap { item in
            guard let url = item.str("url"), let id = YouTubeAudio.videoID(fromWatchPath: url), let title = item.str("title") else { return nil }
            let secs = item.int("duration") ?? -1
            return YouTubeCandidate(videoID: id, title: title, channel: item.str("uploaderName"),
                                    durationMs: secs > 0 ? Int64(secs) * 1000 : nil, thumbnail: item.str("thumbnail"))
        }
    }

    static func parseStreams(_ obj: Any) -> [MusicStream] {
        guard let root = obj as? [String: Any] else { return [] }
        let out: [MusicStream] = root.array("audioStreams").compactMap { s in
            if (s["videoOnly"] as? Bool) == true { return nil }
            guard let url = s.str("url") else { return nil }
            var mime = s.str("mimeType") ?? ""
            if !mime.lowercased().hasPrefix("audio/") {
                // Some servers leave mimeType empty and only say "M4A" or "WEBMA".
                switch (s.str("format") ?? "").uppercased() {
                case "M4A": mime = "audio/mp4; codecs=\"mp4a.40.2\""
                case "WEBMA", "WEBMA_OPUS": mime = "audio/webm; codecs=\"opus\""
                default: return nil
                }
            }
            return YouTubeAudio.stream(url: url, mimeType: mime, bitrateBps: s.int("bitrate"))
        }
        return YouTubeAudio.sortedByBitrate(out)
    }
}
