import Foundation

/// ListenBrainz metadata (open data): one batched call bridges recording MBIDs to streaming links, artist Wikidata links and the cover-art release.
enum MusicListenBrainzParser {
    static func metadata(_ data: Data, retrievedAt: Date = Date()) -> MusicClaimBatch {
        var b = MusicClaimBatch(source: .listenbrainz, license: .cc0, retrievedAt: retrievedAt)
        guard let j = MusicSourceKit.json(data) else { return b }
        for (mbid, v) in j {
            guard let m = v as? [String: Any], let rec = m["recording"] as? [String: Any] else { continue }
            var ids = [ExternalID(.mbid, mbid)] + ((rec["isrcs"] as? [String]) ?? []).map { ExternalID(.isrc, $0.uppercased()) }
            for u in (rec["url_rels"] as? [[String: Any]]) ?? [] { if let s = u["url"] as? String, let x = MusicExternalLinks.externalID(fromURL: s) { ids.append(x) } }
            let name = MusicSourceKit.string(rec["name"]) ?? mbid
            let rref = MusicDraftRef.external(.recording, ExternalID(.mbid, mbid))
            b.drafts.append(MusicSourceDraft(rref, MusicEntityDraft(kind: .recording, name: name, durationMs: rec["length"] as? Int, externalIDs: ids)))
            for (i, a) in (((m["artist"] as? [String: Any])?["artists"] as? [[String: Any]]) ?? []).enumerated() {
                guard let am = MusicSourceKit.string(a["artist_mbid"]), let an = MusicSourceKit.string(a["name"]) else { continue }
                var aids = [ExternalID(.mbid, am)]
                for (_, link) in (a["rels"] as? [String: Any]) ?? [:] { if let s = link as? String, let x = MusicExternalLinks.externalID(fromURL: s), x.scheme == .wikidata { aids.append(x) } }
                let kind: MusicEntityKind = (a["type"] as? String) == "Group" ? .group : .person
                let aref = MusicDraftRef.external(kind, ExternalID(.mbid, am))
                b.drafts.append(MusicSourceDraft(aref, MusicEntityDraft(kind: kind, name: an, year: a["begin_year"] as? Int, yearEnd: a["end_year"] as? Int, country: nil, externalIDs: aids)))
                b.claims.append(MusicClaimDraft(subject: rref, predicate: .performedBy, object: aref, role: .performer, order: i, creditLevel: .song, confidence: 0.85, evidence: ["listenbrainz-metadata"]))
            }
            if let rel = m["release"] as? [String: Any], let caa = rel["caa_release_mbid"] as? String { b.imageHints[rref] = "https://coverartarchive.org/release/\(caa)/front-250" }
        }
        return b
    }

    /// `labs` similar artists: candidate people with a score; no facts are written.
    static func similarArtists(_ data: Data, retrievedAt: Date = Date()) -> MusicClaimBatch {
        var b = MusicClaimBatch(source: .listenbrainz, license: .cc0, retrievedAt: retrievedAt); b.isSearch = true
        let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        for r in rows.prefix(40) {
            guard let m = MusicSourceKit.string(r["artist_mbid"]), let n = MusicSourceKit.string(r["name"]) else { continue }
            let score = (r["score"] as? Double).map { String($0) } ?? ""
            b.drafts.append(MusicSourceDraft(.external(.person, ExternalID(.mbid, m)), MusicEntityDraft(kind: .person, name: n, attrs: ["similarScore": score], externalIDs: [ExternalID(.mbid, m)])))
        }
        return b
    }
}

struct ListenBrainzGraphSource: MusicMetadataSource {
    var transport: any MusicMetadataTransport
    var id: MusicSourceID { .listenbrainz }

    var policy: MusicSourcePolicy {
        MusicSourcePolicy(hosts: ["api.listenbrainz.org", "labs.api.listenbrainz.org"], license: .cc0, retention: nil, attribution: "ListenBrainz",
                          ttl: [MusicFacet.similarArtists: 7 * 86_400, MusicFacet.recordingMetadata: 30 * 86_400], defaultTTL: 30 * 86_400, defaultOn: true,
                          privacyNote: "MusicBrainz recording ids (not names or your plays) are sent to ListenBrainz (listenbrainz.org) to find streaming and artist links. No account.")
    }

    func fetch(_ r: MusicSourceRequest, context: MusicFetchContext) async throws -> MusicClaimBatch {
        let now = context.now()
        switch r.facet {
        case MusicFacet.recordingMetadata:
            let ids = (r.param("mbids") ?? "").split(separator: ",").map(String.init).filter { $0.count == 36 }.prefix(25)
            guard !ids.isEmpty else { throw MusicSourceError.badRequest("mbids") }
            let d = try await transport.get(URL(string: "https://api.listenbrainz.org/1/metadata/recording/")!, query: ["recording_mbids": ids.joined(separator: ","), "inc": "artist release"], headers: MusicSourceKit.headers)
            return MusicListenBrainzParser.metadata(d, retrievedAt: now)
        case MusicFacet.similarArtists:
            guard let m = r.param("mbid"), m.count == 36 else { throw MusicSourceError.badRequest("mbid") }
            let d = try await transport.get(URL(string: "https://labs.api.listenbrainz.org/similar-artists/json")!,
                                            query: ["artist_mbids": m, "algorithm": "session_based_days_9000_session_300_contribution_5_threshold_15_limit_50_skip_30"], headers: MusicSourceKit.headers)
            return MusicListenBrainzParser.similarArtists(d, retrievedAt: now)
        default: throw MusicSourceError.unsupported(r.facet)
        }
    }
}
