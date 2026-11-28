import Foundation

/// How a hit from Apple's catalogue is scored against the song that is playing. Pure, so the weights can be tested.
enum MusicMotionScoring {
    static let minimum = 12
    static let editionWords: Set<String> = ["deluxe", "expanded", "remastered", "remix", "version", "edit", "mix", "bonus"]
    static let notAnAlbum = ["playlist", "set list", "essentials", "dj mix", "mixed", "apple music", "todays hits", "session"]

    private static func words(_ s: String) -> Set<String> { Set(MusicText.normalize(s).split(separator: " ").map(String.init)) }

    private static func contains(_ a: String, _ b: String) -> Bool {
        let x = " " + MusicText.normalize(a) + " ", y = " " + MusicText.normalize(b) + " "
        return !b.isEmpty && (x.contains(y) || y.contains(x))
    }

    private static func edition(_ hit: String, _ want: String) -> Int {
        let h = words(hit).intersection(editionWords), w = words(want).intersection(editionWords)
        if h.isEmpty { return 0 }
        return w.isEmpty ? -3 : 5
    }

    static func isCompilation(_ name: String) -> Bool {
        let n = MusicText.normalize(name)
        return notAnAlbum.contains { n.contains($0) }
    }

    /// A song hit: the artist must be credited, then the title and the album decide.
    static func song(hitTitle: String, hitArtist: String, hitAlbum: String?, title: String, artists: [String], album: String?) -> Int? {
        guard !isCompilation(hitTitle), MusicMotionMatch.credits(hitArtist, include: artists) else { return nil }
        var score = 10
        let t = MusicText.normalize(hitTitle), w = MusicText.normalize(title)
        if t == w { score += 15 } else if contains(hitTitle, title) { score += 7 } else { score -= 10 }
        if let hitAlbum, let album, !album.isEmpty {
            let a = MusicText.normalize(hitAlbum), b = MusicText.normalize(album)
            if a == b { score += 20 } else if contains(hitAlbum, album) { score += 10 }
        }
        score += edition(hitTitle, title)
        return score
    }

    /// An album hit, asked for by the album's name (or the song's title when the album is not known). The artist raises or lowers the score
    /// rather than deciding it, because a film album is credited to a composer and the song to its singers.
    static func album(hitName: String, hitArtist: String, wanted: String, artists: [String]) -> Int? {
        guard !isCompilation(hitName), !MusicText.normalize(wanted).isEmpty else { return nil }
        var score = 10
        if MusicText.normalize(hitName) == MusicText.normalize(wanted) { score += 25 } else if contains(hitName, wanted) { score += 10 } else { score -= 10 }
        score += MusicMotionMatch.credits(hitArtist, include: artists) ? 8 : -6
        score += edition(hitName, wanted)
        return score
    }
}

/// Apple Music's looping album artwork, read from Apple's public web catalogue with the anonymous token Apple's own web player embeds (the same
/// way the Apple lyrics source reads it). Unofficial: there is no published agreement for this.
struct AppleMotionArtworkProvider: MusicMotionArtworkProvider {
    static let id = "apple-motion"
    static let base = "https://amp-api.music.apple.com/v1/catalog"
    static let timeout = 8.0

    typealias TokenSource = @Sendable (MusicHTTP, Double) async throws -> String
    typealias TokenReset = @Sendable () async -> Void

    private let http: MusicHTTP
    private let token: TokenSource
    private let resetToken: TokenReset

    @Sendable private static func forgetSharedToken() async { await PaxSenixAppleToken.shared.forget() }

    init(http: MusicHTTP = MusicHTTP(),
         token: @escaping TokenSource = { try await PaxSenixAppleToken.shared.value(http: $0, timeout: $1) },
         resetToken: @escaping TokenReset = AppleMotionArtworkProvider.forgetSharedToken) {
        self.http = http; self.token = token; self.resetToken = resetToken
    }

    var info: MusicProviderInfo {
        MusicProviderInfo(id: Self.id, name: "Apple Music motion artwork",
                          summary: "Looping album artwork from Apple Music, shown behind the cover while a song plays",
                          privacyNote: "While this is on and a song is playing, its album, title and artist are sent to Apple Music's web catalogue to look for an animated cover, and the clip is downloaded from Apple. To search, this source reads an anonymous token out of Apple's web player and presents itself as that web player, which is unofficial access to a third-party web client. Nothing is sent when it is off.",
                          homepage: "https://music.apple.com")
    }

    // MARK: lookup

    func clip(for q: MusicMotionQuery) async throws -> MusicMotionClip? {
        guard !q.title.isEmpty || q.album != nil else { return nil }
        if let id = q.catalogAlbumID { return try await album(id: id, storefront: q.storefront) }
        if let isrc = q.isrc, !isrc.isEmpty, let id = try await albumID(isrc: isrc, storefront: q.storefront), let c = try await album(id: id, storefront: q.storefront) { return c }
        if let wanted = q.album, !wanted.isEmpty {
            let term = ([q.artists.first ?? ""] + [wanted]).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            let obj = try await get("/\(q.storefront)/search", ["term": term, "types": "albums", "limit": "10", "extend": "editorialVideo", "l": "en-US"])
            if let best = Self.bestAlbum(in: obj, wanted: wanted, artists: q.artists), let clip = Self.clip(fromAlbum: best) { return clip }
        }
        // No album name to search by: find the song, then its album.
        let withAlbum = q.album.map { MusicText.normalize(q.title).contains(MusicText.normalize($0)) ? "" : " " + $0 } ?? ""
        let term = ((q.artists.first ?? "") + " " + q.title + withAlbum).trimmingCharacters(in: .whitespaces)
        let obj = try await get("/\(q.storefront)/search", ["term": term, "types": "songs", "limit": "10", "include": "albums", "l": "en-US"])
        guard let id = Self.bestSongAlbumID(in: obj, title: q.title, artists: q.artists, album: q.album) else { return nil }
        return try await album(id: id, storefront: q.storefront)
    }

