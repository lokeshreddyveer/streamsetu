import Foundation

// Artist, album and playlist pages; the watch/next queue; lyrics; library grids and history.

struct YTMArtistPage: Sendable {
    var artist: MusicArtist
    var topTracks: [MusicTrack]
    var topSongsPlaylistID: String?
    var radioPlaylistID: String?
    var subscribed = false
    var subscriberText: String?
    var monthlyListeners: String?
    var shelves: [YTMShelf]
}

struct YTMAlbumPage: Sendable {
    var album: MusicAlbum
    var rows: [YTMRow]
    var audioPlaylistID: String?
    var inLibrary: Bool?
    var shelves: [YTMShelf]
    var tracks: [MusicTrack] { rows.map(\.track) }
}

struct YTMPlaylistPage: Sendable {
    var playlist: MusicPlaylist
    var rows: [YTMRow]
    var continuation: String?
    var owned: Bool
    var collaborative: Bool
    var hasHeader: Bool
    var tracks: [MusicTrack] { rows.map(\.track) }
}

struct YTMNextPage: Sendable {
    var tracks: [MusicTrack]
    var continuation: String?
    var automixPlaylistID: String?
    var lyricsBrowseID: String?
}

struct YTMHistoryBucket: Sendable { var title: String; var tracks: [MusicTrack] }

enum YTMPageParser {
    private static func firstHeader(_ root: Any?, _ keys: [String]) -> [String: Any]? {
        for k in keys { if let h = YTMJSON.first(k, in: root) { return h } }
        return nil
    }

    // MARK: artist

    static func parseArtist(_ root: Any?, browseID: String) -> YTMArtistPage {
        let header = firstHeader(root, ["musicImmersiveHeaderRenderer", "musicHeaderRenderer", "musicVisualHeaderRenderer"])
        let name = YTMJSON.text(header?["title"])
        let thumbs = YTMJSON.thumbnails(in: header?["foregroundThumbnail"]).nilIfEmptyArray ?? YTMJSON.thumbnails(in: header?["thumbnail"])
        let sub = header.flatMap { YTMJSON.first("subscribeButtonRenderer", in: $0) }
        let channel = sub?.str("channelId") ?? browseID
        let subscriberText = YTMJSON.text(sub?["longSubscriberCountText"]).nilIfEmpty ?? YTMJSON.text(sub?["subscriberCountText"]).nilIfEmpty
        let artist = MusicArtist(id: channel.hasPrefix("UC") ? channel : browseID, providerID: YTM.providerID, name: name, thumbnails: thumbs,
                                 followers: nil, bio: YTMJSON.text(header?["description"]).nilIfEmpty,
                                 externalURL: "https://music.youtube.com/channel/\(browseID)")
        let radio = YTMJSON.allStrings("playlistId", in: header).first { $0.hasPrefix("RD") }
        let shelf = YTMJSON.find("musicShelfRenderer", in: root).first
        var top = YTMItems.songRows(shelf?["contents"]).map(\.track)
        let ref = MusicArtistRef(id: artist.id, name: name)
        for i in top.indices where top[i].artists.isEmpty { top[i].artists = [ref] }
        var topID = YTMJSON.first("browseEndpoint", in: shelf?["bottomEndpoint"] ?? shelf)?.str("browseId")
        if let t = topID, t.hasPrefix("VL") { topID = String(t.dropFirst(2)) } else { topID = nil }
        return YTMArtistPage(artist: artist, topTracks: top, topSongsPlaylistID: topID, radioPlaylistID: radio,
                             subscribed: (sub?["subscribed"] as? Bool) ?? false, subscriberText: subscriberText,
                             monthlyListeners: YTMJSON.text(header?["monthlyListenerCount"]).nilIfEmpty,
                             shelves: YTMHomeParser.shelves(root, idPrefix: "artist"))
    }

    // MARK: album

