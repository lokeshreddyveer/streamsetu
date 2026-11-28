import Foundation

// Shared parsing tools for InnerTube replies. YouTube re-nests its renderers often, so nothing here relies on absolute paths: values are found
// by key anywhere in the tree. Every parser is tolerant: a missing optional field means absent, never an error.

enum YTM {
    static let providerID = "ytmusic"
}

enum YTMJSON {
    /// Every object stored under `key`, depth first, arrays flattened, dictionary keys visited in sorted order so results are stable.
    static func find(_ key: String, in node: Any?, skipping: Set<String> = [], depth: Int = 0) -> [[String: Any]] {
        var out: [[String: Any]] = []
        walk(node, depth: depth) { k, v in
            if k == key, let m = v as? [String: Any] { out.append(m) }
            return !skipping.contains(k)
        }
        return out
    }

    /// Like `find` for several keys at once, but stops descending when one matches (rows that embed a copy of themselves would otherwise repeat).
    static func findShallow(_ keys: Set<String>, in node: Any?, depth: Int = 0) -> [(key: String, value: [String: Any])] {
        var out: [(key: String, value: [String: Any])] = []
        walk(node, depth: depth) { k, v in
            if keys.contains(k), let m = v as? [String: Any] { out.append((k, m)); return false }
            return true
        }
        return out
    }

    /// Visits every key/value pair; the closure returns false to skip the value's children.
    static func walk(_ node: Any?, depth: Int = 0, _ visit: (String, Any) -> Bool) {
        guard depth < 40, let node else { return }
        if let d = node as? [String: Any] {
            for k in d.keys.sorted() {
                guard let v = d[k] else { continue }
                if visit(k, v) { walk(v, depth: depth + 1, visit) }
            }
        } else if let a = node as? [Any] {
            for v in a { walk(v, depth: depth + 1, visit) }
        }
    }

    static func first(_ key: String, in node: Any?) -> [String: Any]? { find(key, in: node).first }

    static func allStrings(_ key: String, in node: Any?) -> [String] {
        var out: [String] = []
        walk(node) { k, v in
            if k == key, let s = v as? String { out.append(s) }
            return true
        }
        return out
    }

    static func firstString(_ key: String, in node: Any?) -> String? { allStrings(key, in: node).first }

    /// True when a string value equal to `value` exists anywhere under `node`.
    static func contains(_ value: String, in node: Any?) -> Bool {
        var hit = false
        walk(node) { _, v in
            if let s = v as? String, s == value { hit = true }
            return !hit
        }
        if hit { return true }
        if let a = node as? [Any] { return a.contains { ($0 as? String) == value || contains(value, in: $0) } }
        return false
    }

    static func runs(_ node: Any?) -> [[String: Any]] { (node as? [String: Any])?.array("runs") ?? [] }

    /// Text of a runs object (or `simpleText`); empty counts as absent.
    static func text(_ node: Any?) -> String {
        guard let d = node as? [String: Any] else { return "" }
        if let s = d["simpleText"] as? String { return s }
        return runs(d).compactMap { $0["text"] as? String }.joined()
    }

    /// The first `thumbnails` array found under the node, ascending in size as YouTube sends it.
    static func thumbnails(in node: Any?) -> [MusicThumbnail] {
        var found: [[String: Any]]?
        walk(node) { k, v in
            if found == nil, k == "thumbnails", let a = v as? [[String: Any]], !a.isEmpty { found = a }
            return found == nil
        }
        return (found ?? []).compactMap { t in
            guard let u = t.str("url") else { return nil }
            return MusicThumbnail(url: u.hasPrefix("//") ? "https:" + u : u, width: t.int("width") ?? 0, height: t.int("height") ?? 0)
        }
    }

    /// First `continuationCommand.token`, else the first `nextContinuationData.continuation`.
    static func continuationToken(in node: Any?) -> String? {
        if let t = find("continuationCommand", in: node).compactMap({ $0.str("token") }).first { return t }
        return find("nextContinuationData", in: node).compactMap { $0.str("continuation") }.first
    }

    static func browseID(_ endpoint: [String: Any]?) -> String? { endpoint?.dict("browseEndpoint")?.str("browseId") }

    // MARK: durations