    func album(id: String, storefront: String) async throws -> MusicMotionClip? {
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
        let obj = try await get("/\(storefront)/albums/\(id)", ["extend": "editorialVideo", "l": "en-US"])
        guard let d = (obj as? [String: Any])?.array("data").first else { return nil }
        return Self.clip(fromAlbum: d)
    }

    func albumID(isrc: String, storefront: String) async throws -> String? {
        let obj = try await get("/\(storefront)/songs", ["filter[isrc]": isrc, "include": "albums", "l": "en-US"])
        guard let song = (obj as? [String: Any])?.array("data").first else { return nil }
        return Self.albumID(ofSong: song)
    }

    private func get(_ path: String, _ query: [String: String]) async throws -> Any {
        guard let url = URL(string: Self.base + path) else { throw MusicError.network("bad address") }
        let headers = { (t: String) in ["Authorization": "Bearer \(t)", "Origin": "https://music.apple.com", "Referer": "https://music.apple.com/"] }
        var t = try await token(http, Self.timeout)
        do { return try await MusicLyricsIO.object(http, url, query: query, headers: headers(t), timeout: Self.timeout) }
        catch MusicError.notSignedIn, MusicError.refused {
            // The token expired: read a fresh one once.
            await resetToken()
            t = try await token(http, Self.timeout)
            return try await MusicLyricsIO.object(http, url, query: query, headers: headers(t), timeout: Self.timeout)
        }
    }

    // MARK: reading replies

    static func bestAlbum(in obj: Any, wanted: String, artists: [String]) -> [String: Any]? {
        let items = ((obj as? [String: Any])?.dict("results")?.dict("albums")?.array("data")) ?? []
        var best: ([String: Any], Int)?
        for item in items {
            let a = item.dict("attributes") ?? [:]
            // An edition with no clip is skipped, so the same album's other edition can still answer.
            guard clip(fromAlbum: item) != nil, let name = a.str("name"), let s = MusicMotionScoring.album(hitName: name, hitArtist: a.str("artistName") ?? "", wanted: wanted, artists: artists), s >= MusicMotionScoring.minimum else { continue }
            if best == nil || s > best!.1 { best = (item, s) }
        }
        return best?.0
    }

    static func bestSongAlbumID(in obj: Any, title: String, artists: [String], album: String?) -> String? {
        let items = ((obj as? [String: Any])?.dict("results")?.dict("songs")?.array("data")) ?? []
        var best: (String, Int)?
        for item in items {
            let a = item.dict("attributes") ?? [:]
            guard let name = a.str("name"), let id = albumID(ofSong: item),
                  let s = MusicMotionScoring.song(hitTitle: name, hitArtist: a.str("artistName") ?? "", hitAlbum: a.str("albumName"), title: title, artists: artists, album: album),
                  s >= MusicMotionScoring.minimum else { continue }
            if best == nil || s > best!.1 { best = (id, s) }
        }
        return best?.0
    }

    /// The song's album id from its relationships, else from its page address (`/album/<name>/<id>?i=<song>`). Playlist ids (`pl.`) are never albums.
    static func albumID(ofSong song: [String: Any]) -> String? {
        if let rel = song.dict("relationships")?.dict("albums")?.array("data").first, let id = rel.str("id"), id.allSatisfy(\.isNumber) { return id }
        guard let s = song.dict("attributes")?.str("url"), let u = URL(string: s) else { return nil }
        let parts = u.pathComponents
        guard let i = parts.firstIndex(of: "album"), parts.indices.contains(i + 2) else { return nil }
        let id = parts[i + 2]
        return id.allSatisfy(\.isNumber) ? id : nil
    }

    private static let linkKeys = ["video", "videoUrl", "hlsUrl", "url"]
    private static let squareKeys = ["motionDetailSquare", "motionSquareVideo1x1"]
    private static let rawKeys = ["motionDetailRaw"]
    private static let tallKeys = ["motionDetailTall", "motionTallVideo3x4"]

    /// Every usable address under these keys, in key order.
    static func renditions(_ video: [String: Any], keys: [String]) -> [URL] {
        var out: [URL] = []
        for k in keys {
            guard let r = video.dict(k) else { continue }
            for l in linkKeys {
                if let s = r.str(l), let u = URL(string: s), u.scheme?.lowercased() == "https", MusicTransfer.isAllowed(u) { if !out.contains(u) { out.append(u) }; break }
            }
        }
        return out
    }

    /// The square rendition is preferred, then the raw one, then the tall one. A second, different rendition is kept for the one retry.
    static func clip(fromAlbum item: [String: Any]) -> MusicMotionClip? {
        guard let a = item.dict("attributes"), let video = a.dict("editorialVideo") else { return nil }
        let tall = renditions(video, keys: tallKeys)
        let ordered = renditions(video, keys: squareKeys) + renditions(video, keys: rawKeys) + tall
        guard let first = ordered.first else { return nil }
        return MusicMotionClip(masterURL: first, fallbackURL: ordered.first { $0 != first }, portraitURL: tall.first,
                               title: nil, artist: a.str("artistName"), album: a.str("name"), source: id)
    }

    private var id: String { Self.id }
}
