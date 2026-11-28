import Foundation

/// IMDb's public, unofficial pages for a person: the name suggestion list, and the name page (JSON-LD for the person, the page's embedded
/// `__NEXT_DATA__` JSON for the filmography). Best effort and tolerant on purpose: IMDb publishes no schema for either, so the credits are found by
/// walking the JSON for title nodes (an `id` of the form `tt1234567` with a title text) under a `category`. Nothing is executed, sizes are capped,
/// and a refusal or challenge page is reported as `blocked` so the caller switches the source off for a while (see `MusicIMDbParser.looksBlocked`).
enum MusicPersonIMDbParser {
    static let source = MusicSourceID.imdb
    static let maxPage = 4_000_000

    struct NameHit: Sendable, Equatable { var id: String; var name: String; var known: String }

    /// `v2.sg.media-imdb.com/suggestion/<first letter>/<query>.json` rows that are people.
    static func nameHits(_ data: Data) -> [NameHit] {
        guard data.count < 600_000, let rows = MusicSourceKit.json(data)?["d"] as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard let id = r["id"] as? String, id.hasPrefix("nm"), id.dropFirst(2).allSatisfy(\.isNumber), let l = MusicSourceKit.string(r["l"]) else { return nil }
            return NameHit(id: id, name: l, known: (r["s"] as? String) ?? "")
        }
    }

    /// The JSON text of the page's `<script id="__NEXT_DATA__" ...>` block.
    static func nextData(inHTML html: String) -> Any? {
        guard html.utf8.count < maxPage, let m = html.range(of: "id=\"__NEXT_DATA__\""), let gt = html[m.upperBound...].firstIndex(of: ">"),
              let close = html[gt...].range(of: "</script>") else { return nil }
        let body = html[html.index(after: gt)..<close.lowerBound]
        return body.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    /// The name and IMDb id the page's JSON-LD `Person` block gives.
    static func person(html: String) -> (name: String, id: String?)? {
        guard let j = MusicIMDbParser.jsonLDAny(inHTML: html, types: ["Person"]), let n = MusicSourceKit.string(j["name"]) else { return nil }
        let id = (j["url"] as? String)?.split(separator: "/").first { $0.hasPrefix("nm") }.map(String.init)
        return (n, id)
    }

    private static let types: Set<String> = ["movie", "tvMovie", "tvSeries", "tvMiniSeries", "video", "short", "tvShort", "tvSpecial"]
    private static let cast: Set<String> = ["actor", "actress", "self"]
    private static let music: Set<String> = ["composer", "music_department"]

    private static func relation(_ category: String?) -> MusicPersonRelation? {
        guard let c = category?.lowercased().replacingOccurrences(of: " ", with: "_") else { return nil }
        if cast.contains(c) { return .cast }
        if c == "director" { return .director }
        if music.contains(c) || c == "music" { return .composer }
        if c == "producer" { return .producer }
        return nil
    }

    private static func text(_ v: Any?) -> String? {
        if let s = v as? String, !s.isEmpty { return s }
        if let d = v as? [String: Any] { return MusicSourceKit.string(d["text"]) ?? MusicSourceKit.string(d["value"]) }
        return nil
    }

    /// Filmography credits (films, series, shorts) with the person's relation to each, deduplicated by IMDb title id.
    static func credits(html: String, retrievedAt: Date = Date()) -> [MusicPersonWork] {
        guard let root = nextData(inHTML: html) else { return [] }
        var found: [String: MusicPersonWork] = [:]
        var visited = 0
        func walk(_ node: Any, _ category: String?) {
            visited += 1
            guard visited < 200_000 else { return }
            if let arr = node as? [Any] { for x in arr { walk(x, category) }; return }
            guard let d = node as? [String: Any] else { return }
            var cat = category
            if let c = d["category"] { cat = text(c) ?? (c as? [String: Any]).flatMap { $0["id"] as? String } ?? cat }
            // a title node: the node itself or under `title` / `node`
            for key in ["title", "node"] {
                if let t = d[key] as? [String: Any], let w = title(t, relation: relation(cat), at: retrievedAt) { merge(w) }
            }
            if let w = title(d, relation: relation(cat), at: retrievedAt) { merge(w) }
            for (_, v) in d where v is [String: Any] || v is [Any] { walk(v, cat) }
        }
        func merge(_ w: MusicPersonWork) {
            guard let id = w.sourceRef else { return }
            if var cur = found[id] { cur.relations.formUnion(w.relations); cur.year = cur.year ?? w.year; found[id] = cur } else { found[id] = w }
        }
        func title(_ t: [String: Any], relation rel: MusicPersonRelation?, at: Date) -> MusicPersonWork? {
            guard let id = t["id"] as? String, id.hasPrefix("tt"), id.dropFirst(2).allSatisfy(\.isNumber), let rel else { return nil }
            let name = text(t["titleText"]) ?? text(t["originalTitleText"]) ?? text(t["title"]) ?? text(t["name"])
            guard let name else { return nil }
            if let ty = (t["titleType"] as? [String: Any])?["id"] as? String, !types.contains(ty) { return nil }
            let y = ((t["releaseYear"] as? [String: Any])?["year"] as? Int) ?? (t["year"] as? Int) ?? (t["releaseYear"] as? Int)
            return MusicPersonWork(kind: .film, title: name, year: y.flatMap { (1880...2100).contains($0) ? $0 : nil }, relations: [rel], ids: [ExternalID(.imdbTitle, id)], source: source, sourceRef: id)
        }
        walk(root, nil)
        return found.values.sorted { ($0.year ?? 0, $0.sourceRef ?? "") > ($1.year ?? 0, $1.sourceRef ?? "") }
    }
}

extension MusicIMDbParser {
    /// First JSON-LD block whose `@type` is one of `types` (the existing `jsonLD(inHTML:)` only looks for movies).
    static func jsonLDAny(inHTML html: String, types: Set<String>) -> [String: Any]? {
        guard html.utf8.count < maxPage else { return nil }
        var rest = Substring(html)
        while let open = rest.range(of: "application/ld+json"), let gt = rest[open.upperBound...].firstIndex(of: ">"), let close = rest[gt...].range(of: "</script>") {
            let body = rest[rest.index(after: gt)..<close.lowerBound]
            if let d = body.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) {
                let cands: [[String: Any]] = (o as? [[String: Any]]) ?? ((o as? [String: Any]).map { [$0] } ?? [])
                if let hit = cands.first(where: { types.contains($0["@type"] as? String ?? "") }) { return hit }
            }
            rest = rest[close.upperBound...]
        }
        return nil
    }
}