    static func parseAlbum(_ root: Any?, browseID: String) -> YTMAlbumPage {
        let header = firstHeader(root, ["musicResponsiveHeaderRenderer", "musicDetailHeaderRenderer"])
        let title = YTMJSON.text(header?["title"])
        let subFields = YTMItems.fields(YTMJSON.runs(header?["subtitle"]))
        let year = subFields.map(YTMItems.fieldText).first { $0.range(of: #"^\d{4}$"#, options: .regularExpression) != nil }
        let type = subFields.first.map(YTMItems.fieldText).flatMap { YTMItems.typeLabels.contains($0) ? $0 : nil }
        let total = YTMJSON.text(header?["secondSubtitle"]).split(whereSeparator: { !$0.isNumber }).first.flatMap { Int($0) }
        var artists = YTMItems.artistRefs(YTMJSON.runs(header?["straplineTextOne"]))
        if artists.count == 1, artists[0].id == artists[0].name, artists[0].name.isEmpty { artists = [] }
        let cover = YTMJSON.thumbnails(in: header?["thumbnail"])
        var album = MusicAlbum(id: browseID, providerID: YTM.providerID, title: title, artists: artists, thumbnails: cover, releaseDate: year,
                               totalTracks: total, albumType: type, externalURL: "https://music.youtube.com/browse/\(browseID)")
        album.creditBundle = YouTubeMusicCreditMapper.albumBundle(artists: artists, year: year)
        var rows = YTMItems.songRows(root, skipping: ["musicCarouselShelfRenderer"])
        let albumRef = MusicAlbumRef(id: browseID, title: title, artists: artists, thumbnails: cover)
        for i in rows.indices {
            rows[i].track.thumbnails = cover
            if rows[i].track.artists.isEmpty { rows[i].track.artists = artists }
            rows[i].track.album = albumRef
            rows[i].track.trackNumber = i + 1
            rows[i].albumID = browseID
        }
        var olak = rows.compactMap(\.audioPlaylistID).first
        var inLibrary: Bool?
        if let toggle = YTMJSON.find("toggleButtonRenderer", in: header).first(where: { YTMJSON.first("likeEndpoint", in: $0) != nil }) {
            if olak == nil { olak = YTMJSON.firstString("playlistId", in: toggle) }
            inLibrary = toggle["isToggled"] as? Bool
        }
        let shelves = YTMHomeParser.shelves(root, idPrefix: "album").map { s -> YTMShelf in
            var s = s
            s.items = s.items.filter { if case .album(let a) = $0 { return a.id != browseID }; return true }
            return s
        }.filter { !$0.items.isEmpty }
        return YTMAlbumPage(album: album, rows: rows, audioPlaylistID: olak, inLibrary: inLibrary, shelves: shelves)
    }

    // MARK: playlist

    static func parsePlaylist(_ root: Any?, playlistID: String) -> YTMPlaylistPage {
        let header = firstHeader(root, ["musicResponsiveHeaderRenderer", "musicDetailHeaderRenderer"])
        let shelf = YTMJSON.find("musicPlaylistShelfRenderer", in: root).first ?? YTMJSON.find("musicShelfRenderer", in: root).first
        var rows = YTMItems.songRows(shelf ?? root, shallow: true)
        let cover = YTMJSON.thumbnails(in: header?["thumbnail"])
        if !cover.isEmpty { for i in rows.indices where rows[i].track.thumbnails.isEmpty { rows[i].track.thumbnails = cover } }
        let count = trackCount(header)
        let owner = YTMJSON.text(header?["straplineTextOne"]).nilIfEmpty
        let pl = MusicPlaylist(id: playlistID, providerID: YTM.providerID, name: YTMJSON.text(header?["title"]),
                               summary: YTMJSON.text(header?["description"]).nilIfEmpty, owner: owner, thumbnails: cover, trackCount: count,
                               externalURL: "https://music.youtube.com/playlist?list=\(playlistID)")
        return YTMPlaylistPage(playlist: pl, rows: rows, continuation: YTMJSON.continuationToken(in: shelf ?? root),
                               owned: YTMJSON.first("musicEditablePlaylistDetailHeaderRenderer", in: root) != nil,
                               collaborative: YTMJSON.contains("PAplaylist_collaborate", in: root), hasHeader: header != nil)
    }

    /// "1B views • 200 tracks • 12 hours": the count is the part that names tracks, never the view total in front of it.
    static func trackCount(_ header: [String: Any]?) -> Int? {
        let parts = [YTMJSON.text(header?["secondSubtitle"]), YTMJSON.text(header?["subtitle"])]
            .flatMap { $0.components(separatedBy: "\u{2022}") }.map { $0.trimmingCharacters(in: .whitespaces) }
        let wanted = ["track", "song", "episode", "video"]
        let hit = parts.first { part in let l = part.lowercased(); return l.first?.isNumber == true && wanted.contains { l.contains($0) } }
        // A bare number with no unit still counts, as long as it is not a view or play total.
        let bare = parts.first { $0.first?.isNumber == true && !$0.lowercased().contains("view") && !$0.lowercased().contains("play") && !$0.lowercased().contains("min") && !$0.lowercased().contains("hour") && !$0.lowercased().contains("sec") }
        guard let hit = hit ?? bare else { return nil }
        return Int(hit.replacingOccurrences(of: ",", with: "").split(whereSeparator: { !$0.isNumber }).first ?? "")
    }

    static func parsePlaylistContinuation(_ root: Any?) -> (rows: [YTMRow], next: String?) {
        (YTMItems.songRows(root, shallow: true), YTMJSON.continuationToken(in: root))
    }

    /// The browse id that opens a playlist id. Special pages keep their own prefix.
    static func browseID(forPlaylist id: String) -> String {
        id.hasPrefix("FEmusic_") || id.hasPrefix("MPSP") || id.hasPrefix("VL") ? id : "VL" + id
    }

    // MARK: next / radio

    static func parseNext(_ root: Any?) -> YTMNextPage {
        let found = YTMJSON.findShallow(["playlistPanelVideoWrapperRenderer", "playlistPanelVideoRenderer"], in: root)
        let panels: [[String: Any]] = found.compactMap { f in
            f.key == "playlistPanelVideoRenderer" ? f.value : f.value.dict("primaryRenderer")?.dict("playlistPanelVideoRenderer")
        }
        let tracks = panels.compactMap(panelTrack)
        let lyricsID = YTMJSON.find("browseEndpoint", in: root).first { $0.str("browseId") != nil && YTMJSON.firstString("pageType", in: $0) == "MUSIC_PAGE_TYPE_TRACK_LYRICS" }?.str("browseId")
        let automix = YTMJSON.first("automixPreviewVideoRenderer", in: root).flatMap { YTMJSON.firstString("playlistId", in: $0) }
        return YTMNextPage(tracks: tracks, continuation: YTMJSON.firstString("continuation", in: root), automixPlaylistID: automix, lyricsBrowseID: lyricsID)
    }

    private static func panelTrack(_ p: [String: Any]) -> MusicTrack? {
        guard let vid = p.str("videoId") else { return nil }
        let title = YTMJSON.text(p["title"])
        guard !title.isEmpty else { return nil }
        let byline = YTMJSON.runs(p["longBylineText"]).isEmpty ? YTMJSON.runs(p["shortBylineText"]) : YTMJSON.runs(p["longBylineText"])
        let fs = YTMItems.fields(byline)
        let artists = fs.first.map(YTMItems.artistRefs) ?? []
        var album: MusicAlbumRef?
        if let r = byline.first(where: { (YTMJSON.browseID($0.dict("navigationEndpoint")) ?? "").hasPrefix("MPRE") }),
           let id = YTMJSON.browseID(r.dict("navigationEndpoint")), let t = r["text"] as? String { album = MusicAlbumRef(id: id, title: t) }
        let dur = YTMJSON.durationMs(YTMJSON.text(p["lengthText"])) ?? 0
        var t = MusicTrack(id: vid, providerID: YTM.providerID, title: title, durationMs: dur, artists: artists, album: album,
                           thumbnails: YTMJSON.thumbnails(in: p["thumbnail"]), externalURL: "https://music.youtube.com/watch?v=\(vid)")
        t.videoID = vid
        t.isVideo = YTMItems.videoFlag(of: p)
        if YTMItems.flags(of: p).isEpisode { t.isPodcast = true }
        return t
    }

    // MARK: lyrics

    static func parseTimedLyrics(_ root: Any?) -> [MusicLyricLine] {
        var lines: [MusicLyricLine] = []
        YTMJSON.walk(root) { k, v in
            if lines.isEmpty, k == "timedLyricsData", let arr = v as? [[String: Any]] {
                lines = arr.compactMap { e in
                    guard let text = e["lyricLine"] as? String, let cue = e.dict("cueRange"), let ms = cue.int("startTimeMilliseconds") else { return nil }
                    return MusicLyricLine(timeMs: Int64(ms), text: text)
                }.sorted { $0.timeMs < $1.timeMs }
            }
            return lines.isEmpty
        }
        return lines
    }

    static func parsePlainLyrics(_ root: Any?) -> (text: String, source: String)? {
        guard let shelf = YTMJSON.first("musicDescriptionShelfRenderer", in: root) else { return nil }
        let text = YTMJSON.text(shelf["description"])
        guard !text.isEmpty else { return nil }
        return (text, YTMJSON.text(shelf["footer"]).nilIfEmpty ?? "YouTube Music")
    }

    // MARK: library and history (callable only with a session)

    static func parseLibraryGrid(_ root: Any?) -> (items: [MusicBrowseItem], next: String?) {
        (YTMItems.gridItems(root), YTMJSON.continuationToken(in: root))
    }

    static func parseHistory(_ root: Any?) -> [YTMHistoryBucket] {
        YTMJSON.find("musicShelfRenderer", in: root).compactMap { s in
            let tracks = YTMItems.songRows(s["contents"], shallow: true).map(\.track)
            return tracks.isEmpty ? nil : YTMHistoryBucket(title: YTMJSON.text(s["title"]), tracks: tracks)
        }
    }
}

extension Array {
    var nilIfEmptyArray: [Element]? { isEmpty ? nil : self }
}
