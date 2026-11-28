import Foundation

/// MusicBrainz replies as graph drafts and claims. Pure functions: bytes in, a batch out. Core data is CC0; genres are read as `hasGenre` claims
/// marked CC BY-NC-SA with the "MusicBrainz" attribution (non-commercial posture); ratings and free tags are not read. Cover Art Archive addresses are image hints only.
enum MusicBrainzParser {
    static let source = MusicSourceID.musicbrainz

    private static func batch(_ at: Date) -> MusicClaimBatch { MusicClaimBatch(source: source, license: .cc0, retrievedAt: at) }

    // MARK: building blocks

    private static func ref(_ kind: MusicEntityKind, _ mbid: String) -> MusicDraftRef { .external(kind, ExternalID(.mbid, mbid)) }

    /// The predicate and role of an artist relation type; nil for the ones the graph does not model (mix engineers and the like).
    static func creditMapping(_ type: String) -> (MusicPredicate, MusicRole)? {
        switch type {
        case "vocal": (.performedBy, .singer)
        case "instrument": (.performedBy, .instrumentalist)
        case "performer", "performing orchestra": (.performedBy, .performer)
        case "conductor": (.performedBy, .conductor)
        case "remixer": (.performedBy, .remixer)
        case "producer": (.producedBy, .producer)
        case "arranger", "orchestrator": (.composedBy, .arranger)
        case "composer": (.composedBy, .composer)
        case "lyricist": (.writtenBy, .lyricist)
        case "writer", "librettist": (.writtenBy, .writer)
        default: nil
        }
    }

    static func artistDraft(_ a: [String: Any], includeLife: Bool = true) -> MusicSourceDraft? {
        guard let id = MusicSourceKit.string(a["id"]), let name = MusicSourceKit.string(a["name"]) else { return nil }
        let kind: MusicEntityKind = (a["type"] as? String) == "Group" ? .group : .person
        var year: Int?; var yearEnd: Int?
        if includeLife, let life = a["life-span"] as? [String: Any] {
            year = MusicSourceKit.year(life["begin"] as? String); yearEnd = MusicSourceKit.year(life["end"] as? String)
        }
        var aliases: [NameAlias] = []
        if let sort = MusicSourceKit.string(a["sort-name"]), sort != name, !sort.contains(",") { aliases.append(NameAlias(sort, source: "musicbrainz")) }
        for al in (a["aliases"] as? [[String: Any]]) ?? [] {
            if let n = MusicSourceKit.string(al["name"]), n != name { aliases.append(NameAlias(n, lang: MusicSourceKit.string(al["locale"]), source: "musicbrainz")) }
        }
        var attrs: [String: String] = [:]
        if let d = MusicSourceKit.string(a["disambiguation"]) { attrs["disambiguation"] = d }
        let ref = ref(kind, id)
        return MusicSourceDraft(ref, MusicEntityDraft(kind: kind, name: name, year: year, yearEnd: yearEnd, country: MusicSourceKit.string(a["country"]), attrs: attrs,
                                                      externalIDs: [ExternalID(.mbid, id)] + urlIDs(a["relations"]), aliases: aliases))
    }

    private static func urlIDs(_ relations: Any?) -> [ExternalID] {
        ((relations as? [[String: Any]]) ?? []).compactMap { r in
            guard (r["target-type"] as? String) == "url", let res = (r["url"] as? [String: Any])?["resource"] as? String else { return nil }
            return MusicExternalLinks.externalID(fromURL: res)
        }
    }

    private static func creditOrder(_ credits: [[String: Any]]) -> [(draft: MusicSourceDraft, name: String)] {
        credits.compactMap { c in
            guard let a = c["artist"] as? [String: Any], let d = artistDraft(a, includeLife: false) else { return nil }
            return (d, MusicSourceKit.string(c["name"]) ?? d.entity.name)
        }
    }

