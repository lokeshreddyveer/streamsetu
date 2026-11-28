import Foundation

/// YouTube Music. An album page header links its artists (channel ids starting `UC`) and says `Album/Single/EP, year`. The song's own "Song credits"
/// panel is a separate browse page (`MUSIC_PAGE_TYPE_TRACK_CREDITS`, id `MPTCp<videoId>`) that the `next` reply points to; it answers without a
/// sign-in and lists "Performed by", "Written by" and "Produced by". Not every song has one, and the section titles are in the request language
/// (English is asked for), so a title this file does not know is left out rather than guessed.
enum YouTubeMusicCreditMapper {
    static let sourceID = "ytmusic"

    /// Album-level performers from the artists the album header linked, plus the year and type it shows.
    static func albumBundle(artists: [MusicArtistRef], year: String?) -> MusicCreditBundle? {
        var c = MusicCreditCollector()
        for a in artists where a.id.hasPrefix("UC") { c.add(a.name, role: .primary, id: a.id, level: .album) }
        var h = MusicProviderHints()
        h.year = MusicProviderHints.year(year)
        return c.bundle(hints: h.isEmpty ? nil : h)
    }

    /// The credits page id a `next` reply points to for its song, nil when the song has none.
    static func creditsBrowseID(inNext root: Any?) -> String? {
        var found: String?
        YTMJSON.walk(root) { key, value in
            if key == "browseEndpoint", let e = value as? [String: Any], let id = e.str("browseId"), id.hasPrefix("MPTC"),
               YTMJSON.firstString("pageType", in: e) == "MUSIC_PAGE_TYPE_TRACK_CREDITS" { found = id; return false }
            return found == nil
        }
        return found
    }

    /// The credits of the dialog the credits page returns.
    static func parseCredits(_ root: Any?) -> [MusicCredit] {
        var c = MusicCreditCollector()
        let sections = YTMJSON.find("dismissableDialogContentSectionRenderer", in: root)
        for s in sections {
            guard let role = role(forTitle: YTMJSON.text(s["title"])) else { continue }
            for n in MusicCreditCollector.splitNames(YTMJSON.text(s["subtitle"])) { c.add(n, role: role, level: .track) }
        }
        return c.credits
    }

    static func role(forTitle title: String) -> MusicCreditRole? {
        let t = title.lowercased()
        if t.contains("perform") { return .performer }
        if t.contains("lyric") { return .lyricist }
        if t.contains("compos") { return .composer }
        if t.contains("writ") { return .writer }
        if t.contains("produc") { return .producer }
        if t.contains("arrang") { return .arranger }
        if t.contains("conduct") { return .conductor }
        return nil
    }
}
