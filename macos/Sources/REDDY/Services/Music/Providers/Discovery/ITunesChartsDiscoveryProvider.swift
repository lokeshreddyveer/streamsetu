import Foundation

/// Apple's public per-country charts (the old RSS feed, which still answers without a key). Songs and albums resolve through the Apple
/// catalogue provider (`itunes`) when opened, so detail pages need nothing extra here.
struct ITunesChartsDiscoveryProvider: MusicMetadataProvider, MusicRegionalDiscovery {
    static let id = "discover-itunes-charts"
    private let http: MusicHTTP
    private let region: @Sendable () -> String
    init(http: MusicHTTP = MusicHTTP(), region: @escaping @Sendable () -> String = { MusicDiscoveryRegion.current() }) { self.http = http; self.region = region }

    var info: MusicProviderInfo {
        .discovery(id: Self.id, name: "Apple charts", summary: "Top songs and albums in your country.", host: "itunes.apple.com")
    }
    var capabilities: MusicCapabilities { [.browse, .catalogue] }

    func featured() async throws -> [MusicBrowseSection] { try await featured(region: region()) }

    func featured(region: String) async throws -> [MusicBrowseSection] {
        guard !region.isEmpty else { throw MusicError.notFound }       // Apple publishes per-country charts only
        // A value that is not a country is not answered with another country's charts (it used to become "us" and carry that country's name).
        guard let cc = Self.validRegion(region) else { MusicDebugLog.log("explore", "Apple charts: \"\(region)\" is not a country, no request"); throw MusicError.notFound }
        async let s = try? feed("topsongs", cc)
        async let a = try? feed("topalbums", cc)
        async let m = try? mostPlayedFeed(cc)
        let (songs, albums, played) = await (s, a, m)
        let name = MusicDiscoveryRegion.name(cc)
        var out: [MusicBrowseSection] = []
        let t = Self.songs(songs)
        if !t.isEmpty { out.append(MusicBrowseSection(id: "itunes-songs-" + cc, title: Localized.string("Top songs in %@", name), items: t.map { .track($0) }, scope: .regional(cc))) }
        // Apple's second per-country list (what is played most, as opposed to bought most); a different list from the one above, also keyless.
        let mp = Self.mostPlayed(played)
        if !mp.isEmpty { out.append(MusicBrowseSection(id: "itunes-played-" + cc, title: Localized.string("Most played in %@", name), items: mp.map { .track($0) }, scope: .regional(cc))) }
        let al = Self.albums(albums)
        if !al.isEmpty { out.append(MusicBrowseSection(id: "itunes-albums-" + cc, title: Localized.string("Top albums in %@", name), items: al.map { .album($0) }, scope: .regional(cc))) }
        if out.isEmpty { throw MusicError.network("no chart answered") }
        return out
    }

    /// The lower-case country code, or nil when the value is not two letters.
    static func validRegion(_ r: String) -> String? {
        let c = r.lowercased()
        return c.count == 2 && c.allSatisfy({ $0.isLetter && $0.isASCII }) ? c : nil
    }

    static func cleanRegion(_ r: String) -> String {
        let c = r.lowercased()
        return c.count == 2 && c.allSatisfy({ $0.isLetter && $0.isASCII }) ? c : "us"
    }

    private func feed(_ kind: String, _ cc: String) async throws -> Any {
        guard let url = URL(string: "https://itunes.apple.com/\(cc)/rss/\(kind)/limit=25/json") else { throw MusicError.network("bad address") }
        return try await http.getObject(url)
    }

    private func mostPlayedFeed(_ cc: String) async throws -> Any {
        guard let url = URL(string: "https://rss.marketingtools.apple.com/api/v2/\(cc)/music/most-played/25/songs.json") else { throw MusicError.network("bad address") }
        return try await http.getObject(url)
    }

    // MARK: parsing

