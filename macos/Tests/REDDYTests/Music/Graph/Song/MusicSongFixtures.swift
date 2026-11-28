import Foundation
import Testing
@testable import REDDY

/// A small hand-built graph for the song page: Awaara (1951) with its soundtrack, versions, credits and neighbours, a Telugu film song whose film link is
/// only inferred, a song with no credits and an independent artist's song. Every edge says which source claimed it, like the real ingest does.
final class SongFixture: @unchecked Sendable {
    let graph = MusicInMemoryGraph()
    var ids: [String: MusicEntityID] = [:]
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    subscript(_ key: String) -> MusicEntityID { ids[key]! }

    @discardableResult
    func entity(_ key: String, _ kind: MusicEntityKind, _ name: String, uid: String? = nil, year: Int? = nil, country: String? = nil, subkind: String? = nil,
                attrs: [String: String] = [:], duration: Int? = nil, provisional: Bool = false, extra: [ExternalID] = []) async -> MusicEntityID {
        var ext = extra
        if let uid { ext.insert(ExternalID(.provider, uid), at: 0) }
        if ext.isEmpty { ext = [ExternalID(.canon, kind.slug + "|" + key)] }
        let d = MusicEntityDraft(kind: kind, name: name, subkind: subkind, year: year, country: country, durationMs: duration, attrs: attrs, externalIDs: ext, provisional: provisional)
        let r = try! await graph.upsert(d)
        ids[key] = r.id
        return r.id
    }

    /// Adds one claim. `stated` marks a source that says the film link in so many words (the only way a soundtrack or film link can be verified).
    @discardableResult
    func edge(_ s: String, _ p: MusicPredicate, _ o: String, role: MusicRole? = nil, source: MusicSourceID = .musicbrainz, score: Float? = nil, stated: Bool = false,
              version: MusicVersionKind? = nil, level: CreditLevel = .song, order: Int? = nil, instrument: String? = nil) async -> MusicEdge {
        var attrs = EdgeAttributes()
        attrs.versionKind = version
        attrs.instrument = instrument
        let e = MusicEdge(subject: self[s], predicate: p, object: self[o], qualifier: role?.rawValue ?? "", attributes: attrs, creditLevel: level, order: order)
        let prov = MusicProvenance(source: source, retrievedAt: t0, license: .providerCache, score: score, evidence: stated ? [MusicProvenance.statedToken] : [])
        return try! await graph.addEdge(e, provenance: prov)
    }

