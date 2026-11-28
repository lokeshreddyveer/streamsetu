import Foundation

// Home feed, moods and genres, and the charts/explore landing page.

enum YTMShelfKind: String, Sendable, CaseIterable {
    case listenAgain = "listen_again", listenTogether = "listen_together", quickPicks = "quick_picks", fromLibrary = "from_library"
    case community, forgotten, freshFinds = "fresh_finds", albumsForYou = "albums_for_you", trending
    case featuredPlaylists = "featured_playlists", newReleases = "new_releases", mixedForYou = "mixed_for_you"
    case dailyDiscover = "daily_discover", musicVideos = "music_videos"

    /// English wordings. Other languages are matched by `extraTitles` supplied at run time, because YouTube rewords these now and then.
    static let titles: [String: YTMShelfKind] = [
        "listen again": .listenAgain, "listen together": .listenTogether, "quick picks": .quickPicks, "song mixes": .quickPicks,
        "from your library": .fromLibrary, "from the community": .community, "forgotten favorites": .forgotten, "forgotten favourites": .forgotten,
        "fresh finds, old favorites": .freshFinds, "albums for you": .albumsForYou, "trending songs for you": .trending,
        "featured playlists for you": .featuredPlaylists, "new releases": .newReleases, "mixed for you": .mixedForYou,
        "your daily discover": .dailyDiscover, "music videos for you": .musicVideos
    ]
    static let moreTargets: [String: YTMShelfKind] = [
        "FEmusic_library_landing": .fromLibrary, "FEmusic_new_releases_albums": .newReleases, "FEmusic_mixed_for_you": .mixedForYou
    ]

    static func classify(title: String, moreBrowseID: String?, extraTitles: [String: YTMShelfKind] = [:]) -> YTMShelfKind? {
        if let m = moreBrowseID, let k = moreTargets[m] { return k }
        let t = title.trimmingCharacters(in: .whitespaces).lowercased()
        return titles[t] ?? extraTitles[t]
    }
}

struct YTMChip: Sendable, Hashable { var title: String; var params: String }

struct YTMShelf: Sendable, Identifiable {
    var id: String
    var title: String
    var kind: YTMShelfKind?
    var items: [MusicBrowseItem]
    var moreBrowseID: String? = nil
    var moreParams: String? = nil
    var browseSection: MusicBrowseSection { MusicBrowseSection(id: id, title: title, items: items) }
}

struct YTMHomePage: Sendable {
    var chips: [YTMChip]
    var shelves: [YTMShelf]
    var continuation: String?
}

struct YTMMoodTile: Sendable, Hashable { var title: String; var params: String; var colorHex: String }
struct YTMMoodSection: Sendable { var title: String; var tiles: [YTMMoodTile] }

enum YTMHomeParser {
    static func parseHome(_ root: Any?, extraTitles: [String: YTMShelfKind] = [:]) -> YTMHomePage {
        let chips: [YTMChip] = YTMJSON.find("chipCloudChipRenderer", in: root).compactMap { c in
            let title = YTMJSON.text(c["text"])
            guard !title.isEmpty, let p = c.dict("navigationEndpoint")?.dict("browseEndpoint")?.str("params") else { return nil }
            return YTMChip(title: title, params: p)
        }
        return YTMHomePage(chips: chips, shelves: shelves(root, extraTitles: extraTitles, includeRowShelves: true), continuation: YTMJSON.continuationToken(in: root))
    }

