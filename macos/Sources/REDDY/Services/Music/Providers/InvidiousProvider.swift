import Foundation

/// Audio from YouTube through public Invidious servers (a second route when Piped servers are down).
struct InvidiousProvider: MusicAudioProvider {
    static let providerID = "invidious"
    let http: MusicHTTP
    let instances: YouTubeInstances

    init(http: MusicHTTP = MusicHTTP(), instances: YouTubeInstances? = nil) {
        self.http = http
        self.instances = instances ?? YouTubeInstances(http: http)
    }

    let info = MusicProviderInfo(
        id: InvidiousProvider.providerID, name: "Invidious (YouTube audio)",
        summary: "Finds the song on YouTube through a public Invidious server and plays its audio.",
        privacyNote: "A public Invidious server sees the song name you search for and your IP address, and the audio is streamed through that server. Servers are run by volunteers and can be slow or go offline; the app tries the next one.",
        homepage: "https://invidious.io")
    var capabilities: MusicCapabilities { [.audio] }

    func sources(for track: MusicTrack) async throws -> [MusicAudioSource] {
        let q = YouTubeAudio.query(for: track)
        let http = self.http
        let found: [YouTubeCandidate] = try await instances.perform(.invidious) { base in
            let url = base.appendingPathComponent("api/v1/search")
            let obj = try await http.getObject(url, query: ["q": q, "type": "video", "sort_by": "relevance"])
            return Self.parseSearch(obj)
        }
        return YouTubeAudio.rank(found, for: track, providerID: Self.providerID)
    }

    func streams(for source: MusicAudioSource) async throws -> [MusicStream] {
        if let s = source.streams, !s.isEmpty { return s }
        let id = source.id
        guard id.range(of: "^[A-Za-z0-9_-]{6,20}$", options: .regularExpression) != nil else { throw MusicError.notFound }
        let http = self.http
        let list: [MusicStream] = try await instances.perform(.invidious) { base in
            // local=true makes the server proxy the media; direct Google links are tied to the server's address and would not play here.
            let obj = try await http.getObject(base.appendingPathComponent("api/v1/videos").appendingPathComponent(id), query: ["local": "true"])
            return Self.parseStreams(obj, base: base)
        }
        if list.isEmpty { throw MusicError.noPlayableSource(source.title) }
        return list
    }

    // MARK: parsing

    static func parseSearch(_ obj: Any) -> [YouTubeCandidate] {
        let rows = (obj as? [[String: Any]]) ?? []
        return rows.compactMap { r in
            if let t = r.str("type"), t != "video" { return nil }
            guard let id = r.str("videoId"), let title = r.str("title") else { return nil }
            let secs = r.int("lengthSeconds") ?? 0
            let thumbs = r.array("videoThumbnails")
            let thumb = thumbs.first { $0.str("quality") == "medium" }?.str("url") ?? thumbs.first?.str("url")
            return YouTubeCandidate(videoID: id, title: title, channel: r.str("author"), durationMs: secs > 0 ? Int64(secs) * 1000 : nil, thumbnail: thumb)
        }
    }

    static func parseStreams(_ obj: Any, base: URL) -> [MusicStream] {
        guard let root = obj as? [String: Any] else { return [] }
        let out: [MusicStream] = root.array("adaptiveFormats").compactMap { f in
            guard var url = f.str("url"), let type = f.str("type") else { return nil }
            if url.hasPrefix("/") { url = base.absoluteString + url }
            return YouTubeAudio.stream(url: url, mimeType: type, bitrateBps: f.int("bitrate"), sampleRate: f.int("audioSampleRate"))
        }
        return YouTubeAudio.sortedByBitrate(out)
    }
}