    /// Adds the drafts and claims of `relations` (artist relations and performance links) of one entity.
    private static func addRelations(_ relations: [[String: Any]], subject: MusicDraftRef, level: CreditLevel, into b: inout MusicClaimBatch) {
        var vocalists = Set<String>()
        for r in relations {
            guard let type = r["type"] as? String else { continue }
            if (r["target-type"] as? String) == "artist", let a = r["artist"] as? [String: Any], let d = artistDraft(a, includeLife: false), let (pred, role) = creditMapping(type) {
                if !b.drafts.contains(where: { $0.ref == d.ref }) { b.drafts.append(d) }
                var attrs = EdgeAttributes()
                let at = (r["attributes"] as? [String]) ?? []
                if !at.isEmpty { attrs.instrument = at.joined(separator: ", ") }
                guard pred.accepts(subject: subject.kind, object: d.ref.kind) else { continue }
                if role == .singer, case .external(_, let x) = d.ref { vocalists.insert(x.value) }
                b.claims.append(MusicClaimDraft(subject: subject, predicate: pred, object: d.ref, role: role, attributes: attrs, creditLevel: level, confidence: 0.95,
                                                evidence: ["musicbrainz-relation", type]))
            } else if type == "performance", (r["target-type"] as? String) == "work", let w = r["work"] as? [String: Any], let wd = workDraft(w, into: &b) {
                var attrs = EdgeAttributes()
                let at = (r["attributes"] as? [String]) ?? []
                if at.contains("cover") { attrs.versionKind = .cover } else if at.contains("live") { attrs.versionKind = .live }
                else if at.contains("karaoke") { attrs.versionKind = .karaoke } else if at.contains("instrumental") { attrs.versionKind = .instrumental }
                b.claims.append(MusicClaimDraft(subject: subject, predicate: .recordingOf, object: wd, attributes: attrs, creditLevel: .song, confidence: 0.95, evidence: ["musicbrainz-relation", "performance"]))
                // The work's own composer and lyricist relations (work-level-rels).
                addRelations((w["relations"] as? [[String: Any]]) ?? [], subject: wd, level: .song, into: &b)
            }
        }
        _ = vocalists
        addTranslatedVersions(relations, subject: subject, into: &b)
        addSamples(relations, subject: subject, into: &b)
    }

    /// "Samples material" links (MusicBrainz: recording A contains samples from B; recording-to-recording and recording-to-release) and the artist-level
    /// "samples artist" link used when the source recording is unknown. On the sampling recording the link comes back "forward"; on the sampled one it comes
    /// back "backward". Both are stored as one edge, sampling recording to sampled source. The relationship type id is kept in the evidence.
    static func addSamples(_ relations: [[String: Any]], subject: MusicDraftRef, into b: inout MusicClaimBatch) {
        guard subject.kind == .recording else { return }
        var seen = Set<String>()
        for r in relations {
            guard let type = r["type"] as? String, type == "samples material" || type == "samples artist", let dir = r["direction"] as? String, dir == "forward" || dir == "backward" else { continue }
            let target = r["target-type"] as? String
            let typeID = (r["type-id"] as? String).map { "type-id:" + $0 } ?? "type-id:unknown"
            var other: MusicSourceDraft?
            var predicate: MusicPredicate = .samples
            switch (type, target) {
            case ("samples material", "recording"): other = (r["recording"] as? [String: Any]).flatMap { recordingDraft($0) }
            case ("samples material", "release"):
                if let rel = r["release"] as? [String: Any], let id = MusicSourceKit.string(rel["id"]), let title = MusicSourceKit.string(rel["title"]) {
                    other = MusicSourceDraft(ref(.release, id), MusicEntityDraft(kind: .release, name: title, externalIDs: [ExternalID(.mbid, id)]))
                }
            case ("samples artist", "artist"): predicate = .samplesArtist; other = (r["artist"] as? [String: Any]).flatMap { artistDraft($0, includeLife: false) }
            default: break
            }
            guard let d = other else { continue }
            // Backward means this recording is the sampled source: the sampling recording is the other one, and only a recording can sample.
            let (from, to): (MusicDraftRef, MusicDraftRef)
            if dir == "forward" { (from, to) = (subject, d.ref) } else { guard d.ref.kind == .recording, predicate == .samples else { continue }; (from, to) = (d.ref, subject) }
            guard predicate.accepts(subject: from.kind, object: to.kind) else { continue }
            let key = "\(predicate.rawValue)|\(from)|\(to)"
            guard seen.insert(key).inserted else { continue }
            if !b.drafts.contains(where: { $0.ref == d.ref }) { b.drafts.append(d) }
            b.claims.append(MusicClaimDraft(subject: from, predicate: predicate, object: to, creditLevel: .song, confidence: 0.9, evidence: ["musicbrainz-relation", type, typeID]))
        }
    }

