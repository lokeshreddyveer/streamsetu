import Foundation

/// Where a picture came from and under which licence, so the UI can credit it (Commons images carry their own licences).
struct MusicImageRecord: Hashable, Sendable {
    var file: String
    var thumbnailURL: String?
    var pageURL: String?
    var licence: String?
    var author: String?
    var attributionRequired: Bool
    var credit: String?
}

/// Wikipedia article text (CC BY-SA) and Wikimedia Commons picture records: the film cast fallback when Wikidata is thin, and the one source that
/// covers the Indian-language editions (Telugu, Tamil, Hindi...) through the sitelinks Wikidata lists. Pure parsers.
enum MusicWikipediaParser {
    static let source = MusicSourceID.wikipedia

    struct Summary: Equatable, Sendable { var title: String; var extract: String; var wikidataID: String? }

    static func summary(_ data: Data) -> Summary? {
        guard let j = MusicSourceKit.json(data), let t = MusicSourceKit.string(j["title"]) else { return nil }
        return Summary(title: t, extract: (j["extract"] as? String) ?? "", wikidataID: j["wikibase_item"] as? String)
    }

    /// `action=parse&prop=wikitext&formatversion=2`.
    static func wikitext(_ data: Data) -> String? {
        ((MusicSourceKit.json(data)?["parse"] as? [String: Any])?["wikitext"] as? String)
    }

    // MARK: templates

    /// The top-level `{{...}}` templates of a text, outermost only.
    static func topLevelTemplates(_ text: String) -> [String] {
        let chars = Array(text)
        var out: [String] = []; var depth = 0; var start = 0; var i = 0
        while i + 1 < chars.count {
            if chars[i] == "{", chars[i + 1] == "{" { if depth == 0 { start = i + 2 }; depth += 1; i += 2; continue }
            if chars[i] == "}", chars[i + 1] == "}", depth > 0 { depth -= 1; if depth == 0 { out.append(String(chars[start..<i])) }; i += 2; continue }
            i += 1
        }
        return out
    }

    /// Splits at `|` outside nested templates and links.
    static func splitParams(_ body: String) -> [String] {
        var parts: [String] = []; var cur = ""; var tmpl = 0; var link = 0
        let c = Array(body); var i = 0
        while i < c.count {
            let ch = c[i], nx: Character? = i + 1 < c.count ? c[i + 1] : nil
            if ch == "{", nx == "{" { tmpl += 1; cur += "{{"; i += 2; continue }
            if ch == "}", nx == "}" { tmpl = max(0, tmpl - 1); cur += "}}"; i += 2; continue }
            if ch == "[", nx == "[" { link += 1; cur += "[["; i += 2; continue }
            if ch == "]", nx == "]" { link = max(0, link - 1); cur += "]]"; i += 2; continue }
            if ch == "|", tmpl == 0, link == 0 { parts.append(cur); cur = ""; i += 1; continue }
            cur.append(ch); i += 1
        }
        parts.append(cur)
        return parts
    }

