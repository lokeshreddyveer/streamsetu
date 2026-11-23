import Foundation

/// Our canonical channel genres (a derived tag; the provider's own category is never edited).
enum GuideCategoryMapper {
    static let map: [String: String] = [
        "general": "general", "news": "news", "sports": "sports", "entertainment": "entertainment", "movies": "movies", "classic": "movies", "series": "series",
        "kids": "kids", "animation": "kids", "family": "kids", "music": "music", "comedy": "entertainment",
        "documentary": "factual", "science": "factual", "education": "factual", "culture": "factual", "travel": "factual", "outdoor": "factual", "auto": "factual", "cooking": "factual", "lifestyle": "factual", "relax": "factual",
        "religious": "religious", "business": "news", "legislative": "news", "public": "news", "weather": "news", "shop": "shopping", "interactive": "other",
    ]
    /// First mapped key of a database record. "xxx" never maps (adult is a hard gate, not a genre).
    static func genre(_ categories: [String]) -> String? {
        for c in categories where c != "xxx" { if let g = map[c] { return g } }
        return nil
    }
}

/// Logo choice in one place: the person's choice, then the playlist's logo (if it is known to load), then the guide icon, then the public database (URL only, loaded through ImageCache), then a generated tile (nil).
enum GuideLogoResolver {
    struct Inputs: Sendable { var userChoice: String?; var provider: String?; var providerFailed = false; var guideIcon: String?; var enrichment: String? }
    static func resolve(_ i: Inputs) -> (url: String?, source: String) {
        if let u = i.userChoice, !u.isEmpty { return (u, "user") }
        if let p = i.provider, !p.isEmpty, !i.providerFailed { return (p, "provider") }
        if let g = i.guideIcon, g.hasPrefix("https://") { return (g, "guide") }
        if let e = i.enrichment, e.hasPrefix("https://") { return (e, "iptvorg") }
        return (nil, "generated")
    }
}

/// Applies the public channel database to the library as an overlay: `channel_enrichment` and `field_provenance`, never `channels`.
/// Locked, hidden, adult and kids-restricted channels are never matched and any earlier row for them is removed. A field the person set is never touched.
struct ChannelEnrichmentService: Sendable {
    let db: DatabaseManager

    struct Report: Sendable, Equatable { var considered = 0; var matched = 0; var logosGained = 0; var genresGained = 0; var countriesGained = 0; var languagesGained = 0; var skippedRestricted = 0 }

    static let restrictedWords = ["adult", "xxx", "18+", "porn", "erotic", "kids", "children", "junior"]

    /// Channels the feature must not touch.
    func restrictedIDs() throws -> Set<String> {
        try db.read { c in
            var out = Set(try c.query("""
                SELECT ch.id FROM channels ch WHERE ch.category_id IN (SELECT category_id FROM locked_categories)
                   OR ch.id IN (SELECT item_id FROM hidden_items) OR ch.category_id IN (SELECT item_id FROM hidden_items)
                """) { $0.string(0) })
            for r in try c.query("SELECT id, COALESCE(category_name,''), name FROM channels") { ($0.string(0), $0.string(1).lowercased(), $0.string(2).lowercased()) } {
                if Self.restrictedWords.contains(where: { r.1.contains($0) || r.2.contains($0) }) { out.insert(r.0) }
            }
            return out
        }
    }

