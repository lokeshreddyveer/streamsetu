import Foundation

/// Discogs release credits as text roles ("Music By", "Lyrics By", "Vocals"). Built and OFF by default: keyless limits are low (about 25 a minute) and
/// the search needs a token; the person may add one. Credits only; Discogs images are never stored. Shown with "Data provided by Discogs".
enum MusicDiscogsParser {
    static func role(_ text: String) -> (MusicPredicate, MusicRole)? {
        let t = text.lowercased()
        if t.contains("lyrics") || t.contains("words by") { return (.writtenBy, .lyricist) }
        if t.contains("written") { return (.writtenBy, .writer) }
        if t.contains("music by") || t.contains("composed") || t.contains("music director") { return (.composedBy, .composer) }
        if t.contains("arrang") { return (.composedBy, .arranger) }
        if t.contains("vocal") || t.contains("singer") { return (.performedBy, .singer) }
        if t.contains("producer") || t.contains("produced") { return (.producedBy, .producer) }
        return nil
    }

    /// `/releases/{id}`: tracks with per-track `extraartists`, plus release-level credits applied at album level.
    static func release(_ data: Data, retrievedAt: Date = Date()) -> MusicClaimBatch? {
        guard let j = MusicSourceKit.json(data), let id = j["id"] as? Int, let title = MusicSourceKit.string(j["title"]) else { return nil }
        var b = MusicClaimBatch(source: .discogs, license: .termsRestricted, retrievedAt: retrievedAt, retention: 30 * 86_400, attribution: "Discogs")
        let did = ExternalID(.discogs, "release/\(id)"); let rr = MusicDraftRef.external(.release, did)
        b.drafts.append(MusicSourceDraft(rr, MusicEntityDraft(kind: .release, name: title, year: j["year"] as? Int, externalIDs: [did])))
        func person(_ a: [String: Any]) -> MusicDraftRef? {
            guard let n = MusicSourceKit.string(a["name"]), let aid = a["id"] as? Int else { return nil }
            let x = ExternalID(.discogs, "artist/\(aid)"); let r = MusicDraftRef.external(.person, x)
            if !b.drafts.contains(where: { $0.ref == r }) { b.drafts.append(MusicSourceDraft(r, MusicEntityDraft(kind: .person, name: n.replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression), externalIDs: [x]))) }
            return r
        }
        func credits(_ list: Any?, subject: MusicDraftRef, level: CreditLevel) {
            for a in (list as? [[String: Any]]) ?? [] {
                guard let rt = a["role"] as? String else { continue }
                for part in rt.split(separator: ",") {
                    guard let (pred, role) = role(String(part)), let p = person(a), pred.accepts(subject: subject.kind, object: p.kind) else { continue }
                    var c = MusicClaimDraft(subject: subject, predicate: pred, object: p, role: role, creditLevel: level, confidence: 0.6, evidence: ["discogs-credit", String(part).trimmingCharacters(in: .whitespaces)])
                    c.attribution = "Discogs"
                    b.claims.append(c)
                }
            }
        }
        credits(j["extraartists"], subject: rr, level: .album)
        for (i, t) in ((j["tracklist"] as? [[String: Any]]) ?? []).enumerated() {
            guard let tt = MusicSourceKit.string(t["title"]), (t["type_"] as? String ?? "track") == "track" else { continue }
            let key = "discogs|\(id)|" + MusicGraphText.latin(tt)
            let rec = MusicDraftRef.local(.recording, key)
            b.drafts.append(MusicSourceDraft(rec, MusicEntityDraft(kind: .recording, name: tt, externalIDs: [ExternalID(.canon, key)], provisional: true)))
            var a = EdgeAttributes(); a.position = i + 1
            b.claims.append(MusicClaimDraft(subject: rec, predicate: .trackOn, object: rr, attributes: a, order: i + 1, creditLevel: .album, confidence: 0.6, evidence: ["discogs-tracklist"]))
            credits(t["extraartists"], subject: rec, level: .song)
        }
        return b
    }
}

