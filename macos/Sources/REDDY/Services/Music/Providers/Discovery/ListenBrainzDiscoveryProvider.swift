import Foundation

/// New releases this week from ListenBrainz's public explore list. Covers come from the Cover Art Archive; the track list of an album comes
/// from MusicBrainz when the card is opened. No token, no account.
struct ListenBrainzDiscoveryProvider: MusicMetadataProvider {
    static let id = "discover-listenbrainz"
    static let fresh = URL(string: "https://api.listenbrainz.org/1/explore/fresh-releases/")!
    static let musicBrainz = URL(string: "https://musicbrainz.org/ws/2/release/")!
    private let http: MusicHTTP
    init(http: MusicHTTP = MusicHTTP()) { self.http = http }

    var info: MusicProviderInfo {
        .discovery(id: Self.id, name: "New releases (ListenBrainz)", summary: "Albums and singles released this week.", host: "api.listenbrainz.org")
    }
    var capabilities: MusicCapabilities { [.browse, .catalogue] }

    func featured() async throws -> [MusicBrowseSection] {
        let obj = try await http.getObject(Self.fresh, query: ["days": "7"])
        let albums = Self.albums(obj)
        if albums.isEmpty { throw MusicError.notFound }
        return [MusicBrowseSection(id: "listenbrainz-fresh", title: "New releases this week", items: albums.prefix(30).map { .album($0) }, scope: .global)]
    }

    func albumTracks(id: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> {
        let url = Self.musicBrainz.appendingPathComponent(id)
        let obj = try await http.getObject(url, query: ["inc": "recordings artist-credits", "fmt": "json"])
        return MusicPage(items: Self.releaseTracks(obj))
    }

    // MARK: parsing

    static func albums(_ obj: Any?) -> [MusicAlbum] {
        let rows = (((obj as? [String: Any])?.dict("payload"))?.array("releases")) ?? []
        // Releases with cover art first, so the shelf does not open on blank squares.
        let mapped: [(Bool, MusicAlbum, Int)] = rows.compactMap { d in
            guard let mbid = d.str("release_mbid"), let name = d.str("release_name") else { return nil }
            let artist = MusicArtistRef(id: (d["artist_mbids"] as? [String])?.first ?? "", name: d.str("artist_credit_name") ?? Localized.string("Unknown artist"))
            let cover = d.str("caa_release_mbid").map { [MusicThumbnail(url: "https://coverartarchive.org/release/\($0)/front-500", width: 500, height: 500)] } ?? []
            let album = MusicAlbum(id: mbid, providerID: id, title: name, artists: [artist], thumbnails: cover, releaseDate: d.str("release_date"), albumType: d.str("release_group_primary_type"))
            return (!cover.isEmpty, album, d.int("listen_count") ?? 0)
        }.sorted { $0.2 > $1.2 }
        // Only releases that have cover art; the rest would be blank squares. Most-listened first.
        return mapped.filter(\.0).map(\.1)
    }

    static func releaseTracks(_ obj: Any?) -> [MusicTrack] {
        guard let d = obj as? [String: Any] else { return [] }
        let cover = d.dict("cover-art-archive")?["front"] as? Bool == true
        let albumID = d.str("id") ?? ""
        let thumbs = cover ? [MusicThumbnail(url: "https://coverartarchive.org/release/\(albumID)/front-500", width: 500, height: 500)] : []
        let albumRef = MusicAlbumRef(id: albumID, title: d.str("title") ?? "", thumbnails: thumbs)
        var out: [MusicTrack] = []
        for medium in d.array("media") {
            for t in medium.array("tracks") {
                guard let title = t.str("title"), let rid = t.dict("recording")?.str("id") ?? t.str("id") else { continue }
                let credit = ((t["artist-credit"] as? [[String: Any]]) ?? []).compactMap { $0.str("name") }.joined(separator: ", ")
                out.append(MusicTrack(id: rid, providerID: id, title: title, durationMs: Int64(t.int("length") ?? 0),
                                      trackNumber: t.int("position"), artists: [MusicArtistRef(id: "", name: credit.isEmpty ? Localized.string("Unknown artist") : credit)], album: albumRef, thumbnails: thumbs))
            }
        }
        return out
    }
}
