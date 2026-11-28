import Foundation

/// TMDB through the app's own client (`MusicFilmTMDBGate`, installed at launch: the person's TMDB switch, key, pacing and refusal pause all apply).
/// Optional: with no gate (no key, switch off) every fetch throws `.disabled` and the rest of the graph works without it. The film layer's parser is the
/// one parser: this source adds only the alternative titles, the Wikidata id, the producers and the crew departments, and keeps the film's own facts (see `facts`).
/// The images kept are addresses only: the backdrop, the gallery's poster and backdrop paths (no image bytes), plus the videos list and the extra crew. TMDB text is kept for 30 days.
struct TMDBGraphSource: MusicMetadataSource {
    /// The regions whose age rating is looked for first: the viewer's own region, then whatever the title was released in.
    static var certificationRegions: [String] { [Locale.current.region?.identifier].compactMap { $0 } }

    var gate: MusicFilmTMDBGate.Fetch?
    var id: MusicSourceID { .tmdb }

    var policy: MusicSourcePolicy {
        MusicSourcePolicy(hosts: ["api.themoviedb.org", "image.tmdb.org"], license: .termsRestricted, retention: 30 * 86_400, attribution: "TMDB",
                          ttl: [MusicFacet.filmCredits: 10 * 86_400, MusicFacet.personFilmography: 14 * 86_400, MusicFacet.filmSearch: 7 * 86_400],
                          defaultTTL: 10 * 86_400, defaultOn: true,
                          privacyNote: "Film and person names are sent to The Movie Database (themoviedb.org) through the app's own TMDB connection, only while TMDB lookups are on. Optional.")
    }

    /// The alternative titles, Wikidata id and producers of a `movie/{id}?append_to_response=credits,external_ids,alternative_titles` reply.
    static func extras(_ data: Data) -> (aliases: [NameAlias], wikidata: String?, producers: [MusicFilmPerson]) {
        guard let j = MusicSourceKit.json(data) else { return ([], nil, []) }
        let titles = ((j["alternative_titles"] as? [String: Any])?["titles"] as? [[String: Any]]) ?? []
        let aliases = titles.compactMap { t in MusicSourceKit.string(t["title"]).map { NameAlias($0, lang: Self.languageOf(country: (t["iso_3166_1"] as? String)), source: "tmdb") } }
        let wd = ((j["external_ids"] as? [String: Any])?["wikidata_id"] as? String).flatMap { $0.hasPrefix("Q") ? $0 : nil }
        let crew = ((j["credits"] as? [String: Any])?["crew"] as? [[String: Any]]) ?? []
        let producers = crew.filter { ($0["job"] as? String) == "Producer" }.prefix(4).compactMap { c -> MusicFilmPerson? in
            guard let n = MusicSourceKit.string(c["name"]) else { return nil }
            return MusicFilmPerson(tmdbID: c["id"] as? Int, name: n)
        }
        return (aliases, wd, Array(producers))
    }

    /// The collection TMDB says a film belongs to (`belongs_to_collection`), as a franchise name and id. TMDB names these "The Matrix Collection"; the franchise is the name without that word.
    static func collection(_ data: Data) -> (id: String, name: String)? {
        guard let j = MusicSourceKit.json(data), let c = j["belongs_to_collection"] as? [String: Any], let id = c["id"] as? Int, let raw = MusicSourceKit.string(c["name"]) else { return nil }
        var name = raw.trimmingCharacters(in: .whitespaces)
        if name.hasSuffix(" Collection"), name.count > 12 { name = String(name.dropLast(" Collection".count)) }
        return name.isEmpty ? nil : (String(id), name)
    }

    /// The crew departments of the same reply (camera, editing, writing, art, sound, costume, effects, choreography), one entry per person and department.
    static func crewDepartments(_ data: Data) -> [MusicFilmExtraCredit] {
        guard let j = MusicSourceKit.json(data) else { return [] }
        return MusicFilmExtraCrew.credits(fromCrew: ((j["credits"] as? [String: Any])?["crew"] as? [[String: Any]]) ?? [])
    }