    /// Every carousel shelf with at least one parsed item. Also used for home continuation replies.
    static func shelves(_ root: Any?, extraTitles: [String: YTMShelfKind] = [:], idPrefix: String = "shelf", includeRowShelves: Bool = false) -> [YTMShelf] {
        var out: [YTMShelf] = []
        for (i, c) in YTMJSON.find("musicCarouselShelfRenderer", in: root).enumerated() {
            let header = c.dict("header")?.dict("musicCarouselShelfBasicHeaderRenderer")
            let title = YTMJSON.text(header?["title"])
            let items = YTMItems.items(inContents: c.array("contents"))
            guard !items.isEmpty else { continue }
            let more = YTMJSON.first("browseEndpoint", in: header?["moreContentButton"])
            let moreID = more?.str("browseId")
            let kind = YTMShelfKind.classify(title: title, moreBrowseID: moreID, extraTitles: extraTitles)
            out.append(YTMShelf(id: kind?.rawValue ?? "\(idPrefix)-\(i)", title: title, kind: kind, items: items, moreBrowseID: moreID, moreParams: more?.str("params")))
        }
        // Episode rows on the home feed arrive as their own shelf type.
        for (i, s) in (includeRowShelves ? YTMJSON.find("musicShelfRenderer", in: root) : []).enumerated() {
            let items = YTMItems.items(inContents: s.array("contents"))
            guard !items.isEmpty else { continue }
            out.append(YTMShelf(id: "\(idPrefix)-s\(i)", title: YTMJSON.text(s["title"]), kind: nil, items: items))
        }
        return out
    }

    // MARK: moods and genres

    static func parseMoods(_ root: Any?) -> [YTMMoodSection] {
        YTMJSON.find("gridRenderer", in: root).compactMap { g in
            let title = YTMJSON.text(g.dict("header")?.dict("gridHeaderRenderer")?["title"])
            guard !title.isEmpty else { return nil }
            let tiles: [YTMMoodTile] = YTMJSON.find("musicNavigationButtonRenderer", in: g).compactMap { b in
                let name = YTMJSON.text(b["buttonText"])
                guard !name.isEmpty, let params = YTMJSON.first("browseEndpoint", in: b["clickCommand"])?.str("params") else { return nil }
                let argb = (b.dict("solid")?["leftStripeColor"] as? NSNumber)?.uint64Value ?? 0
                return YTMMoodTile(title: name, params: params, colorHex: String(format: "#%06x", UInt32(argb & 0xFFFFFF)))
            }
            return tiles.isEmpty ? nil : YTMMoodSection(title: title, tiles: tiles)
        }
    }

    // MARK: charts / explore

    /// The countries YouTube Music really has a chart for, read from the charts page's own country menu (each option carries its code inside an encoded key). A country
    /// that is not in it gets no chart when asked for: YouTube answers such a request with a mix of other countries' lists, which must never be shown under that country's name.
    static func chartCountries(_ root: Any?) -> Set<String> {
        var out = Set<String>()
        for item in YTMJSON.find("musicMultiSelectMenuItemRenderer", in: root) {
            guard let key = item["formItemEntityKey"] as? String, let decoded = key.removingPercentEncoding else { continue }
            var b64 = decoded; while b64.count % 4 != 0 { b64 += "=" }
            guard let data = Data(base64Encoded: b64), let text = String(data: data, encoding: .isoLatin1), let r = text.range(of: #"menu_\d+([A-Z]{2})"#, options: .regularExpression) else { continue }
            out.insert(String(text[r].suffix(2)))
        }
        out.remove("ZZ")
        return out
    }

    /// The explore landing page (`FEmusic_explore`) and the charts page (`FEmusic_charts`) are ordinary carousel pages; charts also carry
    /// ranked song lists as shelves of rows. Parsed from the public shapes of those pages; not exercised against the live service.
    static func parseExplore(_ root: Any?) -> [YTMShelf] {
        var out = shelves(root, idPrefix: "explore")
        for (i, s) in YTMJSON.find("musicShelfRenderer", in: root).enumerated() {
            let rows = YTMItems.songRows(s["contents"]).map { MusicBrowseItem.track($0.track) }
            if !rows.isEmpty { out.append(YTMShelf(id: "explore-r\(i)", title: YTMJSON.text(s["title"]), kind: nil, items: rows)) }
        }
        return out
    }
}