    /// The Awaara (1951) fixture graph.
    static func awaara() async -> SongFixture {
        let f = SongFixture()
        // people and groups
        await f.entity("mukesh", .person, "Mukesh", uid: "jiosaavn:a-mukesh", year: 1923, country: "IN")
        await f.entity("lata", .person, "Lata Mangeshkar", uid: "jiosaavn:a-lata", year: 1929, country: "IN")
        await f.entity("sj", .group, "Shankar-Jaikishan", uid: "jiosaavn:a-sj", subkind: "duo")
        await f.entity("shailendra", .person, "Shailendra", uid: "jiosaavn:a-shailendra", year: 1923, country: "IN")
        await f.entity("hasrat", .person, "Hasrat Jaipuri", uid: "jiosaavn:a-hasrat")
        await f.entity("rajkapoor", .person, "Raj Kapoor", extra: [ExternalID(.tmdbPerson, "1")])
        // the film, its soundtrack album and its release
        await f.entity("awaara51", .film, "Awaara", year: 1951, extra: [ExternalID(.tmdbMovie, "39039")])
        await f.entity("awaara10", .film, "Awaara", year: 2010, extra: [ExternalID(.tmdbMovie, "50000")])
        await f.entity("shree420", .film, "Shree 420", year: 1955, extra: [ExternalID(.tmdbMovie, "39040")])
        await f.entity("albumA", .album, "Awaara", year: 1951, subkind: "soundtrack", extra: [ExternalID(.mbReleaseGroup, "rg-awaara")])
        await f.entity("releaseA", .release, "Awaara", uid: "jiosaavn:alb-awaara", year: 1951, subkind: "soundtrack")
        // the work and its recordings
        await f.entity("work", .work, "Awara Hoon", extra: [ExternalID(.mbWork, "w-awara")])
        await f.entity("awara", .recording, "Awara Hoon", uid: "ytmusic:AbCdEfGhIjK", year: 1951, duration: 233_000, extra: [ExternalID(.isrc, "INA000100001")])
        await f.entity("remix", .recording, "Awara Hoon (Remix)", uid: "jiosaavn:s-remix", year: 2022, attrs: ["versionKind": "remix", "versionEvidence": "title-remix"])
        await f.entity("karaoke", .recording, "Awara Hoon (Karaoke Version)", uid: "jiosaavn:s-karaoke", year: 2019)
        await f.entity("live", .recording, "Awara Hoon (Live)", uid: "jiosaavn:s-live", year: 1990)
        await f.entity("cover", .recording, "Awara Hoon", uid: "jiosaavn:s-cover", year: 2015, extra: [ExternalID(.canon, "cover-by-other")])
        await f.entity("rerec", .recording, "Awara Hoon (1960)", uid: "jiosaavn:s-rerec", year: 1960)
        await f.entity("coverArtist", .person, "Arijit Singh", uid: "jiosaavn:a-arijit", year: 1987, country: "IN")
        // album-mates and other songs
        await f.entity("ghar", .recording, "Ghar Aaya Mera Pardesi", uid: "jiosaavn:s-ghar", year: 1951)
        await f.entity("dum", .recording, "Dum Bhar Jo Udhar", uid: "jiosaavn:s-dum", year: 1951)
        await f.entity("mera", .recording, "Mera Joota Hai Japani", uid: "jiosaavn:s-mera", year: 1955)
        await f.entity("kisi", .recording, "Kisi Ki Muskurahaton Pe", uid: "jiosaavn:s-kisi", year: 1959)
        await f.entity("jaane", .recording, "Jaane Kahan Gaye Woh Din", uid: "jiosaavn:s-jaane", year: 1970)
        await f.entity("playlist", .playlist, "Golden Hits", uid: "jiosaavn:pl-golden")
        // facets
        await f.entity("hin", .language, "Hindi", attrs: ["iso639": "hin"])
        await f.entity("e50", .era, "1950s", attrs: ["decade": "1950s"])
        await f.entity("filmi", .genre, "Filmi", attrs: ["slug": "filmi"])

        // placement and film link: the album is the soundtrack of the film, inferred (nobody stated it)
        await f.edge("awara", .trackOn, "releaseA", source: .jiosaavn, score: 0.9, level: .album)
        await f.edge("releaseA", .editionOf, "albumA")
        await f.edge("albumA", .soundtrackOf, "awaara51", source: .jiosaavn, score: 0.7, level: .film)
        for k in ["ghar", "dum"] { await f.edge(k, .trackOn, "releaseA", source: .jiosaavn, score: 0.9, level: .album) }
        await f.edge("mera", .featuredIn, "shree420", source: .tmdb, stated: true)
        // credits (singer and composer verified by MusicBrainz, the rest from the provider)
        await f.edge("awara", .performedBy, "mukesh", role: .singer, order: 0)
        await f.edge("awara", .composedBy, "sj", role: .composer, order: 0)
        await f.edge("awara", .musicDirectedBy, "sj", role: .musicDirector, source: .jiosaavn, score: 0.9)
        await f.edge("awara", .writtenBy, "shailendra", role: .lyricist, order: 0)
        await f.edge("ghar", .performedBy, "lata", role: .singer)
        await f.edge("dum", .performedBy, "mukesh", role: .singer)
        await f.edge("kisi", .performedBy, "mukesh", role: .singer)
        await f.edge("jaane", .performedBy, "mukesh", role: .singer)
        await f.edge("mera", .performedBy, "mukesh", role: .singer)
        await f.edge("kisi", .composedBy, "sj", role: .composer)
        await f.edge("mera", .composedBy, "sj", role: .composer)
        await f.edge("shree420", .composedBy, "sj", role: .composer, source: .tmdb, level: .film)
        await f.edge("shree420", .hasCast, "rajkapoor", role: .actor, source: .tmdb, level: .film)
        await f.edge("awaara51", .composedBy, "sj", role: .composer, source: .tmdb, level: .film)
        // versions
        await f.edge("awara", .recordingOf, "work")
        await f.edge("rerec", .recordingOf, "work")
        await f.edge("cover", .recordingOf, "work")
        await f.edge("remix", .alternateOf, "awara", source: .matcher, score: 0.8, version: .remix)
        await f.edge("karaoke", .alternateOf, "awara", source: .matcher, score: 0.8, version: .karaoke)
        await f.edge("live", .alternateOf, "awara", version: .live)
        await f.edge("cover", .alternateOf, "awara", version: .cover)
        await f.edge("cover", .performedBy, "coverArtist", role: .singer)
        await f.edge("playlist", .playlistContains, "awara", source: .jiosaavn, score: 0.9)
        // facets
        for k in ["awara", "ghar", "dum", "mera"] {
            await f.edge(k, .inLanguage, "hin", source: .jiosaavn, score: 0.9)
            await f.edge(k, .ofEra, "e50", source: .jiosaavn, score: 0.9)
        }
        for k in ["awara", "ghar"] { await f.edge(k, .hasGenre, "filmi", source: .jiosaavn, score: 0.9) }
        return f
    }

    /// A Telugu film song: the album is only inferred to be the film's soundtrack, no song-level film edge.
    static func telugu() async -> SongFixture {
        let f = SongFixture()
        await f.entity("armaan", .person, "Armaan Malik", uid: "jiosaavn:a-armaan")
        await f.entity("thaman", .person, "Thaman S", uid: "jiosaavn:a-thaman")
        await f.entity("film", .film, "Ala Vaikunthapurramuloo", year: 2020, extra: [ExternalID(.tmdbMovie, "612")])
        await f.entity("rel", .release, "Ala Vaikunthapurramuloo (Original Motion Picture Soundtrack)", uid: "jiosaavn:alb-ala", year: 2020, subkind: "soundtrack")
        await f.entity("butta", .recording, "Butta Bomma", uid: "jiosaavn:s-butta", year: 2020)
        await f.edge("butta", .trackOn, "rel", source: .jiosaavn, score: 0.9, level: .album)
        await f.edge("rel", .soundtrackOf, "film", source: .jiosaavn, score: 0.72, level: .film)
        await f.edge("butta", .performedBy, "armaan", role: .singer, source: .jiosaavn, score: 0.9)
        await f.edge("butta", .musicDirectedBy, "thaman", role: .musicDirector, source: .jiosaavn, score: 0.9)
        return f
    }
}

/// An enrichment hook that always fails: the metadata sources are down.
struct SongOutageEnricher: MusicEntityEnriching {
    struct Down: Error {}
    func enrichTrack(_ id: MusicEntityID) async throws -> MusicEnrichmentResult { throw Down() }
}

/// Collects partial reports of one loader run.
final class SongPartials: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [MusicSectionResult] = []
    var results: [MusicSectionResult] { lock.withLock { all } }
    var reporter: MusicSectionReporter { MusicSectionReporter { [self] r in lock.withLock { all.append(r) } } }
}