    static func isDuration(_ s: String) -> Bool { s.range(of: #"^\d{1,2}(:\d{2}){1,2}$"#, options: .regularExpression) != nil }

    static func durationMs(_ s: String) -> Int64? { isDuration(s) ? YouTubeAudio.clock(s) : nil }

    /// "1 hr 4 min" becomes 1:04:00, a lone number is minutes. Only the numbers matter, so other languages work too.
    static func spokenDurationMs(_ s: String) -> Int64? {
        if let d = durationMs(s) { return d }
        let nums = s.split(whereSeparator: { !$0.isNumber }).compactMap { Int64($0) }
        switch nums.count {
        case 1: return nums[0] * 60_000
        case 2: return (nums[0] * 3600 + nums[1] * 60) * 1000
        case 3: return (nums[0] * 3600 + nums[1] * 60 + nums[2]) * 1000
        default: return nil
        }
    }
}

// MARK: rows and cards

struct YTMRow: Sendable {
    var track: MusicTrack
    var isVideo = false, isUpload = false, isEpisode = false
    var setVideoID: String? = nil
    var playCount: String? = nil
    var rating: String? = nil
    var albumID: String? = nil
    var audioPlaylistID: String? = nil
}

enum YTMItems {
    static let typeLabels: Set<String> = ["Song", "Video", "Album", "Single", "EP", "Playlist", "Artist", "Episode", "Podcast"]
    static let bullet = "\u{2022}"

    static func fields(_ runs: [[String: Any]]) -> [[[String: Any]]] {
        var out: [[[String: Any]]] = [[]]
        for r in runs {
            if (r["text"] as? String)?.trimmingCharacters(in: .whitespaces) == bullet { out.append([]) } else { out[out.count - 1].append(r) }
        }
        return out.filter { !$0.isEmpty }
    }

    static func fieldText(_ f: [[String: Any]]) -> String { f.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespaces) }

    static func linksArtist(_ f: [[String: Any]]) -> Bool {
        f.contains { (YTMJSON.browseID($0.dict("navigationEndpoint")) ?? "").hasPrefix("UC") }
    }

    /// The first field is often a localized result-type label; it is dropped by structure, not only by English text.
    static func dropTypeLabel(_ fields: [[[String: Any]]]) -> [[[String: Any]]] {
        guard let first = fields.first, !linksArtist(first) else { return fields }
        let later = fields.dropFirst().contains(where: linksArtist)
        let twoWithDuration = fields.count == 2 && YTMJSON.isDuration(fieldText(fields[1]))
        return typeLabels.contains(fieldText(first)) || later || twoWithDuration ? Array(fields.dropFirst()) : fields
    }

    static func artistRefs(_ field: [[String: Any]]) -> [MusicArtistRef] {
        let linked = field.compactMap { run -> MusicArtistRef? in
            guard let id = YTMJSON.browseID(run.dict("navigationEndpoint")), id.hasPrefix("UC"), let t = run["text"] as? String else { return nil }
            return MusicArtistRef(id: id, name: t)
        }
        if !linked.isEmpty { return linked }
        let t = fieldText(field)
        return t.isEmpty ? [] : [MusicArtistRef(id: t, name: t)]
    }

    static func musicVideoType(of node: [String: Any]) -> String? {
        YTMJSON.firstString("musicVideoType", in: node["overlay"] ?? node["thumbnailOverlay"]) ?? YTMJSON.firstString("musicVideoType", in: node["navigationEndpoint"])
    }

    /// True for a music video, false for a song, upload or episode, nil when the row names no type.
    static func videoFlag(of node: [String: Any]) -> Bool? {
        guard musicVideoType(of: node) != nil else { return nil }
        let f = flags(of: node)
        return f.isVideo
    }

    static func flags(of node: [String: Any]) -> (isVideo: Bool, isUpload: Bool, isEpisode: Bool) {
        let t = musicVideoType(of: node)
        let upload = t == "MUSIC_VIDEO_TYPE_PRIVATELY_OWNED_TRACK"
        let episode = t == "MUSIC_VIDEO_TYPE_PODCAST_EPISODE"
        let video = t != nil && t != "MUSIC_VIDEO_TYPE_ATV" && !upload && !episode
        return (video, upload, episode)
    }

    static func isExplicit(_ node: [String: Any]) -> Bool {
        for key in ["badges", "subtitleBadges", "subtitleBadge"] where YTMJSON.contains("MUSIC_EXPLICIT_BADGE", in: node[key]) { return true }
        return false
    }

    static func isPlayCount(_ s: String) -> Bool { s.first?.isNumber == true && !s.contains(":") }

    // MARK: song row

    static func parseSongRow(_ item: [String: Any]) -> YTMRow? {
        let columns = item.array("flexColumns").map { YTMJSON.runs($0.dict("musicResponsiveListItemFlexColumnRenderer")?.dict("text")) }
        guard let titleRuns = columns.first else { return nil }
        let title = fieldText(titleRuns)
        guard !title.isEmpty else { return nil }
        let videoID = item.dict("playlistItemData")?.str("videoId")
            ?? item.dict("navigationEndpoint")?.dict("watchEndpoint")?.str("videoId")
            ?? YTMJSON.firstString("videoId", in: item["overlay"])
            ?? titleRuns.compactMap({ $0.dict("navigationEndpoint")?.dict("watchEndpoint")?.str("videoId") }).first
        guard let videoID else { return nil }

        let f = flags(of: item)
        let fieldsAll = dropTypeLabel(columns.count > 1 ? fields(columns[1]) : [])
        var artists: [MusicArtistRef] = []
        if let first = fieldsAll.first, !YTMJSON.isDuration(fieldText(first)), linksArtist(first) || !isPlayCount(fieldText(first)) { artists = artistRefs(first) }
        var durationMs = fieldsAll.reversed().compactMap { YTMJSON.durationMs(fieldText($0)) }.first
        if durationMs == nil {
            for fixed in item.array("fixedColumns") {
                if let ms = YTMJSON.durationMs(YTMJSON.text(fixed.dict("musicResponsiveListItemFixedColumnRenderer")?.dict("text"))) { durationMs = ms }
            }
        }
        if durationMs == nil, columns.count > 2 { durationMs = YTMJSON.durationMs(fieldText(columns[2])) }

        // Album: a run linking an MPRE page is locale-proof; else a plain third column; else the second subtitle field (not for videos, where it is a view count).
        var album: MusicAlbumRef?
        for col in columns.dropFirst() {
            if let r = col.first(where: { (YTMJSON.browseID($0.dict("navigationEndpoint")) ?? "").hasPrefix("MPRE") }),
               let id = YTMJSON.browseID(r.dict("navigationEndpoint")), let t = r["text"] as? String { album = MusicAlbumRef(id: id, title: t); break }
        }
        var playCount: String?
        if columns.count > 2 {
            let t = fieldText(columns[2])
            let hasLink = columns[2].contains { $0["navigationEndpoint"] != nil }
            if isPlayCount(t), !hasLink { playCount = t.split(separator: " ").dropLast().joined(separator: " ").nilIfEmpty ?? t }
            else if album == nil, !t.isEmpty, !YTMJSON.isDuration(t), !isPlayCount(t) { album = MusicAlbumRef(id: t, title: t) }
        }
        if album == nil, !f.isVideo, fieldsAll.count > 1 {
            let t = fieldText(fieldsAll[1])
            if !t.isEmpty, !YTMJSON.isDuration(t), !isPlayCount(t) { album = MusicAlbumRef(id: t, title: t) }
        }
        let albumID = YTMJSON.find("browseEndpoint", in: item).compactMap { $0.str("browseId") }.first { $0.hasPrefix("MPRE") }
        if var a = album, a.id == a.title, let albumID { a.id = albumID; album = a }

        var setVideoID: String?
        if YTMJSON.contains("ACTION_REMOVE_VIDEO", in: item["menu"]) { setVideoID = item.dict("playlistItemData")?.str("playlistSetVideoId") }

        let thumbs = YTMJSON.thumbnails(in: item["thumbnail"])
        var t = MusicTrack(id: videoID, providerID: YTM.providerID, title: title, durationMs: durationMs ?? 0, artists: artists, album: album,
                           thumbnails: thumbs, explicit: isExplicit(item), externalURL: "https://music.youtube.com/watch?v=\(videoID)")
        t.videoID = videoID
        t.isVideo = videoFlag(of: item)
        if f.isEpisode { t.isPodcast = true }
        let rating = YTMJSON.firstString("likeStatus", in: item)
        let olak = YTMJSON.allStrings("playlistId", in: item).first { $0.hasPrefix("OLAK5uy_") }
        return YTMRow(track: t, isVideo: f.isVideo && !f.isEpisode, isUpload: f.isUpload, isEpisode: f.isEpisode, setVideoID: setVideoID,
                      playCount: playCount, rating: rating, albumID: albumID, audioPlaylistID: olak)
    }

    // MARK: podcast episode

    static func parseEpisode(_ item: [String: Any]) -> YTMRow? {
        let videoID = item.dict("onTap")?.dict("watchEndpoint")?.str("videoId") ?? YTMJSON.firstString("videoId", in: item["onTap"]) ?? YTMJSON.firstString("videoId", in: item["overlay"])
        let title = YTMJSON.text(item["title"])
        guard let videoID, !title.isEmpty else { return nil }
        let show = YTMJSON.text(item["secondTitle"])
        let dur = YTMJSON.first("musicPlaybackProgressRenderer", in: item).map { YTMJSON.text($0["durationText"]) }.flatMap(YTMJSON.spokenDurationMs)
        var t = MusicTrack(id: videoID, providerID: YTM.providerID, title: title, durationMs: dur ?? 0,
                           artists: show.isEmpty ? [] : [MusicArtistRef(id: show, name: show)], thumbnails: YTMJSON.thumbnails(in: item["thumbnail"] ?? item),
                           externalURL: "https://music.youtube.com/watch?v=\(videoID)")
        t.videoID = videoID; t.isPodcast = true; t.isVideo = false
        return YTMRow(track: t, isEpisode: true)
    }

    // MARK: browse targets (cards and non-song rows)

    /// Turns a browse id into an item: albums (MPRE), artists (UC) or playlists (everything else, with the leading `VL` removed).
    static func classify(browseID raw: String, title: String, subtitle: [[String: Any]], thumbs: [MusicThumbnail]) -> MusicBrowseItem? {
        var id = raw
        if id.hasPrefix("MPLA") { id = String(id.dropFirst(4)) }
        if id.hasPrefix("VLMPRE") { id = String(id.dropFirst(2)) }
        let fs = fields(subtitle)
        let labelled = fs.first.map { typeLabels.contains(fieldText($0)) } ?? false
        let rest = labelled ? Array(fs.dropFirst()) : fs
        if id.hasPrefix("MPRE") {
            var artists = rest.first(where: linksArtist).map(artistRefs) ?? []
            if artists.isEmpty, let f = rest.first(where: { !YTMJSON.isDuration(fieldText($0)) && fieldText($0).range(of: #"^\d{4}$"#, options: .regularExpression) == nil }) { artists = artistRefs(f) }
            let year = rest.map(fieldText).first { $0.range(of: #"^\d{4}$"#, options: .regularExpression) != nil }
            return .album(MusicAlbum(id: id, providerID: YTM.providerID, title: title, artists: artists, thumbnails: thumbs, releaseDate: year,
                                     albumType: labelled ? fieldText(fs[0]) : nil, externalURL: "https://music.youtube.com/browse/\(id)"))
        }
        if id.hasPrefix("UC") {
            return .artist(MusicArtist(id: id, providerID: YTM.providerID, name: title, thumbnails: thumbs, externalURL: "https://music.youtube.com/channel/\(id)"))
        }
        if id.hasPrefix("VL") { id = String(id.dropFirst(2)) }
        let owner = rest.first.map(fieldText).flatMap { $0.isEmpty ? nil : $0 }
        let summary = rest.map(fieldText).joined(separator: " \(bullet) ")
        return .playlist(MusicPlaylist(id: id, providerID: YTM.providerID, name: title, summary: summary.isEmpty ? nil : summary, owner: owner,
                                       thumbnails: thumbs, externalURL: "https://music.youtube.com/playlist?list=\(id)"))
    }

    static func parseCard(_ c: [String: Any]) -> MusicBrowseItem? {
        let title = YTMJSON.text(c["title"])
        guard !title.isEmpty else { return nil }
        let sub = YTMJSON.runs(c["subtitle"])
        let thumbs = YTMJSON.thumbnails(in: c["thumbnailRenderer"] ?? c["thumbnail"] ?? c)
        let nav = c.dict("navigationEndpoint")
        if let vid = nav?.dict("watchEndpoint")?.str("videoId") {
            let f = flags(of: c)
            let fs = dropTypeLabel(fields(sub))
            var artists: [MusicArtistRef] = []
            if let first = fs.first, !YTMJSON.isDuration(fieldText(first)) { artists = artistRefs(first) }
            let dur = fs.reversed().compactMap { YTMJSON.durationMs(fieldText($0)) }.first ?? 0
            var t = MusicTrack(id: vid, providerID: YTM.providerID, title: title, durationMs: dur, artists: artists, thumbnails: thumbs,
                               explicit: isExplicit(c), externalURL: "https://music.youtube.com/watch?v=\(vid)")
            t.videoID = vid
            t.isVideo = videoFlag(of: c)
            if f.isEpisode { t.isPodcast = true }
            return .track(t)
        }
        if let pid = nav?.dict("watchPlaylistEndpoint")?.str("playlistId") {
            return classify(browseID: "VL" + pid, title: title, subtitle: sub, thumbs: thumbs)
        }
        if let b = YTMJSON.browseID(nav) { return classify(browseID: b, title: title, subtitle: sub, thumbs: thumbs) }
        return nil
    }

    /// A list row that is not a plain song (album, artist or playlist rows in search and library grids).
    static func parseListItem(_ item: [String: Any]) -> MusicBrowseItem? {
        if item.dict("navigationEndpoint")?.dict("watchEndpoint") == nil, let b = YTMJSON.browseID(item.dict("navigationEndpoint")) {
            let columns = item.array("flexColumns").map { YTMJSON.runs($0.dict("musicResponsiveListItemFlexColumnRenderer")?.dict("text")) }
            let title = columns.first.map(fieldText) ?? ""
            guard !title.isEmpty else { return nil }
            let sub = columns.count > 1 ? columns[1] : []
            return classify(browseID: b, title: title, subtitle: sub, thumbs: YTMJSON.thumbnails(in: item["thumbnail"]))
        }
        return parseSongRow(item).map { .track($0.track) }
    }

    /// Any element of a carousel or grid.
    static func parseItem(_ container: [String: Any]) -> MusicBrowseItem? {
        if let c = container.dict("musicTwoRowItemRenderer") { return parseCard(c) }
        if let r = container.dict("musicResponsiveListItemRenderer") { return parseListItem(r) }
        if let e = container.dict("musicMultiRowListItemRenderer") { return parseEpisode(e).map { .track($0.track) } }
        return nil
    }

    static func items(inContents contents: [[String: Any]]) -> [MusicBrowseItem] { contents.compactMap(parseItem) }

    /// Cards for every two-row card in the tree; if none, list rows as cards. Duplicates removed, first copy kept.
    static func gridItems(_ root: Any?) -> [MusicBrowseItem] {
        var cards = YTMJSON.find("musicTwoRowItemRenderer", in: root).compactMap(parseCard)
        if cards.isEmpty { cards = YTMJSON.find("musicResponsiveListItemRenderer", in: root, skipping: ["musicCarouselShelfRenderer"]).compactMap(parseListItem) }
        return dedupe(cards)
    }

    static func key(_ i: MusicBrowseItem) -> String {
        switch i {
        case .track(let t): "t:" + t.id
        case .album(let a): "a:" + a.id
        case .artist(let a): "r:" + a.id
        case .playlist(let p): "p:" + p.id
        }
    }

    static func dedupe(_ items: [MusicBrowseItem]) -> [MusicBrowseItem] {
        var seen = Set<String>()
        return items.filter { seen.insert(key($0)).inserted }
    }

    /// Song rows of a tree. `shallow` stops at each row (editable playlists embed a copy of every row).
    static func songRows(_ root: Any?, shallow: Bool = false, skipping: Set<String> = []) -> [YTMRow] {
        if shallow {
            return YTMJSON.findShallow(["musicResponsiveListItemRenderer", "musicMultiRowListItemRenderer"], in: root).compactMap {
                $0.key == "musicMultiRowListItemRenderer" ? parseEpisode($0.value) : parseSongRow($0.value)
            }
        }
        return YTMJSON.find("musicResponsiveListItemRenderer", in: root, skipping: skipping).compactMap(parseSongRow)
    }
}