    /// The "most played" list of the marketing feed: `feed.results[]` with id, name, artistName and artworkUrl100.
    static func mostPlayed(_ o: Any?) -> [MusicTrack] {
        let rows = (((o as? [String: Any])?["feed"] as? [String: Any])?["results"] as? [[String: Any]]) ?? []
        return rows.compactMap { d in
            guard let id = d["id"] as? String, let title = d["name"] as? String, !title.isEmpty else { return nil }
            let art = (d["artworkUrl100"] as? String).map { u in [MusicThumbnail(url: u, width: 100, height: 100), MusicThumbnail(url: u.replacingOccurrences(of: "100x100bb", with: "600x600bb"), width: 600, height: 600)] } ?? []
            let artists = (d["artistName"] as? String).map { [MusicArtistRef(id: "", name: $0)] } ?? []
            return MusicTrack(id: id, providerID: "itunes", title: title, durationMs: 0, artists: artists, thumbnails: art)
        }
    }

    private static func entries(_ o: Any?) -> [[String: Any]] {
        let feed = ((o as? [String: Any])?["feed"] as? [String: Any])
        if let list = feed?["entry"] as? [[String: Any]] { return list }
        if let one = feed?["entry"] as? [String: Any] { return [one] }   // a single result is sent as an object, not a list
        return []
    }
    private static func label(_ d: [String: Any]?, _ key: String) -> String? { ((d?[key] as? [String: Any])?["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    private static func capture(_ pattern: String, in text: String?) -> String? {
        guard let text, let r = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[r]).split(whereSeparator: { !$0.isNumber }).last.map(String.init)
    }
    private static func art(_ d: [String: Any]) -> [MusicThumbnail] {
        let imgs = (d["im:image"] as? [[String: Any]]) ?? []
        guard let last = imgs.last?["label"] as? String, last.hasPrefix("http") else { return [] }
        let big = last.replacingOccurrences(of: "170x170bb", with: "600x600bb")
        return [MusicThumbnail(url: last, width: 170, height: 170)] + (big != last ? [MusicThumbnail(url: big, width: 600, height: 600)] : [])
    }
    private static func artistRef(_ d: [String: Any]) -> MusicArtistRef? {
        guard let name = label(d, "im:artist") else { return nil }
        let href = ((d["im:artist"] as? [String: Any])?["attributes"] as? [String: Any])?["href"] as? String
        return MusicArtistRef(id: capture("/artist/[^/]+/[0-9]+", in: href) ?? "", name: name)
    }

    static func songs(_ o: Any?) -> [MusicTrack] {
        entries(o).compactMap { d in
            guard let id = ((d["id"] as? [String: Any])?["attributes"] as? [String: Any])?["im:id"] as? String, let title = label(d, "im:name") else { return nil }
            let artist = artistRef(d)
            let coll = d["im:collection"] as? [String: Any]
            let href = (((coll?["link"] as? [String: Any])?["attributes"]) as? [String: Any])?["href"] as? String
            let art = art(d)
            let album = capture("/album/[^/]+/[0-9]+", in: href).map { MusicAlbumRef(id: $0, title: label(coll, "im:name") ?? "", artists: artist.map { [$0] } ?? [], thumbnails: art) }
            return MusicTrack(id: id, providerID: "itunes", title: title, durationMs: 0, artists: artist.map { [$0] } ?? [], album: album, thumbnails: art)
        }
    }

    static func albums(_ o: Any?) -> [MusicAlbum] {
        entries(o).compactMap { d in
            guard let id = ((d["id"] as? [String: Any])?["attributes"] as? [String: Any])?["im:id"] as? String, let title = label(d, "im:name") else { return nil }
            return MusicAlbum(id: id, providerID: "itunes", title: title, artists: artistRef(d).map { [$0] } ?? [], thumbnails: art(d),
                              releaseDate: label(d, "im:releaseDate").map { String($0.prefix(10)) }, totalTracks: label(d, "im:itemCount").flatMap(Int.init))
        }
    }
}