struct DiscogsSource: MusicMetadataSource {
    var transport: any MusicMetadataTransport
    var token: @Sendable () -> String? = { nil }
    var id: MusicSourceID { .discogs }

    var policy: MusicSourcePolicy {
        MusicSourcePolicy(hosts: ["api.discogs.com"], license: .termsRestricted, retention: 30 * 86_400, attribution: "Discogs", ttl: [:], defaultTTL: 30 * 86_400, defaultOn: false,
                          privacyNote: "Album titles and artist names are sent to Discogs (discogs.com) to read per-song credits. Off by default; slow, because Discogs limits requests.")
    }

    func fetch(_ r: MusicSourceRequest, context: MusicFetchContext) async throws -> MusicClaimBatch {
        let now = context.now()
        var h = MusicSourceKit.headers
        if let t = token(), !t.isEmpty { h["Authorization"] = "Discogs token=" + t }
        switch r.facet {
        case MusicFacet.releaseTracklist:
            guard let id = r.param("release"), Int(id) != nil else { throw MusicSourceError.badRequest("release") }
            guard let b = MusicDiscogsParser.release(try await transport.get(URL(string: "https://api.discogs.com/releases/\(id)")!, query: [:], headers: h), retrievedAt: now) else { throw MusicError.network("unexpected reply") }
            return b
        case MusicFacet.releaseGroupSearch:
            guard let t = r.param("title"), token() != nil else { throw MusicSourceError.disabled }
            let d = try await transport.get(URL(string: "https://api.discogs.com/database/search")!, query: ["q": t + " " + (r.param("artist") ?? ""), "type": "release", "per_page": "5"], headers: h)
            var b = MusicClaimBatch(source: .discogs, license: .termsRestricted, retrievedAt: now, retention: 30 * 86_400, attribution: "Discogs"); b.isSearch = true
            for row in ((MusicSourceKit.json(d)?["results"] as? [[String: Any]]) ?? []) {
                guard let id = row["id"] as? Int, let n = MusicSourceKit.string(row["title"]) else { continue }
                let x = ExternalID(.discogs, "release/\(id)")
                b.drafts.append(MusicSourceDraft(.external(.release, x), MusicEntityDraft(kind: .release, name: n, year: Int((row["year"] as? String) ?? ""), externalIDs: [x])))
            }
            return b
        default: throw MusicSourceError.unsupported(r.facet)
        }
    }
}

/// Last.fm: only when a key is available (the person's own, else the app's built-in one through `LastFMKeys`). Similar artists are candidates (nothing
/// written); tags become low-confidence genre edges with attribution "Last.fm".
struct LastFMGraphSource: MusicMetadataSource {
    var transport: any MusicMetadataTransport
    var key: @Sendable () -> String?
    var id: MusicSourceID { MusicSourceID.lastfm }

    var policy: MusicSourcePolicy {
        MusicSourcePolicy(hosts: ["ws.audioscrobbler.com"], license: .termsRestricted, retention: 30 * 86_400, attribution: "Last.fm", ttl: [MusicFacet.similarArtists: 7 * 86_400], defaultTTL: 7 * 86_400,
                          defaultOn: key() != nil, privacyNote: "Artist names are sent to Last.fm (last.fm) with the application key, to find similar artists and tags. On only when a key is available.")
    }

    static func similar(_ data: Data, retrievedAt: Date) -> MusicClaimBatch {
        var b = MusicClaimBatch(source: MusicSourceID.lastfm, license: .termsRestricted, retrievedAt: retrievedAt, retention: 30 * 86_400, attribution: "Last.fm"); b.isSearch = true
        for a in ((MusicSourceKit.json(data)?["similarartists"] as? [String: Any])?["artist"] as? [[String: Any]]) ?? [] {
            guard let n = MusicSourceKit.string(a["name"]) else { continue }
            var ids: [ExternalID] = []; if let m = MusicSourceKit.string(a["mbid"]) { ids.append(ExternalID(.mbid, m)) }
            b.drafts.append(MusicSourceDraft(ids.first.map { .external(.person, $0) } ?? .local(.person, MusicGraphText.latin(n)), MusicEntityDraft(kind: .person, name: n, attrs: ["similarScore": MusicSourceKit.string(a["match"]) ?? ""], externalIDs: ids)))
        }
        return b
    }

