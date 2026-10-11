import Foundation
import CryptoKit

/// Maps Stalker / Ministra portal replies ("js" payloads) into catalog entries. Pure, so it is tested without a portal.
struct StalkerMapper: Sendable {
    let source: PlaylistSource

    func str(_ d: [String: Any], _ k: String) -> String? {
        if let s = d[k] as? String, !s.isEmpty { return s }
        if let n = d[k] as? NSNumber { return n.stringValue }
        return nil
    }

    /// "ffmpeg http://host/x" or "ffrt http://localhost/ch/12" -> "http://host/x". Nil when no address is in it.
    static func address(fromCommand cmd: String) -> String? {
        let parts = cmd.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        return parts.last(where: { $0.contains("://") })
    }

    func genres(_ js: Any?) -> [String: String] {
        var out: [String: String] = [:]
        for g in (js as? [[String: Any]]) ?? [] {
            if let id = str(g, "id"), let t = str(g, "title") ?? str(g, "name"), id != "*" { out[id] = CategoryNormalizer.clean(t) }
        }
        return out
    }

    func channels(_ list: [[String: Any]], genres: [String: String]) -> [Channel] {
        list.enumerated().compactMap { i, d in
            guard let id = str(d, "id"), let raw = str(d, "name"), let cmd = str(d, "cmd") else { return nil }
            let name = MetadataNormalizer.cleanDisplay(raw)
            let gid = str(d, "tv_genre_id")
            let cat = gid.flatMap { g in genres[g].map { (CatalogCategory.makeID(source: source.id, kind: .channel, provider: g), $0) } }
            return Channel(id: ItemID.make(source: source.id, kind: .channel, provider: id), sourceID: source.id, providerID: id, name: name,
                           normalizedName: MetadataNormalizer.normalize(name), categoryID: cat?.0, categoryName: cat?.1, logoURL: str(d, "logo").flatMap { $0.hasPrefix("http") ? $0 : nil },
                           epgID: str(d, "xmltv_id"), language: nil, country: CategoryNormalizer.countryPrefix(name),
                           resolutionHint: MetadataNormalizer.qualityLabel(MetadataNormalizer.normalize(name)),
                           sortOrder: Int(str(d, "number") ?? "") ?? i, streamRef: cmd, groupKey: nil)
        }
    }

    func movies(_ list: [[String: Any]], genres: [String: String], portal: String) -> [Movie] {
        list.compactMap { d in
            guard let id = str(d, "id"), let raw = str(d, "name"), let cmd = str(d, "cmd") else { return nil }
            if (str(d, "is_series") ?? "0") == "1" { return nil }
            let title = MetadataNormalizer.cleanDisplay(raw)
            let gid = str(d, "category_id")
            let cat = gid.flatMap { g in genres[g].map { (CatalogCategory.makeID(source: source.id, kind: .movie, provider: g), $0) } }
            return Movie(id: ItemID.make(source: source.id, kind: .movie, provider: id), sourceID: source.id, providerID: id, title: title,
                         normalizedTitle: MetadataNormalizer.normalize(title), overview: str(d, "description"), posterURL: absolute(str(d, "screenshot_uri"), portal: portal),
                         backdropURL: nil, releaseYear: Int(str(d, "year") ?? "") ?? MetadataNormalizer.year(from: title), durationSeconds: Double(str(d, "time") ?? "").map { $0 * 60 },
                         genre: str(d, "genres_str")?.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) },
                         rating: str(d, "rating_imdb") ?? str(d, "rating_kinopoisk"), categoryID: cat?.0, categoryName: cat?.1,
                         streamRef: cmd, addedAt: nil, detailFetchedAt: nil)
        }
    }

    func series(_ list: [[String: Any]], genres: [String: String], portal: String) -> [Series] {
        list.compactMap { d in
            guard let id = str(d, "id"), let raw = str(d, "name") else { return nil }
            let title = MetadataNormalizer.cleanDisplay(raw)
            let gid = str(d, "category_id")
            let cat = gid.flatMap { g in genres[g].map { (CatalogCategory.makeID(source: source.id, kind: .series, provider: g), $0) } }
            return Series(id: ItemID.make(source: source.id, kind: .series, provider: id), sourceID: source.id, providerID: id, title: title,
                          normalizedTitle: MetadataNormalizer.normalize(title), overview: str(d, "description"), posterURL: absolute(str(d, "screenshot_uri"), portal: portal),
                          backdropURL: nil, genre: str(d, "genres_str")?.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) },
                          releaseYear: Int(str(d, "year") ?? "") ?? MetadataNormalizer.year(from: title), rating: str(d, "rating_imdb"),
                          categoryID: cat?.0, categoryName: cat?.1, addedAt: nil, lastMetadataRefresh: nil)
        }
    }

    /// A series item lists its seasons, each with the episode numbers it has. The stream ref carries what `create_link` needs.
    func detail(_ item: [String: Any], series: Series) -> (seasons: [Season], episodes: [Episode]) {
        var seasons: [Season] = [], episodes: [Episode] = []
        let sid = "\(series.id)|season|"
        let seasonList = (item["series"] as? [Any]) == nil ? [] : [item]
        _ = seasonList
        // Shape A: {"series":[1,2,3], "cmd": "..."}: one season, episode numbers in "series".
        if let nums = item["series"] as? [Any], !nums.isEmpty, let cmd = str(item, "cmd") {
            seasons.append(Season(id: sid + "1", seriesID: series.id, number: 1, name: nil))
            for n in nums.compactMap({ Int("\($0)") }) {
                episodes.append(Episode(id: ItemID.make(source: source.id, kind: .episode, provider: "\(series.providerID)-1-\(n)"), seriesID: series.id, seasonID: sid + "1",
                                        seasonNumber: 1, providerEpisodeID: "\(series.providerID)-1-\(n)", episodeNumber: n, title: "Episode \(n)", overview: nil,
                                        imageURL: nil, durationSeconds: nil, streamRef: "\(cmd)#series=\(n)"))
            }
        }
        return (seasons, episodes)
    }

    func absolute(_ path: String?, portal: String) -> String? {
        guard let p = path, !p.isEmpty else { return nil }
        if p.hasPrefix("http") { return p }
        return portal + (p.hasPrefix("/") ? p : "/" + p)
    }

    /// Stable fake hardware ids derived from the MAC, so the portal sees the same "box" every time.
    static func serial(mac: String) -> String { String(SHA256.hash(data: Data(("sn" + mac.uppercased()).utf8)).map { String(format: "%02X", $0) }.joined().prefix(13)) }
    static func deviceID(mac: String) -> String { SHA256.hash(data: Data(("dev" + mac.uppercased()).utf8)).map { String(format: "%02X", $0) }.joined() }

    static func normalizedMAC(_ raw: String) -> String? {
        let hex = raw.uppercased().filter { "0123456789ABCDEF".contains($0) }
        guard hex.count == 12 else { return nil }
        return stride(from: 0, to: 12, by: 2).map { i in String(hex[hex.index(hex.startIndex, offsetBy: i)..<hex.index(hex.startIndex, offsetBy: i + 2)]) }.joined(separator: ":")
    }
}
