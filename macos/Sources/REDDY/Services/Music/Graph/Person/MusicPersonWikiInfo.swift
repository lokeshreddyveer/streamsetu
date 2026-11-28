import Foundation

/// What Wikipedia and Wikidata say about a person, for the header of their page: the opening of the Wikipedia article (in the person's language of reading when that wiki has
/// one), the person's own native language, and the portrait Wikidata names for them. The rules here are pure (no network) so they are checked on their own and hold for any person.
struct MusicPersonWikiInfo: Codable, Equatable, Sendable {
    var qid: String
    /// Wikipedia's short description ("Indian politician and actor (born 1971)").
    var description: String?
    /// The opening of the article, cut at a sentence end.
    var extract: String?
    /// The language the extract is in.
    var extractLanguage: String?
    /// ISO 639-1 of the person's native language (Wikidata P103), when stated.
    var nativeLanguage: String?
    /// The Commons file of the person's own portrait (Wikidata P18), the first one that is a picture of a person and not a poster or a logo.
    var portraitFile: String?
    var fetchedAt: Date
    /// True when a call that should have answered failed (the claims, the article or the biography), so what is here may be missing its extract. Such an answer is kept
    /// for an hour in memory only, never on disk, so one slow moment does not hide the biography for a month.
    var partial: Bool? = nil
}

enum MusicPersonWikiRules {
    /// The article titles per wiki from the entity's stored sitelinks ("enwiki:Pawan Kalyan|tewiki:పవన్ కళ్యాణ్"), keyed by the language code ("en", "te").
    static func titles(sitelinks: String?) -> [String: String] {
        var out: [String: String] = [:]
        for part in (sitelinks ?? "").split(separator: "|") {
            guard let i = part.firstIndex(of: ":") else { continue }
            let site = String(part[..<i]), title = String(part[part.index(after: i)...])
            guard site.hasSuffix("wiki"), site.count > 4, !title.isEmpty else { continue }
            let code = String(site.dropLast(4))
            guard !["commons", "wikidata", "meta", "species", "simple"].contains(code), code.allSatisfy({ $0.isLetter || $0 == "_" || $0 == "-" }) else { continue }
            out[code.replacingOccurrences(of: "_", with: "-")] = title
        }
        return out
    }

    /// Which wiki to read: the first of the person's own languages of reading (the app's languages, then the native language) that has an article, else English, else none.
    static func chooseWiki(titles: [String: String], preferred: [String]) -> (lang: String, title: String)? {
        for l in preferred { if let t = titles[l] { return (l, t) } }
        if let t = titles["en"] { return ("en", t) }
        return nil
    }