    /// `artist.getTopTags`: user-made tags as `hasGenre` claims (attribution "Last.fm"), low confidence, the heavily voted ones only.
    static func topTags(_ data: Data, artist: MusicDraftRef, retrievedAt: Date) -> MusicClaimBatch {
        var b = MusicClaimBatch(source: MusicSourceID.lastfm, license: .termsRestricted, retrievedAt: retrievedAt, retention: 30 * 86_400, attribution: "Last.fm")
        let tags = ((MusicSourceKit.json(data)?["toptags"] as? [String: Any])?["tag"] as? [[String: Any]]) ?? []
        for t in tags.prefix(6) {
            guard let n = MusicSourceKit.string(t["name"]), (Int(MusicSourceKit.string(t["count"]) ?? "") ?? (t["count"] as? Int) ?? 0) >= 20, n.count <= 30 else { continue }
            let d = MusicSourceKit.facetDraft(.genre, n)
            if !b.drafts.contains(where: { $0.ref == d.ref }) { b.drafts.append(d) }
            var c = MusicClaimDraft(subject: artist, predicate: .hasGenre, object: d.ref, confidence: 0.5, evidence: ["lastfm-tag"])
            c.attribution = "Last.fm"
            b.claims.append(c)
        }
        return b
    }

    func fetch(_ r: MusicSourceRequest, context: MusicFetchContext) async throws -> MusicClaimBatch {
        guard let k = key(), !k.isEmpty else { throw MusicSourceError.disabled }
        if r.facet == "topTags", let a = r.param("artist") {
            let d = try await transport.get(URL(string: "https://ws.audioscrobbler.com/2.0/")!, query: ["method": "artist.gettoptags", "artist": a, "api_key": k, "format": "json"], headers: MusicSourceKit.headers)
            let ref: MusicDraftRef = r.param("mbid").map { .external(.person, ExternalID(.mbid, $0)) } ?? .local(.person, MusicGraphText.latin(a))
            var b = Self.topTags(d, artist: ref, retrievedAt: context.now())
            if case .local = ref { b.drafts.append(MusicSourceDraft(ref, MusicEntityDraft(kind: .person, name: a, externalIDs: [ExternalID(.canon, "lastfm|" + MusicGraphText.latin(a))], provisional: true))) }
            return b
        }
        guard r.facet == MusicFacet.similarArtists, let a = r.param("artist") else { throw MusicSourceError.unsupported(r.facet) }
        let d = try await transport.get(URL(string: "https://ws.audioscrobbler.com/2.0/")!, query: ["method": "artist.getsimilar", "artist": a, "api_key": k, "format": "json", "limit": "30"], headers: MusicSourceKit.headers)
        return Self.similar(d, retrievedAt: context.now())
    }
}

/// The hook G3 fills: a provider's own credits (starring, music, singer, lyricist) as claims, from replies the page already fetched. No network here.
struct MusicProviderCreditsSource: MusicMetadataSource {
    typealias Mapper = @Sendable (MusicSourceRequest) async throws -> MusicClaimBatch?
    var mappers: [String: Mapper]
    var id: MusicSourceID { MusicSourceID("providerCredits") }
    var policy: MusicSourcePolicy {
        MusicSourcePolicy(hosts: [], license: .providerCache, retention: nil, attribution: nil, ttl: [:], defaultTTL: 14 * 86_400, defaultOn: true,
                          privacyNote: "Nothing extra is sent: credits already in the music source's own replies are read.")
    }
    func fetch(_ r: MusicSourceRequest, context: MusicFetchContext) async throws -> MusicClaimBatch {
        guard let p = r.param("provider"), let m = mappers[p], let b = try await m(r) else { return MusicClaimBatch(source: id, license: .providerCache, retrievedAt: context.now()) }
        return b
    }
}