    /// "Other version" links between works that MusicBrainz marks as translated: the lyrics of a work in another language. The relationship is directional
    /// ("later translated versions" forward, "translated version of" backward), so the translation is the subject of the edge and the earlier work its object.
    /// It is a fact about two musical works. It does not say a film was dubbed, and it is never shown as a dub. A version link with no stated kind adds nothing.
    private static func addTranslatedVersions(_ relations: [[String: Any]], subject: MusicDraftRef, into b: inout MusicClaimBatch) {
        guard subject.kind == .work else { return }
        for r in relations where (r["type"] as? String) == "other version" && (r["target-type"] as? String) == "work" {
            let at = ((r["attributes"] as? [String]) ?? []).map { $0.lowercased() }
            guard at.contains("translated") || at.contains("translation"), let w = r["work"] as? [String: Any], let other = workDraft(w, into: &b), other != subject else { continue }
            let backward = (r["direction"] as? String) == "backward"
            var attrs = EdgeAttributes()
            attrs.versionKind = .translatedLyrics
            b.claims.append(MusicClaimDraft(subject: backward ? subject : other, predicate: .alternateOf, object: backward ? other : subject, attributes: attrs, creditLevel: .song,
                                            confidence: 0.85, evidence: ["musicbrainz-relation", "other version", "translated"]))
        }
    }