    /// The opening of an extract: up to `maxSentences` whole sentences within `maxChars`, never a cut mid-word and never a bare "born" parenthesis dump.
    static func shortExtract(_ text: String, maxSentences: Int = 2, maxChars: Int = 280) -> String? {
        let t = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        var sentences: [String] = []
        var current = ""
        let chars = Array(t)
        var i = 0
        while i < chars.count {
            current.append(chars[i])
            let c = chars[i]
            if ".!?।。".contains(c) {
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                let tail = current.dropLast().split(separator: " ").last.map(String.init) ?? ""
                // a full stop after a one-letter initial or a short title ("A. R.", "Dr.", "St.") is not the end of a sentence
                let initial = tail.count == 1 && (tail.first?.isUppercase ?? false)
                let abbreviation = c == "." && (initial || ["Mr", "Mrs", "Ms", "Dr", "St", "Jr", "Sr", "Prof"].contains(tail))
                if (next == " " || next == "\n") && !abbreviation {
                    sentences.append(current.trimmingCharacters(in: .whitespaces)); current = ""
                    if sentences.count >= 8 { break }
                }
            }
            i += 1
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty, sentences.isEmpty { sentences.append(current.trimmingCharacters(in: .whitespaces)) }
        var out = ""
        for s in sentences.prefix(maxSentences) {
            let candidate = out.isEmpty ? s : out + " " + s
            if candidate.count > maxChars { if out.isEmpty { out = cutAtWord(s, maxChars) + "…" }; break }
            out = candidate
        }
        return out.isEmpty ? nil : out
    }

    /// The first `maxChars` characters of `s`, ended at the last whole word.
    static func cutAtWord(_ s: String, _ maxChars: Int) -> String {
        guard s.count > maxChars else { return s }
        let head = String(s.prefix(maxChars))
        let nextIsSpace = s[s.index(s.startIndex, offsetBy: maxChars)] == " "
        if !nextIsSpace, let r = head.range(of: " ", options: .backwards) { return String(head[..<r.lowerBound]).trimmingCharacters(in: .whitespaces) }
        return head.trimmingCharacters(in: .whitespaces)
    }

    /// True for a Commons file that is a picture of the person: a photo, not a poster, a film still, a logo, a cover, a flag, a signature or a map. Judged from the file name,
    /// the only thing known without downloading it.
    static func isPortraitFile(_ name: String) -> Bool {
        let n = name.lowercased()
        guard ["jpg", "jpeg", "png", "webp", "tif", "tiff"].contains(where: { n.hasSuffix("." + $0) }) else { return false }
        let bad = ["poster", "film", "movie", "logo", "cover", "album", "flag", "signature", "autograph", "map", "banner", "still", "screenshot", "scene", "stamp", "symbol",
                   "emblem", "coat of arms", "wordmark", "icon", "trailer", "teaser", "promo", "ost", "soundtrack", "firstlook", "first look"]
        // Whole words only: "ost" must not reject "Elvis Costello.jpg" or "Frost".
        let stem = n.split(separator: ".").dropLast().joined(separator: ".")
        let padded = " " + stem.split(whereSeparator: { !$0.isLetter }).joined(separator: " ") + " "
        return !bad.contains { padded.contains(" " + $0 + " ") || padded.contains(" " + $0 + "s ") }
    }

    static func choosePortrait(_ files: [String]) -> String? { files.first(where: isPortraitFile) }

    // MARK: parsing the two answers

    struct Summary: Equatable, Sendable { var description: String?; var extract: String?; var isDisambiguation: Bool; var wikibaseItem: String? }

    static func parseSummary(_ data: Data) -> Summary? {
        guard let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let type = d["type"] as? String
        return Summary(description: (d["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       extract: d["extract"] as? String, isDisambiguation: type == "disambiguation", wikibaseItem: d["wikibase_item"] as? String)
    }

    struct Claims: Equatable, Sendable { var portraits: [String]; var nativeQID: String? }

    /// The biography of a TMDB person answer, empty text counting as none.
    static func parseTMDBBiography(_ data: Data) -> String? {
        guard let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let b = d["biography"] as? String else { return nil }
        let t = b.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static func parseClaims(_ data: Data, qid: String) -> Claims? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let entity = (root["entities"] as? [String: Any])?[qid] as? [String: Any],
              let claims = entity["claims"] as? [String: Any] else { return nil }
        func values(_ p: String) -> [Any] {
            ((claims[p] as? [[String: Any]]) ?? []).filter { ($0["rank"] as? String) != "deprecated" }.compactMap { (($0["mainsnak"] as? [String: Any])?["datavalue"] as? [String: Any])?["value"] }
        }
        return Claims(portraits: values("P18").compactMap { $0 as? String }, nativeQID: values("P103").compactMap { ($0 as? [String: Any])?["id"] as? String }.first)
    }

    // MARK: finding the Wikidata item of a person who has none yet

    struct SearchHit: Equatable, Sendable { var qid: String; var label: String; var description: String }

    /// `wbsearchentities` answer: `{"search":[{"id":"Q1","label":"...","description":"...","match":{"type":"label"}}]}`. Only label matches are kept.
    static func parseSearch(_ data: Data) -> [SearchHit] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let list = root["search"] as? [[String: Any]] else { return [] }
        var out: [SearchHit] = []
        for e in list {
            guard let id = e["id"] as? String, id.hasPrefix("Q"), let label = e["label"] as? String else { continue }
            if let m = (e["match"] as? [String: Any])?["type"] as? String, m != "label" { continue }
            out.append(SearchHit(qid: id, label: label, description: (e["description"] as? String) ?? ""))
        }
        return out
    }

    private static let personWords = ["singer", "vocalist", "playback", "composer", "musician", "lyricist", "songwriter", "rapper", "actor", "actress", "director", "filmmaker",
                                      "producer", "dj", "conductor", "instrumentalist", "guitarist", "pianist", "violinist", "drummer", "poet", "music director", "artist",
                                      "entertainer", "comedian", "screenwriter", "cinematographer", "veena", "flautist", "percussionist"]
    private static let groupWords = ["band", "group", "duo", "trio", "quartet", "ensemble", "orchestra", "choir", "collective", "supergroup"]
    private static let notAPerson = ["disambiguation", "album", "film by", "song by", "single by", "episode", "novel", "series", "soundtrack", "ep by", "company",
                                     "label", "village", "district", "city", "river", "video game", "magazine", "surname", "given name", "family name"]

    /// The one Wikidata item that is this person, or nil. Strict on purpose: the label must be the name, the description must say a musician, performer or film
    /// professional (a band for a group), anything that is an album, film, place or disambiguation page is out, and when several remain the role the page shows
    /// decides; if that still does not leave exactly one, nobody is chosen (no description is better than another person's).
    static func chooseHit(name: String, isGroup: Bool, roleWords: [String], hits: [SearchHit]) -> String? {
        let want = MusicText.normalize(name)
        guard !want.isEmpty else { return nil }
        func has(_ d: String, _ words: [String]) -> Bool {
            let t = " " + d.lowercased().replacingOccurrences(of: "-", with: " ") + " "
            return words.contains { t.contains(" " + $0) }
        }
        var ok: [SearchHit] = []
        for h in hits where MusicText.normalize(h.label) == want {
            let d = h.description
            if d.isEmpty || has(d, notAPerson) { continue }
            // "film", "song" and "television" alone ("Indian film director", "television actor") describe a person's field; only a person word lets them through, so a bare "2012 Tamil film" still fails below.
            if isGroup ? !has(d, groupWords) : !has(d, personWords) { continue }
            ok.append(h)
        }
        if ok.count == 1 { return ok[0].qid }
        guard ok.count > 1, !roleWords.isEmpty else { return nil }
        let byRole = ok.filter { has($0.description, roleWords) }
        return byRole.count == 1 ? byRole[0].qid : nil
    }

    /// The description words that fit what the page shows for the person (a singer page: singer, vocalist...).
    static func roleWords(forView view: String?) -> [String] {
        switch view {
        case "singer": ["singer", "vocalist", "playback", "musician", "rapper"]
        case "composer": ["composer", "music director", "musician", "conductor"]
        case "lyricist": ["lyricist", "songwriter", "poet", "writer"]
        case "actor": ["actor", "actress"]
        case "director": ["director", "filmmaker"]
        case "producer": ["producer"]
        case "instrumentalist": ["musician", "instrumentalist", "guitarist", "pianist", "violinist", "drummer", "veena", "flautist", "percussionist"]
        case "conductor": ["conductor"]
        default: []
        }
    }

    /// Article titles and the short description from one `wbgetentities` answer asked for `claims|sitelinks|descriptions`.
    static func parseEntityExtras(_ data: Data, qid: String) -> (sitelinks: String?, description: String?) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let e = (root["entities"] as? [String: Any])?[qid] as? [String: Any] else { return (nil, nil) }
        var parts: [String] = []
        for (site, v) in ((e["sitelinks"] as? [String: Any]) ?? [:]).sorted(by: { $0.key < $1.key }) {
            if let t = (v as? [String: Any])?["title"] as? String { parts.append(site + ":" + t) }
        }
        let desc = ((e["descriptions"] as? [String: Any])?["en"] as? [String: Any])?["value"] as? String
        return (parts.isEmpty ? nil : parts.joined(separator: "|"), desc)
    }

    /// A summary is the person's when it is not a disambiguation page and it names the same Wikidata item the entity is linked to (when it says which).
    static func summaryBelongs(_ s: Summary, to qid: String) -> Bool {
        !s.isDisambiguation && (s.wikibaseItem == nil || s.wikibaseItem == qid)
    }

    /// The name in the person's own script: the alias in the native language when there is one, else in the first of the reading languages that has one, else none (never a
    /// script picked because it came first).
    static func nativeName(aliases: [NameAlias], displayIsLatin: Bool, display: String, languages: [String]) -> String? {
        for l in languages {
            if let a = aliases.first(where: { ($0.lang ?? "").lowercased() == l.lowercased() && $0.text != display && !$0.text.isEmpty && MusicPersonText.isLatin($0.text) != displayIsLatin }) { return a.text }
        }
        return nil
    }
}

/// Fetches and remembers the Wikipedia/Wikidata facts of a person. One small answer per person, kept for 30 days on this Mac; a miss is kept for a day so a person with no article
/// is not asked again on every visit.
actor MusicPersonWikiInfoLoader {
    static let shared = MusicPersonWikiInfoLoader()
    private var memory: [String: (info: MusicPersonWikiInfo?, at: Date)] = [:]
    private var inFlight: [String: Task<MusicPersonWikiInfo?, Never>] = [:]
    private var wipes = 0
    static let hit: TimeInterval = 30 * 86_400, miss: TimeInterval = 86_400, partialKeep: TimeInterval = 3_600

    /// How long an answer is trusted: a miss a day, a partial answer an hour, a whole one thirty days.
    static func keep(_ info: MusicPersonWikiInfo?) -> TimeInterval { info == nil ? miss : (info?.partial == true ? partialKeep : hit) }

    private var directory: URL { MusicStorage.ensureUnbacked(MusicStorage.subfolder("PersonWiki")) }

    /// The privacy wipe: the saved answers are named by Wikidata item, so together they list every artist the person opened.
    func wipe() {
        wipes += 1   // an answer still on its way when the wipe happens must not write itself back afterwards
        for (_, t) in inFlight { t.cancel() }
        inFlight = [:]; memory = [:]
        try? FileManager.default.removeItem(at: directory)
    }
    private func file(_ key: String) -> URL { directory.appendingPathComponent(key.map { $0.isLetter || $0.isNumber || $0 == "-" ? String($0) : "_" }.joined() + ".json") }

    /// Who the person is when the graph has no Wikidata or TMDB link for them: the name and what the page shows them as.
    struct Lookup: Sendable { var name: String; var isGroup: Bool; var roleWords: [String] }

    func info(qid givenQID: String?, tmdbID: String? = nil, sitelinks givenSitelinks: String?, readingLanguages: [String], transport: any MusicMetadataTransport,
              tmdb: (@Sendable (String, [URLQueryItem]) async throws -> Data)? = nil, lookup: Lookup? = nil) async -> MusicPersonWikiInfo? {
        var qid = givenQID
        var sitelinks = givenSitelinks
        if qid == nil, tmdbID == nil, let lookup {
            // No link yet: find the Wikidata item by name, strictly (see `chooseHit`). A miss is remembered for a day like any other.
            let nameKey = "name:" + MusicText.normalize(lookup.name) + (lookup.isGroup ? "|g" : "") + "|" + lookup.roleWords.joined(separator: ",")
            if let m = memory[nameKey], Date().timeIntervalSince(m.at) < Self.keep(m.info) { return m.info }
            let looked = await Self.resolve(lookup, transport: transport)
            // A search that could not be asked is not "nobody found": it is asked again next time.
            guard let found = looked.qid else { if !looked.failed { memory[nameKey] = (nil, Date()) }; return nil }
            qid = found; sitelinks = nil
        }
        guard qid != nil || tmdbID != nil else { return nil }
        let key = (qid ?? "tmdb" + (tmdbID ?? "")) + "|" + readingLanguages.prefix(3).joined(separator: ",")
        if let m = memory[key], Date().timeIntervalSince(m.at) < Self.keep(m.info) { return m.info }
        if let data = try? Data(contentsOf: file(key)), let saved = try? JSONDecoder.iso.decode(MusicPersonWikiInfo.self, from: data), Date().timeIntervalSince(saved.fetchedAt) < Self.hit {
            memory[key] = (saved, saved.fetchedAt); return saved
        }
        if let running = inFlight[key] { return await running.value }
        let task = Task<MusicPersonWikiInfo?, Never> { await Self.fetch(qid: qid, tmdbID: tmdbID, sitelinks: sitelinks, readingLanguages: readingLanguages, transport: transport, tmdb: tmdb) }
        inFlight[key] = task
        let epoch = wipes
        let result = await task.value
        guard epoch == wipes else { return result }   // wiped while it ran: the caller still gets its answer, nothing is kept
        inFlight[key] = nil
        memory[key] = (result, Date())
        if let result, result.partial != true, let data = try? JSONEncoder.iso.encode(result) { try? data.write(to: file(key), options: .atomic) }
        return result
    }

    private static func resolve(_ l: Lookup, transport: any MusicMetadataTransport) async -> (qid: String?, failed: Bool) {
        guard let data = try? await transport.get(URL(string: "https://www.wikidata.org/w/api.php")!, query: ["action": "wbsearchentities", "search": l.name, "language": "en", "uselang": "en", "type": "item", "limit": "10", "format": "json"], headers: MusicSourceKit.headers) else { return (nil, true) }
        return (MusicPersonWikiRules.chooseHit(name: l.name, isGroup: l.isGroup, roleWords: l.roleWords, hits: MusicPersonWikiRules.parseSearch(data)), false)
    }

    private static func fetch(qid: String?, tmdbID: String?, sitelinks givenSitelinks: String?, readingLanguages: [String], transport: any MusicMetadataTransport,
                              tmdb: (@Sendable (String, [URLQueryItem]) async throws -> Data)?) async -> MusicPersonWikiInfo? {
        var info = MusicPersonWikiInfo(qid: qid ?? "", description: nil, extract: nil, extractLanguage: nil, nativeLanguage: nil, portraitFile: nil, fetchedAt: Date())
        var failed = false
        if let qid, qid.hasPrefix("Q"), qid.dropFirst().allSatisfy(\.isNumber) {
            // The person's native language and portrait (Wikidata), asked first; then the article's opening (Wikipedia) in the reader's language when that wiki has one.
            let claimsData = try? await transport.get(URL(string: "https://www.wikidata.org/w/api.php")!, query: ["action": "wbgetentities", "ids": qid, "props": "claims|sitelinks|descriptions", "format": "json"], headers: MusicSourceKit.headers)
            if claimsData == nil { failed = true }
            let claims = claimsData.flatMap { MusicPersonWikiRules.parseClaims($0, qid: qid) }
            info.nativeLanguage = claims?.nativeQID.flatMap { MusicWikidataLanguages.code(forQID: $0) }
            info.portraitFile = claims.flatMap { MusicPersonWikiRules.choosePortrait($0.portraits) }
            // Article titles: the ones the graph stored, else the ones Wikidata lists for the item (a person known only by a Wikidata id has none stored).
            let extras = claimsData.map { MusicPersonWikiRules.parseEntityExtras($0, qid: qid) }
            let titles = MusicPersonWikiRules.titles(sitelinks: givenSitelinks ?? extras?.sitelinks)
            if let wiki = MusicPersonWikiRules.chooseWiki(titles: titles, preferred: readingLanguages + (info.nativeLanguage.map { [$0] } ?? [])) {
                let path = wiki.title.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? wiki.title
                if let url = URL(string: "https://\(wiki.lang).wikipedia.org/api/rest_v1/page/summary/\(path)") {
                    if let data = try? await transport.get(url, query: [:], headers: MusicSourceKit.headers) {
                        if let s = MusicPersonWikiRules.parseSummary(data), MusicPersonWikiRules.summaryBelongs(s, to: qid) {
                            info.description = s.description.flatMap { $0.isEmpty ? nil : $0 }
                            info.extract = s.extract.flatMap { MusicPersonWikiRules.shortExtract($0, maxSentences: 5, maxChars: 700) }
                            info.extractLanguage = wiki.lang
                        }
                    } else { failed = true }
                }
            }
        }
        // Wikidata's own short description ("Indian playback singer") when no article could be read, so the header still says who the person is.
        if info.description == nil, info.extract == nil, let qid, qid.hasPrefix("Q"),
           let d = try? await transport.get(URL(string: "https://www.wikidata.org/w/api.php")!, query: ["action": "wbgetentities", "ids": qid, "props": "descriptions", "languages": "en", "format": "json"], headers: MusicSourceKit.headers),
           let text = MusicPersonWikiRules.parseEntityExtras(d, qid: qid).description, !text.isEmpty { info.description = text }
        // The same fallback the movie pages use: the TMDB biography in the reader's language, English when that is empty.
        if info.extract == nil, let tmdbID, let tmdb {
            let lang = readingLanguages.first ?? "en"
            var answered = false
            for l in ([lang] + (lang == "en" ? [] : ["en"])) {
                guard let d = try? await tmdb("/3/person/" + tmdbID, [URLQueryItem(name: "language", value: l == "en" ? "en-US" : l)]) else { continue }
                answered = true
                if let b = MusicPersonWikiRules.parseTMDBBiography(d) {
                    info.extract = MusicPersonWikiRules.shortExtract(b, maxSentences: 5, maxChars: 700); info.extractLanguage = l; break
                }
            }
            if !answered { failed = true }
        }
        info.partial = failed && info.extract == nil ? true : nil
        let done = info
        MusicDebugLog.log("person", "wiki info \(qid ?? "tmdb\(tmdbID ?? "")"): extract \(done.extract?.count ?? 0) chars (\(done.extractLanguage ?? "-")), description \(done.description == nil ? "no" : "yes"), portrait \(done.portraitFile ?? "none"), native \(done.nativeLanguage ?? "-")")
        return info.extract == nil && info.description == nil && info.portraitFile == nil && info.nativeLanguage == nil && !failed ? nil : info
    }
}

enum MusicWikidataLanguages {
    static func code(forQID q: String) -> String? { MusicWikidataParser.languageByQID[q] }
}

private extension JSONDecoder { static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d } }
private extension JSONEncoder { static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e } }

extension MusicEntitySnapshot {
    /// Just enough of a snapshot to choose a name spelling again from data the header already holds.
    static func stub(name: String, lang: String?) -> MusicEntitySnapshot {
        MusicEntitySnapshot(id: .derive(kind: .person, aliasKey: "header-" + name), subkind: nil, name: name, nameLatin: name, lang: lang, year: nil, yearEnd: nil, country: nil, durationMs: nil,
                            imageRef: nil, attrs: [:], provisional: false, state: .live, pinned: false, mergedInto: nil, createdAt: .distantPast, updatedAt: .distantPast)
    }
}
