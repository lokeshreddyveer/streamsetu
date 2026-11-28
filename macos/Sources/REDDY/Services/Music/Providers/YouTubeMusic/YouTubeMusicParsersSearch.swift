import Foundation

// Search results (mixed and filtered), search continuation and typeahead suggestions.

enum YTMSearchFilter: String, Sendable {
    case songs, videos, albums, artists, communityPlaylists, podcasts, live

    /// Opaque filter tokens taken from YouTube. Podcast search is not exercised by the reference; its token is the public one and unverified.
    var params: String {
        switch self {
        case .songs: "EgWKAQIIAWoKEAkQBRAKEAMQBA=="
        case .videos: "EgWKAQIQAWoKEAkQChAFEAMQBA=="
        case .albums: "EgWKAQIYAWoKEAkQChAFEAMQBA=="
        case .artists: "EgWKAQIgAWoKEAkQChAFEAMQBA=="
        case .communityPlaylists: "EgeKAQQoAEABagoQAxAEEAoQCRAF"
        case .podcasts: "EgWKAQJQAWoKEAMQBBAJEAoQBQ=="
        case .live: "EgJAAQ=="
        }
    }
}

struct YTMSearchResults: Sendable {
    var top: [MusicBrowseItem] = []
    var songs: [MusicTrack] = []
    var albums: [MusicAlbum] = []
    var artists: [MusicArtist] = []
    var playlists: [MusicPlaylist] = []
    var continuation: String? = nil

    var all: [MusicBrowseItem] {
        var seen = Set<String>(); var out: [MusicBrowseItem] = []
        let ordered: [MusicBrowseItem] = top + songs.map { .track($0) } + albums.map { .album($0) } + artists.map { .artist($0) } + playlists.map { .playlist($0) }
        for i in ordered where seen.insert(YTMItems.key(i)).inserted { out.append(i) }
        return out
    }
}

struct YTMSuggestion: Sendable, Hashable { var text: String; var isHistory: Bool }
struct YTMSuggestions: Sendable { var queries: [YTMSuggestion]; var items: [MusicBrowseItem] }

enum YTMSearchParser {
    /// A filtered search: every list row in the tree, bucketed by what it links to.
    static func parseFiltered(_ root: Any?) -> (items: [MusicBrowseItem], continuation: String?) {
        let rows = YTMJSON.find("musicResponsiveListItemRenderer", in: root).compactMap(YTMItems.parseListItem)
        return (YTMItems.dedupe(rows), YTMJSON.continuationToken(in: root))
    }

    static func parseSongs(_ root: Any?) -> (tracks: [MusicTrack], continuation: String?) {
        let rows = YTMItems.songRows(root).map(\.track)
        var seen = Set<String>()
        return (rows.filter { seen.insert($0.id).inserted }, YTMJSON.continuationToken(in: root))
    }

    /// The unfiltered search is a flat list: a top-result card shelf followed by mixed rows.
    static func parseMixed(_ root: Any?) -> YTMSearchResults {
        var res = YTMSearchResults()
        guard let section = YTMJSON.find("sectionListRenderer", in: root).first(where: { $0["contents"] is [Any] }) else { return res }
        for entry in section.array("contents") {
            if let card = entry.dict("musicCardShelfRenderer") {
                if let top = topCard(card) { res.top.append(top) }
                res.top += card.array("contents").compactMap { $0.dict("musicResponsiveListItemRenderer") }.compactMap(YTMItems.parseListItem)
            } else {
                for row in YTMJSON.find("musicResponsiveListItemRenderer", in: entry) {
                    guard let item = YTMItems.parseListItem(row) else { continue }
                    switch item {
                    case .track(let t): res.songs.append(t)
                    case .album(let a): res.albums.append(a)
                    case .artist(let a): res.artists.append(a)
                    case .playlist(let p): res.playlists.append(p)
                    }
                }
            }
        }
        res.continuation = YTMJSON.continuationToken(in: section)
        return res
    }

    private static func topCard(_ card: [String: Any]) -> MusicBrowseItem? {
        let title = YTMJSON.text(card["title"])
        guard !title.isEmpty else { return nil }
        let sub = YTMJSON.runs(card["subtitle"])
        let thumbs = YTMJSON.thumbnails(in: card["thumbnail"])
        let nav = YTMJSON.runs(card["title"]).first?.dict("navigationEndpoint") ?? card.dict("onTap") ?? card.dict("navigationEndpoint")
        if let vid = nav?.dict("watchEndpoint")?.str("videoId") {
            let fs = YTMItems.dropTypeLabel(YTMItems.fields(sub))
            var t = MusicTrack(id: vid, providerID: YTM.providerID, title: title,
                               durationMs: fs.reversed().compactMap { YTMJSON.durationMs(YTMItems.fieldText($0)) }.first ?? 0,
                               artists: fs.first.map(YTMItems.artistRefs) ?? [], thumbnails: thumbs, externalURL: "https://music.youtube.com/watch?v=\(vid)")
            t.videoID = vid
            t.isVideo = YTMItems.videoFlag(of: card)
            return .track(t)
        }
        if let b = YTMJSON.browseID(nav) { return YTMItems.classify(browseID: b, title: title, subtitle: sub, thumbs: thumbs) }
        return nil
    }

    static func parseSuggestions(_ root: Any?) -> YTMSuggestions {
        var queries: [YTMSuggestion] = []
        var items: [MusicBrowseItem] = []
        for section in YTMJSON.find("searchSuggestionsSectionRenderer", in: root) {
            for c in section.array("contents") {
                if let s = c.dict("searchSuggestionRenderer") ?? c.dict("historySuggestionRenderer") {
                    let isHistory = c.dict("historySuggestionRenderer") != nil
                    let text = s.dict("navigationEndpoint")?.dict("searchEndpoint")?.str("query") ?? YTMJSON.text(s["suggestion"])
                    if !text.isEmpty { queries.append(YTMSuggestion(text: text, isHistory: isHistory)) }
                } else if let row = c.dict("musicResponsiveListItemRenderer"), let item = YTMItems.parseListItem(row) {
                    items.append(item)
                }
            }
        }
        return YTMSuggestions(queries: queries, items: items)
    }
}