    /// "Translated version" links between release groups (soundtrack releases in another language). Directional: the translation is the subject. Only a release
    /// group whose own title or disambiguation says it is a dubbing is called a dub, and then as a statement about that soundtrack release, never about a film.
    private static func addReleaseGroupTranslations(_ j: [String: Any], subject: MusicDraftRef, into b: inout MusicClaimBatch) {
        for r in (j["relations"] as? [[String: Any]]) ?? [] where (r["type"] as? String) == "translated version" && (r["target-type"] as? String) == "release_group" {
            guard let g = r["release_group"] as? [String: Any], let gd = releaseGroupDraft(g), gd.ref != subject else { continue }
            if !b.drafts.contains(where: { $0.ref == gd.ref }) { b.drafts.append(gd) }
            let backward = (r["direction"] as? String) == "backward"
            let translation = backward ? j : g
            let words = [translation["title"], translation["disambiguation"]].compactMap { $0 as? String }.joined(separator: " ").lowercased()
            let stated = words.range(of: #"\b(dub|dubbed|dubbing)\b"#, options: .regularExpression) != nil
            var attrs = EdgeAttributes()
            attrs.versionKind = stated ? .dub : .translatedSoundtrack
            b.claims.append(MusicClaimDraft(subject: backward ? subject : gd.ref, predicate: .relatedAlbum, object: backward ? gd.ref : subject, attributes: attrs, creditLevel: .album,
                                            confidence: 0.85, evidence: ["musicbrainz-relation", "translated version", stated ? "stated-dubbing" : "translated"]))
        }
    }

    private static func workDraft(_ w: [String: Any], into b: inout MusicClaimBatch) -> MusicDraftRef? {
        guard let id = MusicSourceKit.string(w["id"]), let title = MusicSourceKit.string(w["title"]) else { return nil }
        let r = MusicDraftRef.external(.work, ExternalID(.mbWork, id))
        if !b.drafts.contains(where: { $0.ref == r }) {
            let langs = (w["languages"] as? [String]) ?? []
            let lang = MusicSourceKit.language(MusicSourceKit.string(w["language"]) ?? langs.first)
            let iswcs = ((w["iswcs"] as? [String]) ?? []).map { ExternalID(.iswc, $0) }
            b.drafts.append(MusicSourceDraft(r, MusicEntityDraft(kind: .work, name: title, lang: lang, externalIDs: [ExternalID(.mbWork, id)] + iswcs)))
        }
        return r
    }

    private static func recordingDraft(_ rec: [String: Any]) -> MusicSourceDraft? {
        guard let id = MusicSourceKit.string(rec["id"]), let title = MusicSourceKit.string(rec["title"]) else { return nil }
        var ids = [ExternalID(.mbid, id)] + ((rec["isrcs"] as? [String]) ?? []).map { ExternalID(.isrc, $0.uppercased()) }
        ids += urlIDs(rec["relations"])
        let len = (rec["length"] as? Int) ?? (rec["length"] as? Double).map(Int.init)
        var attrs: [String: String] = [:]
        let artists = creditOrder((rec["artist-credit"] as? [[String: Any]]) ?? []).map(\.name)
        if !artists.isEmpty { attrs["artists"] = artists.joined(separator: "|") }
        let releases = ((rec["releases"] as? [[String: Any]]) ?? []).compactMap { MusicSourceKit.string($0["title"]) }
        if !releases.isEmpty { attrs["releases"] = Array(releases.prefix(5)).joined(separator: "|") }
        if let s = rec["score"] as? Int { attrs["mbScore"] = String(s) }
        return MusicSourceDraft(ref(.recording, id), MusicEntityDraft(kind: .recording, name: title, year: MusicSourceKit.year(rec["first-release-date"] as? String),
                                                                       durationMs: len, attrs: attrs, externalIDs: ids))
    }

    private static func creditClaims(_ rec: [String: Any], subject: MusicDraftRef, into b: inout MusicClaimBatch) {
        let credits = creditOrder((rec["artist-credit"] as? [[String: Any]]) ?? [])
        let vocal = Set(((rec["relations"] as? [[String: Any]]) ?? []).filter { ($0["type"] as? String) == "vocal" }.compactMap { (($0["artist"] as? [String: Any])?["id"]) as? String })
        for (i, c) in credits.enumerated() {
            if !b.drafts.contains(where: { $0.ref == c.draft.ref }) { b.drafts.append(c.draft) }
            if case .external(_, let x) = c.draft.ref, vocal.contains(x.value) { continue }
            b.claims.append(MusicClaimDraft(subject: subject, predicate: .performedBy, object: c.draft.ref, role: .performer, order: i, creditLevel: .song, confidence: 0.9,
                                            evidence: ["musicbrainz-artist-credit"]))
        }
    }

    /// Genres (not free tags beyond them) as `hasGenre` claims. CC BY-NC-SA: the claim carries that licence and the "MusicBrainz" attribution.
    private static func addGenres(_ j: [String: Any], subject: MusicDraftRef, into b: inout MusicClaimBatch) {
        for g in ((j["genres"] as? [[String: Any]]) ?? []).prefix(8) {
            guard let n = MusicSourceKit.string(g["name"]) else { continue }
            let d = MusicSourceKit.facetDraft(.genre, n)
            if !b.drafts.contains(where: { $0.ref == d.ref }) { b.drafts.append(d) }
            let votes = (g["count"] as? Int) ?? 1
            var c = MusicClaimDraft(subject: subject, predicate: .hasGenre, object: d.ref, creditLevel: .unknown, confidence: min(0.9, 0.5 + 0.1 * Float(votes)), evidence: ["musicbrainz-genre"])
            c.license = .ccByNcSa; c.attribution = "MusicBrainz"
            b.claims.append(c)
        }
    }

    // MARK: entities

    /// `recording/<mbid>?inc=artist-credits+isrcs+work-rels+work-level-rels+artist-rels+url-rels`.
    static func recording(_ data: Data, retrievedAt: Date = Date()) -> MusicClaimBatch? {
        guard let j = MusicSourceKit.json(data), let d = recordingDraft(j) else { return nil }
        var b = batch(retrievedAt); b.drafts.append(d)
        creditClaims(j, subject: d.ref, into: &b)
        addRelations((j["relations"] as? [[String: Any]]) ?? [], subject: d.ref, level: .song, into: &b)
        addGenres(j, subject: d.ref, into: &b)
        return b
    }

    /// `work/<mbid>?inc=artist-rels`.
    static func work(_ data: Data, retrievedAt: Date = Date()) -> MusicClaimBatch? {
        guard let j = MusicSourceKit.json(data) else { return nil }
        var b = batch(retrievedAt)
        guard let w = workDraft(j, into: &b) else { return nil }
        addRelations((j["relations"] as? [[String: Any]]) ?? [], subject: w, level: .song, into: &b)
        return b
    }

    static func subkind(primary: String?, secondary: [String]) -> String {
        let s = Set(secondary.map { $0.lowercased() })
        if s.contains("soundtrack") { return MusicAlbumSubkind.soundtrack.rawValue }
        if s.contains("compilation") { return MusicAlbumSubkind.compilation.rawValue }
        switch (primary ?? "").lowercased() { case "single": return MusicAlbumSubkind.single.rawValue; case "ep": return MusicAlbumSubkind.ep.rawValue; default: return MusicAlbumSubkind.album.rawValue }
    }

    /// `release-group/<mbid>?inc=url-rels+artist-credits+releases`: the album concept, its editions, and the Wikidata item it links to.
    static func releaseGroup(_ data: Data, retrievedAt: Date = Date()) -> MusicClaimBatch? {
        guard let j = MusicSourceKit.json(data), let d = releaseGroupDraft(j) else { return nil }
        var b = batch(retrievedAt); b.drafts.append(d)
        addGenres(j, subject: d.ref, into: &b)
        addReleaseGroupTranslations(j, subject: d.ref, into: &b)
        for (i, c) in creditOrder((j["artist-credit"] as? [[String: Any]]) ?? []).enumerated() {
            if !b.drafts.contains(where: { $0.ref == c.draft.ref }) { b.drafts.append(c.draft) }
            b.claims.append(MusicClaimDraft(subject: d.ref, predicate: .performedBy, object: c.draft.ref, role: .performer, order: i, creditLevel: .album, confidence: 0.9, evidence: ["musicbrainz-artist-credit"]))
        }
        for r in (j["releases"] as? [[String: Any]]) ?? [] {
            guard let id = MusicSourceKit.string(r["id"]), let t = MusicSourceKit.string(r["title"]) else { continue }
            let rr = ref(.release, id)
            b.drafts.append(MusicSourceDraft(rr, MusicEntityDraft(kind: .release, name: t, year: MusicSourceKit.year(r["date"] as? String), country: MusicSourceKit.string(r["country"]),
                                                                  externalIDs: [ExternalID(.mbid, id)])))
            b.claims.append(MusicClaimDraft(subject: rr, predicate: .editionOf, object: d.ref, creditLevel: .album, confidence: 0.98, evidence: ["musicbrainz-release-group"]))
            if let cover = r["cover-art-archive"] as? [String: Any], (cover["front"] as? Bool) == true { b.imageHints[rr] = "https://coverartarchive.org/release/\(id)/front-250" }
        }
        if b.imageHints.isEmpty, case .external(_, let x) = d.ref { b.imageHints[d.ref] = "https://coverartarchive.org/release-group/\(x.value)/front-250" }
        return b
    }

    private static func releaseGroupDraft(_ j: [String: Any]) -> MusicSourceDraft? {
        guard let id = MusicSourceKit.string(j["id"]), let title = MusicSourceKit.string(j["title"]) else { return nil }
        let sub = subkind(primary: j["primary-type"] as? String, secondary: (j["secondary-types"] as? [String]) ?? [])
        let ids = [ExternalID(.mbReleaseGroup, id)] + urlIDs(j["relations"])
        var attrs: [String: String] = [:]
        let artists = creditOrder((j["artist-credit"] as? [[String: Any]]) ?? []).map(\.name)
        if !artists.isEmpty { attrs["artists"] = artists.joined(separator: "|") }
        if let s = j["score"] as? Int { attrs["mbScore"] = String(s) }
        if let dis = MusicSourceKit.string(j["disambiguation"]), !dis.isEmpty { attrs["disambiguation"] = dis }
        return MusicSourceDraft(.external(.album, ExternalID(.mbReleaseGroup, id)),
                                MusicEntityDraft(kind: .album, name: title, subkind: sub, year: MusicSourceKit.year(j["first-release-date"] as? String), attrs: attrs, externalIDs: ids))
    }

    /// `release/<mbid>?inc=recordings+artist-credits+recording-level-rels+work-rels+work-level-rels`: the tracklist with credits where editors entered them.
    static func release(_ data: Data, retrievedAt: Date = Date()) -> MusicClaimBatch? {
        guard let j = MusicSourceKit.json(data), let id = MusicSourceKit.string(j["id"]), let title = MusicSourceKit.string(j["title"]) else { return nil }
        var b = batch(retrievedAt)
        let rr = ref(.release, id)
        let lang = MusicSourceKit.language(((j["text-representation"] as? [String: Any])?["language"]) as? String)
        b.drafts.append(MusicSourceDraft(rr, MusicEntityDraft(kind: .release, name: title, lang: lang, year: MusicSourceKit.year(j["date"] as? String), country: MusicSourceKit.string(j["country"]),
                                                              externalIDs: [ExternalID(.mbid, id)])))
        if let g = (j["release-group"] as? [String: Any]), let gd = releaseGroupDraft(g) {
            b.drafts.append(gd)
            b.claims.append(MusicClaimDraft(subject: rr, predicate: .editionOf, object: gd.ref, creditLevel: .album, confidence: 0.98, evidence: ["musicbrainz-release-group"]))
        }
        var order = 0
        for m in (j["media"] as? [[String: Any]]) ?? [] {
            let disc = (m["position"] as? Int) ?? 1
            for t in (m["tracks"] as? [[String: Any]]) ?? [] {
                guard var rec = t["recording"] as? [String: Any] else { continue }
                if rec["title"] == nil { rec["title"] = t["title"] }
                if rec["artist-credit"] == nil { rec["artist-credit"] = t["artist-credit"] }
                guard let d = recordingDraft(rec) else { continue }
                order += 1
                if !b.drafts.contains(where: { $0.ref == d.ref }) { b.drafts.append(d) }
                var attrs = EdgeAttributes(); attrs.disc = disc; attrs.position = (t["position"] as? Int) ?? order
                b.claims.append(MusicClaimDraft(subject: d.ref, predicate: .trackOn, object: rr, attributes: attrs, order: order, creditLevel: .album, confidence: 0.98, evidence: ["musicbrainz-tracklist"]))
                creditClaims(rec, subject: d.ref, into: &b)
                addRelations((rec["relations"] as? [[String: Any]]) ?? [], subject: d.ref, level: .song, into: &b)
            }
        }
        if (j["cover-art-archive"] as? [String: Any])?["front"] as? Bool == true { b.imageHints[rr] = "https://coverartarchive.org/release/\(id)/front-250" }
        return b
    }

    /// `artist/<mbid>?inc=url-rels+aliases`.
    static func artist(_ data: Data, retrievedAt: Date = Date()) -> MusicClaimBatch? {
        guard let j = MusicSourceKit.json(data), let d = artistDraft(j) else { return nil }
        var b = batch(retrievedAt); b.drafts.append(d)
        addGenres(j, subject: d.ref, into: &b)
        addBandMembership(j, subject: d, into: &b)
        return b
    }

    /// "Member of band" links on an artist. MusicBrainz words them by direction: on a person a forward link names the band they belong to, and on a band a
    /// backward link names a member. The instruments ride along as the edge's qualifier; the dates are not kept.
    private static func addBandMembership(_ j: [String: Any], subject: MusicSourceDraft, into b: inout MusicClaimBatch) {
        for r in (j["relations"] as? [[String: Any]]) ?? [] where (r["type"] as? String) == "member of band" && (r["target-type"] as? String) == "artist" {
            guard let other = r["artist"] as? [String: Any], let d = artistDraft(other, includeLife: false), let dir = r["direction"] as? String else { continue }
            let (member, band): (MusicDraftRef, MusicDraftRef)
            switch (dir, subject.ref.kind, d.ref.kind) {
            case ("forward", .person, .group): (member, band) = (subject.ref, d.ref)
            case ("backward", .group, .person): (member, band) = (d.ref, subject.ref)
            default: continue                            // not a person-and-band pair: nothing is stated about membership
            }
            if !b.drafts.contains(where: { $0.ref == d.ref }) { b.drafts.append(d) }
            var attrs = EdgeAttributes()
            let at = ((r["attributes"] as? [String]) ?? []).filter { !["original", "founder", "additional", "minor"].contains($0) }
            if !at.isEmpty { attrs.instrument = at.joined(separator: ", ") }
            b.claims.append(MusicClaimDraft(subject: member, predicate: .memberOf, object: band, attributes: attrs, creditLevel: .unknown, confidence: 0.9,
                                            evidence: ["musicbrainz-relation", "member of band"]))
        }
    }

    // MARK: searches (candidates, scored by the resolver)

    static func recordingSearch(_ data: Data, retrievedAt: Date = Date()) -> MusicClaimBatch {
        var b = batch(retrievedAt); b.isSearch = true
        for r in (MusicSourceKit.json(data)?["recordings"] as? [[String: Any]]) ?? [] { if let d = recordingDraft(r) { b.drafts.append(d) } }
        return b
    }

    /// `isrc/<ISRC>?inc=artist-credits`: `{ "isrc": ..., "recordings": [...] }`.
    static func isrcLookup(_ data: Data, retrievedAt: Date = Date()) -> MusicClaimBatch { recordingSearch(data, retrievedAt: retrievedAt) }

    /// `release-group?artist=<mbid>&type=album|ep|single`: the artist's discography as albums with a `performedBy` claim each.
    static func discography(_ data: Data, artist: MusicDraftRef, retrievedAt: Date = Date()) -> MusicClaimBatch {
        var b = batch(retrievedAt)
        for (i, r) in (((MusicSourceKit.json(data)?["release-groups"]) as? [[String: Any]]) ?? []).enumerated() {
            guard let d = releaseGroupDraft(r) else { continue }
            b.drafts.append(d)
            b.claims.append(MusicClaimDraft(subject: d.ref, predicate: .performedBy, object: artist, role: .performer, order: i, creditLevel: .album, confidence: 0.9, evidence: ["musicbrainz-discography"]))
        }
        return b
    }

    static func releaseGroupSearch(_ data: Data, retrievedAt: Date = Date()) -> MusicClaimBatch {
        var b = batch(retrievedAt); b.isSearch = true
        for r in (MusicSourceKit.json(data)?["release-groups"] as? [[String: Any]]) ?? [] { if let d = releaseGroupDraft(r) { b.drafts.append(d) } }
        return b
    }
}

/// MusicBrainz as a source. One request per facet, through the transport (the governor paces it: one a second, 503 is normal pressure).
struct MusicBrainzSource: MusicMetadataSource {
    var transport: any MusicMetadataTransport
    var id: MusicSourceID { .musicbrainz }
    static let base = URL(string: "https://musicbrainz.org/ws/2/")!