    @discardableResult
    func apply(index: IPTVOrgIndex, fillLogos: Bool = true, fillGenres: Bool = true, fillCountryLanguage: Bool = true, now: Date = Date()) throws -> Report {
        let restricted = try restrictedIDs()
        struct Row { var id, name: String; var tvg: String?; var country, language, logo: String? }
        let rows = try db.read { c in try c.query("SELECT id, name, epg_id, country, language, logo_url FROM channels WHERE is_primary=1") { Row(id: $0.string(0), name: $0.string(1), tvg: $0.optString(2), country: $0.optString(3), language: $0.optString(4), logo: $0.optString(5)) } }
        let locked = Set(try db.read { c in try c.query("SELECT channel_id FROM field_provenance WHERE user_locked=1") { $0.string(0) } })
        var rep = Report()
        try db.write { c in
            // Anything stored for channels that are restricted now is removed.
            for id in restricted { try c.execute("DELETE FROM channel_enrichment WHERE channel_id=?", [id]); try c.execute("DELETE FROM field_provenance WHERE channel_id=? AND source='iptvorg'", [id]) }
            let upsert = try c.prepare("""
                INSERT INTO channel_enrichment(channel_id, db_id, logo_url, logo_src, category_key, country, language, tz, matched_by, confidence, blocked, fetched_at) VALUES(?,?,?,?,?,?,?,?,?,?,0,?)
                ON CONFLICT(channel_id) DO UPDATE SET db_id=excluded.db_id, logo_url=excluded.logo_url, logo_src=excluded.logo_src, category_key=excluded.category_key, country=excluded.country, language=excluded.language,
                    tz=excluded.tz, matched_by=excluded.matched_by, confidence=excluded.confidence, fetched_at=excluded.fetched_at
                """)
            let prov = try c.prepare("INSERT OR REPLACE INTO field_provenance(channel_id, field, value, source, confidence, user_locked, updated_at) VALUES(?,?,?,'iptvorg',?,0,?)")
            for r in rows {
                if restricted.contains(r.id) { rep.skippedRestricted += 1; continue }
                rep.considered += 1
                guard let e = IPTVOrgEnricher.match(name: r.name, tvgID: r.tvg, country: r.country, restricted: false, index: index) else {
                    try c.execute("DELETE FROM channel_enrichment WHERE channel_id=?", [r.id]); continue
                }
                rep.matched += 1
                let hasLogo = !(r.logo ?? "").isEmpty
                let logo = fillLogos && !locked.contains(r.id) ? e.logoURL : nil
                let genre = fillGenres ? GuideCategoryMapper.genre(e.categories) : nil
                let country = fillCountryLanguage && (r.country ?? "").isEmpty ? e.country?.lowercased() : nil
                let lang = fillCountryLanguage && (r.language ?? "").isEmpty ? e.languages.first : nil
                try upsert.run([r.id, e.dbID, logo, logo == nil ? nil : "iptvorg", genre, country, lang, e.timezones.first, e.matchedBy, e.confidence, now])
                if logo != nil, !hasLogo { rep.logosGained += 1; try prov.run([r.id, "logo", logo, e.confidence, now]) }
                if let genre { rep.genresGained += 1; try prov.run([r.id, "category", genre, e.confidence * 0.8, now]) }
                if let country { rep.countriesGained += 1; try prov.run([r.id, "country", country, e.confidence, now]) }
                if let lang { rep.languagesGained += 1; try prov.run([r.id, "language", lang, e.confidence, now]) }
            }
        }
        return rep
    }

    /// Bulk read for list screens (one query, no per-row lookups).
    func overlays(for ids: [String]) throws -> [String: (logo: String?, genre: String?, country: String?, language: String?)] {
        var out: [String: (String?, String?, String?, String?)] = [:]
        for chunk in ids.chunked(into: 400) {
            let marks = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try db.read { c in try c.query("SELECT channel_id, logo_url, category_key, country, language FROM channel_enrichment WHERE channel_id IN (\(marks))", chunk.map { $0 as (any SQLConvertible)? }) { ($0.string(0), $0.optString(1), $0.optString(2), $0.optString(3), $0.optString(4)) } }
            for r in rows { out[r.0] = (r.1, r.2, r.3, r.4) }
        }
        return out
    }

    /// "Undo all enrichment".
    func undoAll() throws { try db.write { c in try c.execute("DELETE FROM channel_enrichment"); try c.execute("DELETE FROM field_provenance WHERE source='iptvorg'") } }
}