    /// The film's own facts from the same reply: original title, release date, runtime, tagline, genres, TMDB's rating, the certification (India first, then the US, then any
    /// region that has one: a certification belongs to a country, so the region is kept with it) and the first official trailer or teaser (a link to open, never played here).
    /// Fields the reply lacks stay absent; nothing is filled in from elsewhere.
    static func facts(_ data: Data, regions: [String] = certificationRegions) -> [String: String] {
        guard let j = MusicSourceKit.json(data) else { return [:] }
        var out: [String: String] = [:]
        if let o = MusicSourceKit.string(j["original_title"]) { out["originalTitle"] = o }
        if let d = MusicSourceKit.string(j["release_date"]), !d.isEmpty { out["releaseDate"] = d }
        if let r = j["runtime"] as? Int, r > 0 { out["runtimeMinutes"] = String(r) }
        else if let r = (j["episode_run_time"] as? [Int])?.first(where: { $0 > 0 }) { out["runtimeMinutes"] = String(r) }   // a series: minutes per episode
        let produced = ((j["production_countries"] as? [[String: Any]]) ?? []).compactMap { MusicSourceKit.string($0["iso_3166_1"]) }
        if !produced.isEmpty { out["countries"] = produced.joined(separator: "|") }
        if let b = MusicSourceKit.string(j["backdrop_path"]), b.hasPrefix("/") { out["backdropURL"] = "https://image.tmdb.org/t/p/w1280" + b }
        if let n = MusicFilmAboutFacts.names(j["production_countries"], key: "name") { out["countryNames"] = n }
        if let n = MusicFilmAboutFacts.names(j["production_companies"], key: "name") { out["companies"] = n }
        if let n = MusicFilmAboutFacts.names(j["spoken_languages"], key: "english_name") { out["spokenLanguages"] = n }
        if let st = MusicSourceKit.string(j["status"]), !st.isEmpty { out["status"] = st }
        // TMDB writes 0 for a figure it does not know: only an amount above zero is stored.
        if let b = j["budget"] as? Int, b > 0 { out["budget"] = String(b) }
        if let r = j["revenue"] as? Int, r > 0 { out["revenue"] = String(r) }
        if let t = MusicSourceKit.string(j["tagline"]), !t.isEmpty { out["tagline"] = t }
        let genres = ((j["genres"] as? [[String: Any]]) ?? []).compactMap { MusicSourceKit.string($0["name"]) }
        if !genres.isEmpty { out["genres"] = genres.joined(separator: "|") }
        if let v = j["vote_average"] as? Double, let n = j["vote_count"] as? Int, n >= 10, v > 0 { out["rating"] = String(format: "%.1f", v); out["ratingVotes"] = String(n) }
        let countries = ((j["release_dates"] as? [String: Any])?["results"] as? [[String: Any]]) ?? []
        func cert(_ region: String) -> String? {
            let rows = countries.first { ($0["iso_3166_1"] as? String) == region }?["release_dates"] as? [[String: Any]]
            return rows?.compactMap { MusicSourceKit.string($0["certification"]) }.first { !$0.isEmpty }
        }
        for region in regions + countries.compactMap({ $0["iso_3166_1"] as? String }) {
            if let c = cert(region) { out["certification"] = c; out["certificationRegion"] = region; break }
        }
        if out["certification"] == nil {
            // A series carries `content_ratings` (one rating per country) instead of `release_dates`.
            let ratings = ((j["content_ratings"] as? [String: Any])?["results"] as? [[String: Any]]) ?? []
            for region in regions + ratings.compactMap({ $0["iso_3166_1"] as? String }) {
                if let r = ratings.first(where: { ($0["iso_3166_1"] as? String) == region }).flatMap({ MusicSourceKit.string($0["rating"]) }), !r.isEmpty {
                    out["certification"] = r; out["certificationRegion"] = region; break
                }
            }
        }
        let videos = ((j["videos"] as? [String: Any])?["results"] as? [[String: Any]]) ?? []
        let trailers = videos.filter { ($0["site"] as? String) == "YouTube" && ["Trailer", "Teaser"].contains($0["type"] as? String ?? "") && MusicSourceKit.string($0["key"]) != nil }
        let original = MusicSourceKit.string(j["original_language"])
        func rank(_ v: [String: Any]) -> Int {
            (v["type"] as? String == "Trailer" ? 0 : 4) + ((v["iso_639_1"] as? String) == original ? 0 : 2) + ((v["official"] as? Bool) == true ? 0 : 1)
        }
        if let v = trailers.min(by: { rank($0) < rank($1) }), let k = MusicSourceKit.string(v["key"]) { out["trailerKey"] = k }
        if let e = MusicFilmVideos.encode(MusicFilmVideos.parse(results: videos, originalLanguage: original)) { out["videos"] = e }
        if let e = MusicFilmExtraCrew.encode(crewDepartments(data)) { out["crewExtra"] = e }
        if let g = MusicFilmGallery.encode(MusicFilmGallery.parse(images: j["images"])) { out["gallery"] = g }
        return out
    }