    /// The film infobox's parameters (`starring`, `director`, `music`, ...), keys lower case. Language independent: the template that carries a
    /// `starring` or `director` parameter is the one.
    static func infobox(_ wikitext: String) -> [String: String] {
        for body in topLevelTemplates(wikitext) {
            var map: [String: String] = [:]
            for p in splitParams(body).dropFirst() {
                guard let eq = p.firstIndex(of: "=") else { continue }
                let k = p[..<eq].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let v = p[p.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !k.isEmpty, !v.isEmpty { map[k] = v }
            }
            if map["starring"] != nil || map["director"] != nil { return map }
        }
        return [:]
    }

    // MARK: names

    private static func stripMarkup(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: #"<!--.*?-->"#, with: "", options: [.regularExpression])
        s = s.replacingOccurrences(of: #"<ref[^>]*/>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<ref[^>]*>.*?</ref>"#, with: "", options: [.regularExpression])
        s = s.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"\[\[(?:[^\]|]*\|)?([^\]]*)\]\]"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "'''", with: "").replacingOccurrences(of: "''", with: "")
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return s
    }

    /// The wrappers whose content is a list of names (compared lower case, spaces and underscores ignored).
    private static let listWrappers: Set<String> = ["plainlist", "unbulletedlist", "ubl", "flatlist", "hlist", "bulletedlist", "collapsiblelist"]

    /// `value` with each list wrapper replaced by its (recursively cleaned) content on its own lines, and every other `{{...}}` template removed with all it holds.
    static func unwrapLists(_ value: String) -> String {
        let c = Array(value)
        func at(_ i: Int, _ t: String) -> Bool { i + t.count <= c.count && String(c[i..<(i + t.count)]) == t }
        var out = ""
        var i = 0
        while i < c.count {
            guard at(i, "{{") else { out.append(c[i]); i += 1; continue }
            // the template's end: the matching `}}`
            var depth = 0, j = i
            while j < c.count {
                if at(j, "{{") { depth += 1; j += 2 } else if at(j, "}}") { depth -= 1; j += 2; if depth == 0 { break } } else { j += 1 }
            }
            let end = min(j, c.count)
            let inner = Array(c[(i + 2)..<max(i + 2, end - (at(end - 2, "}}") ? 2 : 0))])
            let bar = inner.firstIndex(of: "|") ?? inner.count
            let name = String(inner[..<bar]).lowercased().filter { $0.isLetter }
            if listWrappers.contains(name), bar < inner.count { out += "\n" + unwrapLists(String(inner[(bar + 1)...])) + "\n" }
            i = end
        }
        return out
    }

    /// People named in an infobox value: links, line lists, `{{Plainlist}}` and `{{ubl}}`, or a comma list. Parenthetical roles are cut.
    static func names(fromInfobox value: String) -> [String] {
        // Only list wrappers carry names. Any other template inside the value (a nested `{{Infobox | child = yes ...}}` row, a citation, a date) is dropped whole:
        // its name and parameters are not people (the Telugu film pages put such child rows after `producer` and `music`, which once became a person called "Infobox").
        var s = unwrapLists(value)
        // `|` between list items (ubl) is a separator once the links are flattened.
        s = stripMarkup(s)
        s = s.replacingOccurrences(of: "|", with: "\n").replacingOccurrences(of: "*", with: "\n")
        var out: [String] = []
        for line in s.split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == ";" || $0 == "،" }) {
            var n = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if let p = n.firstIndex(of: "(") { n = String(n[..<p]).trimmingCharacters(in: .whitespaces) }
            n = n.replacingOccurrences(of: " and ", with: "\n")
            for piece in n.split(separator: "\n") {
                let name = piece.trimmingCharacters(in: .whitespaces)
                if name.count >= 2, name.count <= 60, !name.contains("="), !out.contains(name) { out.append(name) }
            }
        }
        return out
    }

    struct CastRow: Equatable, Sendable { var name: String; var character: String? }

    /// The `== Cast ==` section: `* [[Name]] as Character` rows, in billing order.
    static func castList(_ wikitext: String) -> [CastRow] {
        guard let r = wikitext.range(of: #"\n==+\s*Cast[^=\n]*==+"#, options: .regularExpression) else { return [] }
        let rest = wikitext[r.upperBound...]
        let end = rest.range(of: #"\n==[^=]"#, options: .regularExpression)?.lowerBound ?? rest.endIndex
        var rows: [CastRow] = []
        for line in rest[..<end].split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("*") else { continue }
            let body = stripMarkup(String(t.drop { $0 == "*" || $0 == " " }))
            var name = body; var character: String?
            for sep in [" as ", " – ", " - ", " — "] {
                if let rr = body.range(of: sep) { name = String(body[..<rr.lowerBound]); character = String(body[rr.upperBound...]).trimmingCharacters(in: .whitespaces); break }
            }
            name = name.trimmingCharacters(in: .whitespaces)
            if name.count >= 2, name.count <= 60 { rows.append(CastRow(name: name, character: character.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) })) }
        }
        return rows
    }

    // MARK: film batch

    /// A film's cast, director and music from one article. People are name-only (`nameOnly`): the resolver matches them to people Wikidata already
    /// gave, and never merges two persons by name alone. Confidence is lower than Wikidata's (0.7), the licence CC BY-SA, the attribution "Wikipedia".
    static func film(wikitext: String, lang: String, article: String, film: MusicDraftRef, retrievedAt: Date = Date(), castLimit: Int = 30) -> MusicClaimBatch {
        var b = MusicClaimBatch(source: source, license: .ccBySa, retrievedAt: retrievedAt, attribution: "Wikipedia")
        let box = infobox(wikitext)
        let rows = castList(wikitext)
        func add(_ names: [(String, String?)], _ pred: MusicPredicate, _ role: MusicRole, evidence: String) {
            for (i, (n, ch)) in names.prefix(castLimit).enumerated() {
                var d = MusicEntityDraft(kind: .person, name: n, attrs: ["nameOnly": "1", "wikipediaLang": lang], aliases: [], provisional: true)
                let key = "wikipedia|" + lang + "|" + article + "|" + MusicGraphText.latin(n)
                d.externalIDs = [ExternalID(.canon, key)]
                let r = MusicDraftRef.local(.person, key)
                if !b.drafts.contains(where: { $0.ref == r }) { b.drafts.append(MusicSourceDraft(r, d)) }
                var a = EdgeAttributes(); a.characterName = ch; if pred == .hasCast { a.creditOrder = i }
                var c = MusicClaimDraft(subject: film, predicate: pred, object: r, role: role, attributes: a, order: pred == .hasCast ? i : nil, creditLevel: .film, confidence: 0.7,
                                        evidence: ["wikipedia-" + evidence, lang + "wiki"], sourceRef: lang + "wiki:" + article)
                c.attribution = "Wikipedia"
                b.claims.append(c)
            }
        }
        if !rows.isEmpty { add(rows.map { ($0.name, $0.character) }, .hasCast, .actor, evidence: "cast-section") }
        else if let s = box["starring"] { add(names(fromInfobox: s).map { ($0, nil) }, .hasCast, .actor, evidence: "infobox") }
        if let s = box["director"] { add(names(fromInfobox: s).map { ($0, nil) }, .directedBy, .director, evidence: "infobox") }
        if let s = box["music"] { add(names(fromInfobox: s).map { ($0, nil) }, .composedBy, .composer, evidence: "infobox") }
        if let s = box["producer"] { add(names(fromInfobox: s).prefix(3).map { ($0, nil) }, .producedBy, .producer, evidence: "infobox") }
        return b
    }

    // MARK: article search and soundtrack articles

    /// `generator=search&prop=pageprops|description`: pages with their Wikidata item and short description ("2010 soundtrack album by ..."), as candidates.
    static func articleSearch(_ data: Data, retrievedAt: Date = Date()) -> MusicClaimBatch {
        var b = MusicClaimBatch(source: source, license: .ccBySa, retrievedAt: retrievedAt, attribution: "Wikipedia"); b.isSearch = true
        let pages = (((MusicSourceKit.json(data)?["query"] as? [String: Any])?["pages"] as? [[String: Any]]) ?? []).sorted { ($0["index"] as? Int ?? 99) < ($1["index"] as? Int ?? 99) }
        for p in pages {
            guard let title = MusicSourceKit.string(p["title"]), let q = (p["pageprops"] as? [String: Any])?["wikibase_item"] as? String else { continue }
            let desc = (p["description"] as? String) ?? ""
            let l = desc.lowercased()
            let kind: MusicEntityKind = l.contains("soundtrack") || l.contains("album") ? .album : (l.contains("film") ? .film : .person)
            guard kind != .person else { continue }
            let year = desc.range(of: #"(?:18|19|20)\d\d"#, options: .regularExpression).flatMap { Int(desc[$0]) }
            b.drafts.append(MusicSourceDraft(.external(kind, ExternalID(.wikidata, q)),
                                             MusicEntityDraft(kind: kind, name: title, subkind: kind == .album ? MusicAlbumSubkind.soundtrack.rawValue : nil, year: year,
                                                              attrs: ["description": desc, "article": title], externalIDs: [ExternalID(.wikidata, q)])))
        }
        return b
    }

    /// The film a soundtrack article names in its lead ("the soundtrack to the 2010 Indian Tamil-language film [[Paiyaa|of the same name]]"): the article title.
    static func soundtrackFilmTitle(_ wikitext: String) -> String? {
        let lead = stripTemplates(wikitext)
        guard let r = lead.range(of: #"(?:soundtrack|score|album)[^.\n]{0,160}?\bfilm\s+\[\[([^\]|#]+)"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let m = String(lead[r])
        guard let o = m.range(of: "[[", options: .backwards) else { return nil }
        let t = m[o.upperBound...].trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    private static func stripTemplates(_ s: String) -> String {
        var out = ""; var depth = 0; let c = Array(s); var i = 0
        while i < c.count {
            if i + 1 < c.count, c[i] == "{", c[i + 1] == "{" { depth += 1; i += 2; continue }
            if i + 1 < c.count, c[i] == "}", c[i + 1] == "}", depth > 0 { depth -= 1; i += 2; continue }
            if depth == 0 { out.append(c[i]) }
            i += 1
        }
        return out
    }

    /// `prop=pageprops&ppprop=wikibase_item`: the Wikidata item of one article.
    static func pageItem(_ data: Data) -> (title: String, qid: String, description: String)? {
        guard let p = (((MusicSourceKit.json(data)?["query"] as? [String: Any])?["pages"] as? [[String: Any]]) ?? []).first,
              let t = MusicSourceKit.string(p["title"]), let q = (p["pageprops"] as? [String: Any])?["wikibase_item"] as? String else { return nil }
        return (t, q, (p["description"] as? String) ?? "")
    }

    // MARK: Commons

    private static func plain(_ html: String?) -> String? {
        guard let h = html else { return nil }
        let t = h.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// `action=query&prop=imageinfo&iiprop=url|extmetadata&iiurlwidth=N`: the thumbnail address and the licence record.
    static func commonsImage(_ data: Data, file: String) -> MusicImageRecord? {
        guard let page = (((MusicSourceKit.json(data)?["query"] as? [String: Any])?["pages"] as? [[String: Any]]) ?? []).first,
              let info = (page["imageinfo"] as? [[String: Any]])?.first else { return nil }
        let meta = (info["extmetadata"] as? [String: Any]) ?? [:]
        func m(_ k: String) -> String? { (meta[k] as? [String: Any])?["value"] as? String }
        let required = (m("AttributionRequired") ?? "").lowercased() == "true"
        return MusicImageRecord(file: file, thumbnailURL: (info["thumburl"] as? String).map(secure), pageURL: info["descriptionurl"] as? String,
                                licence: m("LicenseShortName") ?? m("UsageTerms"), author: plain(m("Artist")), attributionRequired: required, credit: plain(m("Credit")))
    }

    private static func secure(_ u: String) -> String { u.hasPrefix("http://") ? "https://" + u.dropFirst(7) : u }

    /// A Commons thumbnail address built from a file name alone (`Special:FilePath`), for when no record was fetched.
    static func commonsThumbnailURL(file: String, width: Int = 200) -> URL? {
        var c = URLComponents(string: "https://commons.wikimedia.org/wiki/Special:FilePath/")
        c?.path = "/wiki/Special:FilePath/" + file.replacingOccurrences(of: " ", with: "_")
        c?.queryItems = [URLQueryItem(name: "width", value: String(width))]
        return c?.url
    }
}

struct WikipediaSource: MusicMetadataSource {
    var transport: any MusicMetadataTransport
    var id: MusicSourceID { .wikipedia }

    var policy: MusicSourcePolicy {
        MusicSourcePolicy(hosts: ["en.wikipedia.org", "te.wikipedia.org", "ta.wikipedia.org", "hi.wikipedia.org", "ml.wikipedia.org", "kn.wikipedia.org", "bn.wikipedia.org", "commons.wikimedia.org"],
                          license: .ccBySa, retention: nil, attribution: "Wikipedia", ttl: [MusicFacet.filmCredits: 30 * 86_400], defaultTTL: 30 * 86_400, defaultOn: true,
                          privacyNote: "Film titles and article names are sent to Wikipedia and Wikimedia Commons (wikipedia.org, wikimedia.org) to read cast lists and portraits. No account, and never your listening history.")
    }

    /// The articles to read, from a film's sitelinks: the English edition only (owner rule: no Hindi, Telugu, Tamil or other editions). The `language` argument is
    /// kept so callers do not change, and is ignored.
    static func articles(sitelinks: [String: String], language: String?) -> [(lang: String, title: String)] {
        sitelinks["enwiki"].map { [("en", $0)] } ?? []
    }

    private func api(_ lang: String) -> URL { URL(string: "https://\(lang).wikipedia.org/w/api.php")! }

    func fetch(_ r: MusicSourceRequest, context: MusicFetchContext) async throws -> MusicClaimBatch {
        let now = context.now()
        if r.facet == "articleSearch" {
            guard let q = r.param("query") else { throw MusicSourceError.badRequest("query") }
            let d = try await transport.get(api(r.param("lang") ?? "en"), query: ["action": "query", "generator": "search", "gsrsearch": q, "gsrlimit": "6", "prop": "pageprops|description", "ppprop": "wikibase_item",
                                                                              "format": "json", "formatversion": "2"], headers: MusicSourceKit.headers)
            return MusicWikipediaParser.articleSearch(d, retrievedAt: now)
        }
        if r.facet == "soundtrackFilm" {
            // A soundtrack article names its film in the lead sentence; the film's article gives the Wikidata item.
            guard let lang = r.param("lang"), lang.allSatisfy({ $0.isLetter }), let title = r.param("article") else { throw MusicSourceError.badRequest("article") }
            let d = try await transport.get(api(lang), query: ["action": "parse", "page": title, "prop": "wikitext", "section": "0", "format": "json", "formatversion": "2", "redirects": "1"], headers: MusicSourceKit.headers)
            var b = MusicClaimBatch(source: .wikipedia, license: .ccBySa, retrievedAt: now, attribution: "Wikipedia")
            guard let text = MusicWikipediaParser.wikitext(d), let filmTitle = MusicWikipediaParser.soundtrackFilmTitle(text) else { return b }
            let p = try await transport.get(api(lang), query: ["action": "query", "titles": filmTitle, "prop": "pageprops|description", "ppprop": "wikibase_item", "redirects": "1", "format": "json", "formatversion": "2"], headers: MusicSourceKit.headers)
            guard let item = MusicWikipediaParser.pageItem(p) else { return b }
            let fref = MusicDraftRef.external(.film, ExternalID(.wikidata, item.qid))
            b.drafts.append(MusicSourceDraft(fref, MusicEntityDraft(kind: .film, name: item.title, attrs: ["description": item.description, "article": item.title], externalIDs: [ExternalID(.wikidata, item.qid)])))
            if let q = r.param("albumQid") {
                let a = MusicDraftRef.external(.album, ExternalID(.wikidata, q))
                var c = MusicClaimDraft(subject: a, predicate: .soundtrackOf, object: fref, creditLevel: .film, confidence: 0.85, evidence: ["wikipedia-soundtrack-article"], stated: true, sourceRef: lang + "wiki:" + title)
                c.attribution = "Wikipedia"
                b.drafts.append(MusicSourceDraft(a, MusicEntityDraft(kind: .album, name: title, subkind: MusicAlbumSubkind.soundtrack.rawValue, externalIDs: [ExternalID(.wikidata, q)])))
                b.claims.append(c)
            }
            return b
        }
        guard r.facet == MusicFacet.filmCredits else { throw MusicSourceError.unsupported(r.facet) }
        guard let lang = r.param("lang"), lang.allSatisfy({ $0.isLetter }), lang.count <= 3, let title = r.param("article") else { throw MusicSourceError.badRequest("article") }
        let filmRef: MusicDraftRef
        if let q = r.param("qid") { filmRef = .external(.film, ExternalID(.wikidata, q)) } else { filmRef = .local(.film, r.param("filmKey") ?? title) }
        let d = try await transport.get(api(lang), query: ["action": "parse", "page": title, "prop": "wikitext", "format": "json", "formatversion": "2", "redirects": "1"], headers: MusicSourceKit.headers)
        guard let text = MusicWikipediaParser.wikitext(d) else { throw MusicError.network("unexpected reply") }
        return MusicWikipediaParser.film(wikitext: text, lang: lang, article: title, film: filmRef, retrievedAt: now)
    }

    /// The thumbnail and licence record of a Commons file (a person's portrait through Wikidata P18). Nothing is downloaded or stored.
    func image(file: String, width: Int = 200) async throws -> MusicImageRecord? {
        let d = try await transport.get(URL(string: "https://commons.wikimedia.org/w/api.php")!,
                                        query: ["action": "query", "titles": "File:" + file, "prop": "imageinfo", "iiprop": "url|extmetadata", "iiurlwidth": String(width), "format": "json", "formatversion": "2"],
                                        headers: MusicSourceKit.headers)
        return MusicWikipediaParser.commonsImage(d, file: file)
    }
}