    var policy: MusicSourcePolicy {
        MusicSourcePolicy(hosts: ["musicbrainz.org", "coverartarchive.org"], license: .cc0, retention: nil, attribution: nil,
                          ttl: [MusicFacet.recordingCredits: 60 * 86_400, MusicFacet.releaseTracklist: 60 * 86_400, MusicFacet.releaseGroup: 60 * 86_400,
                                MusicFacet.workCredits: 60 * 86_400, MusicFacet.artist: 30 * 86_400],
                          defaultTTL: 60 * 86_400, defaultOn: true,
                          privacyNote: "Song, album and artist names, durations and ISRC codes are sent to MusicBrainz (musicbrainz.org) to find credits. No account, and never your listening history.")
    }

    private func get(_ path: String, _ q: [String: String]) async throws -> Data {
        var q = q; q["fmt"] = "json"
        return try await transport.get(Self.base.appendingPathComponent(path), query: q, headers: MusicSourceKit.headers)
    }

    private static func lucene(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: " ").replacingOccurrences(of: "\"", with: " ") + "\"" }

    func fetch(_ r: MusicSourceRequest, context: MusicFetchContext) async throws -> MusicClaimBatch {
        let now = context.now()
        switch r.facet {
        case MusicFacet.recordingByISRC:
            guard let isrc = r.param("isrc") else { throw MusicSourceError.badRequest("isrc") }
            return MusicBrainzParser.isrcLookup(try await get("isrc/" + isrc, ["inc": "artist-credits"]), retrievedAt: now)
        case MusicFacet.recordingSearch:
            guard let title = r.param("title") else { throw MusicSourceError.badRequest("title") }
            var q = "recording:" + Self.lucene(title)
            if let a = r.param("artist") { q += " AND artist:" + Self.lucene(a) }
            if let d = r.param("durationMs").flatMap(Int.init), d > 0 { q += " AND dur:[\(max(0, d - 10_000)) TO \(d + 10_000)]" }
            return MusicBrainzParser.recordingSearch(try await get("recording", ["query": q, "limit": "8"]), retrievedAt: now)
        case MusicFacet.recordingCredits:
            guard let id = r.param("mbid") else { throw MusicSourceError.badRequest("mbid") }
            guard let b = MusicBrainzParser.recording(try await get("recording/" + id, ["inc": "artist-credits+isrcs+work-rels+work-level-rels+artist-rels+url-rels+genres+recording-rels+release-rels"]), retrievedAt: now) else { throw MusicError.network("unexpected reply") }
            return b
        case MusicFacet.releaseGroupSearch:
            guard let title = r.param("title") else { throw MusicSourceError.badRequest("title") }
            var q = "releasegroup:" + Self.lucene(title)
            if let a = r.param("artist") { q += " AND artist:" + Self.lucene(a) }
            return MusicBrainzParser.releaseGroupSearch(try await get("release-group", ["query": q, "limit": "8"]), retrievedAt: now)
        case MusicFacet.releaseGroup:
            guard let id = r.param("mbid") else { throw MusicSourceError.badRequest("mbid") }
            guard let b = MusicBrainzParser.releaseGroup(try await get("release-group/" + id, ["inc": "url-rels+artist-credits+releases+genres+release-group-rels"]), retrievedAt: now) else { throw MusicError.network("unexpected reply") }
            return b
        case MusicFacet.releaseTracklist:
            guard let id = r.param("mbid") else { throw MusicSourceError.badRequest("mbid") }
            guard let b = MusicBrainzParser.release(try await get("release/" + id, ["inc": "recordings+artist-credits+recording-level-rels+work-rels+work-level-rels+release-groups"]), retrievedAt: now) else { throw MusicError.network("unexpected reply") }
            return b
        case MusicFacet.workCredits:
            guard let id = r.param("mbid") else { throw MusicSourceError.badRequest("mbid") }
            guard let b = MusicBrainzParser.work(try await get("work/" + id, ["inc": "artist-rels+work-rels"]), retrievedAt: now) else { throw MusicError.network("unexpected reply") }
            return b
        case "artistDiscography":
            guard let id = r.param("mbid") else { throw MusicSourceError.badRequest("mbid") }
            return MusicBrainzParser.discography(try await get("release-group", ["artist": id, "limit": "100", "type": "album|ep|single"]), artist: .external(.person, ExternalID(.mbid, id)), retrievedAt: now)
        case MusicFacet.artist:
            guard let id = r.param("mbid") else { throw MusicSourceError.badRequest("mbid") }
            guard let b = MusicBrainzParser.artist(try await get("artist/" + id, ["inc": "url-rels+aliases+genres+artist-rels"]), retrievedAt: now) else { throw MusicError.network("unexpected reply") }
            return b
        default: throw MusicSourceError.unsupported(r.facet)
        }
    }
}