    /// TMDB's alternative titles carry a COUNTRY code. A language is named only for a country that has one clear language for film titles; anywhere else the alias has no language.
    static func languageOf(country: String?) -> String? {
        switch country?.uppercased() {
        case "JP": "ja"; case "KR": "ko"; case "FR": "fr"; case "DE": "de"; case "ES", "MX", "AR": "es"; case "IT": "it"; case "PT", "BR": "pt"; case "RU": "ru"; case "TR": "tr"
        case "CN": "zh"; case "TW": "zh"; default: nil
        }
    }

    static func filmBatch(_ data: Data, now: Date) -> MusicClaimBatch? {
        guard var info = MusicFilmTMDBParser.film(from: data, castLimit: MusicFilmGraphReading.castCap) else { return nil }
        let x = extras(data)
        info.wikidataID = x.wikidata
        info.provenance = MusicFilmProvenance(source: .tmdb, retrievedAt: now, confidence: 0.9)
        var b = MusicFilmGraphBridge.batch(from: info, retrievedAt: now)
        if let i = b.drafts.firstIndex(where: { $0.ref.kind == .film }) {
            b.drafts[i].entity.aliases += x.aliases
            let f = facts(data)
            for (k, v) in f where k != "countries" { b.drafts[i].entity.attrs[k] = v }
            // The country of the film, so its industry is named only for what it is: India when it is among the production countries, else the first one listed (a Hindi
            // film made in the UK and France is not Bollywood). Unknown only when TMDB lists none.
            if let list = f["countries"]?.split(separator: "|").map(String.init) { b.drafts[i].entity.country = MusicFilmAboutFacts.industryCountry(list) }
            // TMDB's own overview is the film's synopsis on its page (shown with where it came from). A blank overview stores nothing.
            if let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let overview = (j["overview"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !overview.isEmpty {
                b.drafts[i].entity.attrs["synopsis"] = overview
                b.drafts[i].entity.attrs["synopsisSource"] = "TMDB"
            }
        }
        // The collection TMDB names is the film's franchise: its own series entity, linked the way Wikidata's franchise is, so the franchise sheet lists the films that share it.
        if let col = collection(data), let film = b.drafts.first(where: { $0.ref.kind == .film })?.ref {
            let cid = ExternalID(.tmdbCollection, col.id)
            let fd = MusicSourceDraft(.external(.series, cid), MusicEntityDraft(kind: .series, name: col.name, subkind: "franchise", externalIDs: [cid]))
            if !b.drafts.contains(where: { $0.ref == fd.ref }) { b.drafts.append(fd) }
            var c = MusicClaimDraft(subject: film, predicate: .inFranchise, object: fd.ref, creditLevel: .film, confidence: 0.85, evidence: ["tmdb-collection"])
            c.attribution = "TMDB"
            b.claims.append(c)
            if let i = b.drafts.firstIndex(where: { $0.ref == film }), b.drafts[i].entity.attrs["franchise"] == nil { b.drafts[i].entity.attrs["franchise"] = col.name }
        }
        // The people of the crew departments become person entities with their TMDB id, so the page can find them again and open their pages.
        for c in crewDepartments(data) {
            let r = MusicDraftRef.external(.person, ExternalID(.tmdbPerson, String(c.tmdb)))
            if !b.drafts.contains(where: { $0.ref == r }) { b.drafts.append(MusicSourceDraft(r, MusicEntityDraft(kind: .person, name: c.name, externalIDs: [ExternalID(.tmdbPerson, String(c.tmdb))]))) }
        }
        if let film = b.drafts.first(where: { $0.ref.kind == .film })?.ref {
            for p in x.producers {
                guard let t = p.tmdbID else { continue }
                let r = MusicDraftRef.external(.person, ExternalID(.tmdbPerson, String(t)))
                if !b.drafts.contains(where: { $0.ref == r }) { b.drafts.append(MusicSourceDraft(r, MusicEntityDraft(kind: .person, name: p.name, externalIDs: [ExternalID(.tmdbPerson, String(t))]))) }
                var c = MusicClaimDraft(subject: film, predicate: .producedBy, object: r, role: .producer, creditLevel: .film, confidence: 0.85, evidence: ["tmdb-credits"])
                c.attribution = "TMDB"
                b.claims.append(c)
            }
        }
        return b
    }

    /// The facts of a series from a `tv/{id}` reply: the same facts as a film (tagline, genres, status, companies, rating, backdrop), the number of seasons and the first air date.
    /// Nothing is guessed; a reply without a name gives no batch.
    static func seriesBatch(_ data: Data, tmdbID: String, now: Date) -> MusicClaimBatch? {
        guard let j = MusicSourceKit.json(data), let name = MusicSourceKit.string(j["name"]), !name.isEmpty else { return nil }
        var attrs = facts(data)
        attrs["countries"] = nil
        if let o = MusicSourceKit.string(j["original_name"]), !o.isEmpty { attrs["originalTitle"] = o }
        if let d = MusicSourceKit.string(j["first_air_date"]), !d.isEmpty { attrs["releaseDate"] = d }
        if let n = j["number_of_seasons"] as? Int, n > 0 { attrs["seasons"] = String(n) }
        if let o = MusicSourceKit.string(j["overview"])?.trimmingCharacters(in: .whitespacesAndNewlines), !o.isEmpty { attrs["synopsis"] = o; attrs["synopsisSource"] = "TMDB" }
        let id = ExternalID(.tmdbTV, tmdbID)
        let year = (attrs["releaseDate"]?.prefix(4)).flatMap { Int($0) }
        var b = MusicClaimBatch(source: .tmdb, license: .termsRestricted, retrievedAt: now, retention: 30 * 86_400, attribution: "TMDB")
        var ids = [id]
        if let wd = ((j["external_ids"] as? [String: Any])?["wikidata_id"] as? String), wd.hasPrefix("Q") { ids.append(ExternalID(.wikidata, wd)) }
        let ref = MusicDraftRef.external(.series, id)
        b.drafts.append(MusicSourceDraft(ref, MusicEntityDraft(kind: .series, name: name, lang: MusicSourceKit.string(j["original_language"]), year: year, attrs: attrs, externalIDs: ids)))
        // The cast, in billing order, the same way a film's cast is stored (walk-ons left out).
        let cast = (((j["credits"] as? [String: Any])?["cast"] as? [[String: Any]]) ?? [])
            .filter { !MusicFilmTMDBParser.isWalkOn($0["character"] as? String) }
            .sorted { ($0["order"] as? Int ?? 999) < ($1["order"] as? Int ?? 999) }
        for (i, c) in cast.prefix(MusicFilmGraphReading.castCap).enumerated() {
            guard let tid = c["id"] as? Int, let n = MusicSourceKit.string(c["name"]) else { continue }
            let r = MusicDraftRef.external(.person, ExternalID(.tmdbPerson, String(tid)))
            if !b.drafts.contains(where: { $0.ref == r }) { b.drafts.append(MusicSourceDraft(r, MusicEntityDraft(kind: .person, name: n, externalIDs: [ExternalID(.tmdbPerson, String(tid))]))) }
            var a = EdgeAttributes(); a.characterName = MusicSourceKit.string(c["character"]); a.creditOrder = i
            var cl = MusicClaimDraft(subject: ref, predicate: .hasCast, object: r, role: .actor, attributes: a, order: i, creditLevel: .film, confidence: 0.85, evidence: ["tmdb-credits"])
            cl.attribution = "TMDB"
            b.claims.append(cl)
        }
        // The people of the crew departments become person entities with their TMDB id, as a film's do, so the series page can name them and open their pages.
        for c in crewDepartments(data) {
            let r = MusicDraftRef.external(.person, ExternalID(.tmdbPerson, String(c.tmdb)))
            if !b.drafts.contains(where: { $0.ref == r }) { b.drafts.append(MusicSourceDraft(r, MusicEntityDraft(kind: .person, name: c.name, externalIDs: [ExternalID(.tmdbPerson, String(c.tmdb))]))) }
        }
        return b
    }

    func fetch(_ r: MusicSourceRequest, context: MusicFetchContext) async throws -> MusicClaimBatch {
        guard let gate else { throw MusicSourceError.disabled }
        let now = context.now()
        switch r.facet {
        case MusicFacet.filmSearch:
            guard let t = r.param("title") else { throw MusicSourceError.badRequest("title") }
            var q = [URLQueryItem(name: "query", value: t), URLQueryItem(name: "include_adult", value: "false"), URLQueryItem(name: "language", value: "en-US")]
            if let y = r.param("year") { q.append(URLQueryItem(name: "year", value: y)) }
            var b = MusicClaimBatch(source: .tmdb, license: .termsRestricted, retrievedAt: now, retention: 30 * 86_400, attribution: "TMDB"); b.isSearch = true
            for c in MusicFilmTMDBParser.credits(from: try await gate("/3/search/movie", q)).prefix(8) {
                let id = ExternalID(.tmdbMovie, String(c.tmdbID))
                b.drafts.append(MusicSourceDraft(.external(.film, id), MusicEntityDraft(kind: .film, name: c.title, lang: c.language, year: c.year,
                                                                                      attrs: ["originalTitle": c.originalTitle], externalIDs: [id])))
            }
            return b
        case MusicFacet.filmCredits:
            if let tv = r.param("tmdbTV") {
                guard Int(tv) != nil else { throw MusicSourceError.badRequest("tmdbTV") }
                let d = try await gate("/3/tv/\(tv)", [URLQueryItem(name: "append_to_response", value: "credits,videos,images,external_ids,content_ratings"), URLQueryItem(name: "language", value: "en-US"), URLQueryItem(name: "include_video_language", value: "en,null,te,hi,ta,ml,kn,bn,pa,mr"), URLQueryItem(name: "include_image_language", value: "null,en,hi,te,ta,ml,kn")])
                guard let b = Self.seriesBatch(d, tmdbID: tv, now: now) else { throw MusicError.network("unexpected reply") }
                return b
            }
            guard let id = r.param("tmdb"), Int(id) != nil else { throw MusicSourceError.badRequest("tmdb") }
            let d = try await gate("/3/movie/\(id)", [URLQueryItem(name: "append_to_response", value: "credits,external_ids,alternative_titles,release_dates,videos,images"), URLQueryItem(name: "language", value: "en-US"), URLQueryItem(name: "include_video_language", value: "en,null,te,hi,ta,ml,kn,bn,pa,mr"), URLQueryItem(name: "include_image_language", value: "null,en,hi,te,ta,ml,kn")])
            guard let b = Self.filmBatch(d, now: now) else { throw MusicError.network("unexpected reply") }
            return b
        case MusicFacet.personFilmography:
            guard let id = r.param("tmdbPerson"), Int(id) != nil else { throw MusicSourceError.badRequest("tmdbPerson") }
            let d = try await gate("/3/person/\(id)/movie_credits", [])
            var b = MusicClaimBatch(source: .tmdb, license: .termsRestricted, retrievedAt: now, retention: 30 * 86_400, attribution: "TMDB")
            let person = MusicDraftRef.external(.person, ExternalID(.tmdbPerson, id))
            for c in MusicFilmTMDBParser.filmography(from: d).sorted(by: { $0.popularity > $1.popularity }).prefix(60) {
                let fid = ExternalID(.tmdbMovie, String(c.tmdbID)), fr = MusicDraftRef.external(.film, fid)
                b.drafts.append(MusicSourceDraft(fr, MusicEntityDraft(kind: .film, name: c.title, lang: c.language, year: c.year, externalIDs: [fid])))
                var a = EdgeAttributes(); a.characterName = c.character
                var cl = MusicClaimDraft(subject: fr, predicate: .hasCast, object: person, role: .actor, attributes: a, order: c.billingOrder, creditLevel: .film, confidence: 0.9, evidence: ["tmdb-movie-credits"])
                cl.attribution = "TMDB"
                b.claims.append(cl)
            }
            return b
        default: throw MusicSourceError.unsupported(r.facet)
        }
    }
}
