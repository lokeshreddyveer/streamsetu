import Foundation

/// Audius's trending tracks, straight from its public API host. Tracks keep the `audius` provider id so a play goes to the Audius audio source.
struct AudiusTrendingDiscoveryProvider: MusicMetadataProvider {
    static let id = "discover-audius"
    static let endpoint = URL(string: "https://api.audius.co/v1/tracks/trending")!
    private let http: MusicHTTP
    init(http: MusicHTTP = MusicHTTP()) { self.http = http }

    var info: MusicProviderInfo {
        .discovery(id: Self.id, name: "Audius trending", summary: "Tracks climbing the charts on Audius, made by independent artists.", host: "api.audius.co")
    }
    var capabilities: MusicCapabilities { [.browse, .catalogue] }

    func featured() async throws -> [MusicBrowseSection] {
        let obj = try await http.getObject(Self.endpoint, query: ["app_name": AudiusProvider.appName, "limit": "25", "time": "week"])
        let tracks = Self.tracks(obj)
        if tracks.isEmpty { throw MusicError.notFound }
        return [MusicBrowseSection(id: "audius-trending-week", title: "Trending now", items: tracks.map { .track($0) }, scope: .global)]
    }

    static func tracks(_ obj: Any?) -> [MusicTrack] {
        ((obj as? [String: Any])?.array("data") ?? []).compactMap { d in
            guard let id = d.str("id"), let title = d.str("title") else { return nil }
            if (d["is_delete"] as? Bool) == true || (d["is_streamable"] as? Bool) == false { return nil }
            let user = d.dict("user") ?? [:]
            let artist = MusicArtistRef(id: user.str("id") ?? "", name: user.str("name") ?? user.str("handle") ?? Localized.string("Unknown artist"), thumbnails: sizes(user.dict("profile_picture")))
            var art = sizes(d.dict("artwork"))
            if art.isEmpty { art = artist.thumbnails }
            return MusicTrack(id: id, providerID: "audius", title: title, durationMs: Int64(d.int("duration") ?? 0) * 1000,
                              artists: [artist], thumbnails: art, popularity: d.int("play_count"),
                              externalURL: d.str("permalink").map { "https://audius.co" + $0 })
        }
    }

    private static func sizes(_ d: [String: Any]?) -> [MusicThumbnail] {
        guard let d else { return [] }
        return d.compactMap { k, v -> MusicThumbnail? in
            guard let u = v as? String, u.hasPrefix("http"), let w = k.split(separator: "x").first.flatMap({ Int($0) }) else { return nil }
            return MusicThumbnail(url: u, width: w, height: w)
        }.sorted { $0.width < $1.width }
    }
}
