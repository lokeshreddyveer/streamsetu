import Foundation
import Testing
@testable import REDDY

/// A small connected universe for the person page tests (all invented rows, no network): the Awaara-era Hindi film world.
struct PersonWorld {
    let store: MusicInMemoryGraph
    var raj: MusicEntityID = .init(kind: .person, token: "0000000000000"), nargis = MusicEntityID(kind: .person, token: "0000000000000")
    var mukesh = MusicEntityID(kind: .person, token: "0000000000000"), lata = MusicEntityID(kind: .person, token: "0000000000000")
    var shailendra = MusicEntityID(kind: .person, token: "0000000000000"), sj = MusicEntityID(kind: .group, token: "0000000000000")
    var shankar = MusicEntityID(kind: .person, token: "0000000000000"), jaikishan = MusicEntityID(kind: .person, token: "0000000000000")
    var kishore = MusicEntityID(kind: .person, token: "0000000000000"), pran = MusicEntityID(kind: .person, token: "0000000000000")
    var ravi = MusicEntityID(kind: .person, token: "0000000000000"), bakshiA = MusicEntityID(kind: .person, token: "0000000000000")
    var bakshiB = MusicEntityID(kind: .person, token: "0000000000000"), nobody = MusicEntityID(kind: .person, token: "0000000000000")
    var awaara = MusicEntityID(kind: .film, token: "0000000000000"), shree420 = MusicEntityID(kind: .film, token: "0000000000000")
    var barsaat = MusicEntityID(kind: .film, token: "0000000000000"), aag = MusicEntityID(kind: .film, token: "0000000000000")
    var gaadi = MusicEntityID(kind: .film, token: "0000000000000"), pranFilm1 = MusicEntityID(kind: .film, token: "0000000000000")
    var pranFilm2 = MusicEntityID(kind: .film, token: "0000000000000"), raviFilm = MusicEntityID(kind: .film, token: "0000000000000")
    var awaaraAlbum = MusicEntityID(kind: .album, token: "0000000000000"), shreeAlbum = MusicEntityID(kind: .album, token: "0000000000000")
    var raviAlbum = MusicEntityID(kind: .album, token: "0000000000000"), soloAlbum = MusicEntityID(kind: .album, token: "0000000000000")
    var awaaraHoon = MusicEntityID(kind: .recording, token: "0000000000000"), gharAaya = MusicEntityID(kind: .recording, token: "0000000000000")
    var joota = MusicEntityID(kind: .recording, token: "0000000000000"), pyar = MusicEntityID(kind: .recording, token: "0000000000000")
    var solo = MusicEntityID(kind: .recording, token: "0000000000000"), duet = MusicEntityID(kind: .recording, token: "0000000000000")
    var kishoreSong = MusicEntityID(kind: .recording, token: "0000000000000")

    init(store: MusicInMemoryGraph) { self.store = store }

    static let wd = MusicProvenance(source: .wikidata, license: .cc0, score: 0.95, evidence: [MusicProvenance.statedToken])
    static let tmdb = MusicProvenance(source: .tmdb, license: .termsRestricted, score: 0.9, evidence: [MusicProvenance.statedToken])
    static let provider = MusicProvenance(source: "jiosaavn", license: .providerCache, score: 0.6)
    static let matcher = MusicProvenance(source: .matcher, license: .derived, score: 0.55, evidence: ["title+year"])

    @discardableResult
    func add(_ s: MusicEntityID, _ p: MusicPredicate, _ o: MusicEntityID, role: MusicRole? = nil, order: Int? = nil, character: String? = nil,
             level: CreditLevel = .song, by: MusicProvenance = PersonWorld.wd) async throws -> MusicEdge {
        var attrs = EdgeAttributes()
        attrs.characterName = character
        let e = MusicEdge(subject: s, predicate: p, object: o, qualifier: role?.rawValue ?? "", attributes: attrs, creditLevel: level, order: order)
        return try await store.addEdge(e, provenance: by)
    }

    static func person(_ store: MusicInMemoryGraph, _ name: String, tmdb: Int? = nil, wikidata: String? = nil, year: Int? = nil, yearEnd: Int? = nil, image: String? = nil,
                       attrs: [String: String] = [:], aliases: [NameAlias] = []) async throws -> MusicEntityID {
        var ids: [ExternalID] = []
        if let tmdb { ids.append(ExternalID(.tmdbPerson, String(tmdb))) }
        if let wikidata { ids.append(ExternalID(.wikidata, wikidata)) }
        if ids.isEmpty { ids.append(ExternalID(.canon, "person|" + name)) }
        return try await store.upsert(MusicEntityDraft(kind: .person, name: name, year: year, yearEnd: yearEnd, imageRef: image, attrs: attrs, externalIDs: ids, aliases: aliases)).id
    }

    static func node(_ store: MusicInMemoryGraph, _ kind: MusicEntityKind, _ name: String, key: String, subkind: String? = nil, year: Int? = nil, lang: String? = nil,
                     attrs: [String: String] = [:]) async throws -> MusicEntityID {
        try await store.upsert(MusicEntityDraft(kind: kind, name: name, subkind: subkind, lang: lang, year: year, attrs: attrs, externalIDs: [ExternalID(.provider, key)])).id
    }

    /// Builds the whole world.
    static func make() async throws -> PersonWorld {
        let store = MusicInMemoryGraph()
        var w = PersonWorld(store: store)
        w.raj = try await person(store, "Raj Kapoor", tmdb: 1001, wikidata: "Q100", year: 1924, yearEnd: 1988, image: "commons:Raj_Kapoor.jpg",
                                 attrs: ["description": "Indian actor, film director and producer"], aliases: [NameAlias("राज कपूर", lang: "hi", script: "Deva", isPrimary: true)])
        w.nargis = try await person(store, "Nargis", tmdb: 1002, year: 1929, yearEnd: 1981, image: "https://image.tmdb.org/t/p/w185/nargis.jpg")
        w.mukesh = try await person(store, "Mukesh", wikidata: "Q200", year: 1923, yearEnd: 1976, image: "commons:Mukesh.jpg")
        w.lata = try await person(store, "Lata Mangeshkar", wikidata: "Q201", year: 1929, yearEnd: 2022)
        w.shailendra = try await person(store, "Shailendra", wikidata: "Q202", year: 1923, yearEnd: 1966)
        w.shankar = try await person(store, "Shankar", wikidata: "Q203")
        w.jaikishan = try await person(store, "Jaikishan", wikidata: "Q204")
        w.sj = try await store.upsert(MusicEntityDraft(kind: .group, name: "Shankar-Jaikishan", subkind: "duo", year: 1949, yearEnd: 1971, externalIDs: [ExternalID(.wikidata, "Q300")])).id
        w.kishore = try await person(store, "Kishore Kumar", tmdb: 1003, wikidata: "Q205")
        w.pran = try await person(store, "Pran", tmdb: 1004)
        w.ravi = try await person(store, "Ravi", wikidata: "Q206")
        w.bakshiA = try await person(store, "Anand Bakshi", wikidata: "Q207", year: 1930, yearEnd: 2002, attrs: ["description": "Indian lyricist"])
        w.bakshiB = try await person(store, "Anand Bakshi", wikidata: "Q208", year: 1960, attrs: ["disambiguation": "Indian cricketer"])
        w.nobody = try await person(store, "Unknown Singer")

        w.awaara = try await node(store, .film, "Awaara", key: "tmdb:1951", year: 1951, lang: "hi")
        w.shree420 = try await node(store, .film, "Shree 420", key: "tmdb:1955", year: 1955, lang: "hi")
        w.barsaat = try await node(store, .film, "Barsaat", key: "tmdb:1949", year: 1949, lang: "hi")
        w.aag = try await node(store, .film, "Aag", key: "tmdb:1948", year: 1948, lang: "hi")
        w.gaadi = try await node(store, .film, "Chalti Ka Naam Gaadi", key: "tmdb:1958", year: 1958, lang: "hi")
        w.pranFilm1 = try await node(store, .film, "Madhumati", key: "tmdb:1958b", year: 1958, lang: "hi")
        w.pranFilm2 = try await node(store, .film, "Zanjeer", key: "tmdb:1973", year: 1973, lang: "hi")
        w.raviFilm = try await node(store, .film, "Chaudhvin Ka Chand", key: "tmdb:1960", year: 1960, lang: "hi")
        w.awaaraAlbum = try await node(store, .album, "Awaara (Original Motion Picture Soundtrack)", key: "jiosaavn:alb1", subkind: "soundtrack", year: 1951, lang: "hi")
        w.shreeAlbum = try await node(store, .album, "Shree 420", key: "jiosaavn:alb2", subkind: "soundtrack", year: 1955, lang: "hi")
        w.raviAlbum = try await node(store, .album, "Chaudhvin Ka Chand", key: "jiosaavn:alb3", subkind: "soundtrack", year: 1960, lang: "hi")
        w.soloAlbum = try await node(store, .album, "Mukesh Sings", key: "jiosaavn:alb4", subkind: "album", year: 1965, lang: "hi")
        w.awaaraHoon = try await node(store, .recording, "Awaara Hoon", key: "jiosaavn:r1", year: 1951, lang: "hi", attrs: ["popularity": "90"])
        w.gharAaya = try await node(store, .recording, "Ghar Aaya Mera Pardesi", key: "jiosaavn:r2", year: 1951, lang: "hi", attrs: ["popularity": "60"])
        w.joota = try await node(store, .recording, "Mera Joota Hai Japani", key: "jiosaavn:r3", year: 1955, lang: "hi", attrs: ["popularity": "80"])
        w.pyar = try await node(store, .recording, "Pyar Hua Ikrar Hua", key: "jiosaavn:r4", year: 1955, lang: "hi", attrs: ["popularity": "70"])
        w.solo = try await node(store, .recording, "Dum Dum Diga Diga", key: "jiosaavn:r5", year: 1965, lang: "hi")
        w.duet = try await node(store, .recording, "Ek Do Teen", key: "jiosaavn:r6", year: 1965, lang: "te")
        w.kishoreSong = try await node(store, .recording, "Ek Ladki Bheegi Bhaagi Si", key: "jiosaavn:r7", year: 1958, lang: "hi")

        // cast and crew of the films (TMDB / Wikidata, verified)
        for (i, f) in [w.awaara, w.shree420, w.barsaat, w.aag].enumerated() {
            try await w.add(f, .hasCast, w.raj, role: .actor, order: i == 3 ? 0 : 0, character: ["Raju", "Raj", "Gopal", "Raj"][i], level: .film, by: tmdb)
            try await w.add(f, .directedBy, w.raj, role: .director, level: .film, by: tmdb)
        }
        for f in [w.awaara, w.shree420, w.barsaat] { try await w.add(f, .hasCast, w.nargis, role: .actor, order: 1, character: "Rita", level: .film, by: tmdb) }
        try await w.add(w.awaara, .producedBy, w.raj, role: .producer, level: .film, by: tmdb)
        for f in [w.awaara, w.shree420, w.barsaat] { try await w.add(f, .musicDirectedBy, w.sj, role: .musicDirector, level: .film) }
        try await w.add(w.shankar, .memberOf, w.sj)
        try await w.add(w.jaikishan, .memberOf, w.sj)
        try await w.add(w.gaadi, .hasCast, w.kishore, role: .actor, order: 0, character: "Manmohan", level: .film, by: tmdb)
        try await w.add(w.pranFilm1, .hasCast, w.pran, role: .actor, order: 3, character: "Ugra Narain", level: .film, by: tmdb)
        try await w.add(w.pranFilm2, .hasCast, w.pran, role: .actor, order: 2, character: "Sher Khan", level: .film, by: tmdb)
        try await w.add(w.raviFilm, .musicDirectedBy, w.ravi, role: .musicDirector, level: .film)

        // soundtracks: stated by Wikidata for Awaara (verified), only inferred by the matcher for Shree 420
        try await w.add(w.awaaraAlbum, .soundtrackOf, w.awaara, level: .film)
        try await w.add(w.shreeAlbum, .soundtrackOf, w.shree420, level: .film, by: matcher)
        try await w.add(w.raviAlbum, .soundtrackOf, w.raviFilm, level: .film, by: matcher)
        try await w.add(w.awaaraAlbum, .musicDirectedBy, w.sj, role: .musicDirector, level: .album)
        try await w.add(w.raviAlbum, .musicDirectedBy, w.ravi, role: .musicDirector, level: .album)

        // recordings
        for (r, a, pos) in [(w.awaaraHoon, w.awaaraAlbum, 1), (w.gharAaya, w.awaaraAlbum, 2), (w.joota, w.shreeAlbum, 1), (w.pyar, w.shreeAlbum, 2), (w.solo, w.soloAlbum, 1), (w.duet, w.soloAlbum, 2)] {
            var attrs = EdgeAttributes(); attrs.position = pos
            _ = try await store.addEdge(MusicEdge(subject: r, predicate: .trackOn, object: a, attributes: attrs), provenance: Self.provider)
        }
        for r in [w.awaaraHoon, w.joota, w.solo, w.duet] { try await w.add(r, .performedBy, w.mukesh, role: .singer, order: 0) }
        for r in [w.gharAaya, w.pyar] { try await w.add(r, .performedBy, w.lata, role: .singer, order: 0) }
        try await w.add(w.pyar, .performedBy, w.mukesh, role: .singer, order: 1)
        try await w.add(w.duet, .performedBy, w.lata, role: .singer, order: 1)
        for r in [w.awaaraHoon, w.gharAaya, w.joota, w.pyar] {
            try await w.add(r, .composedBy, w.sj, role: .composer)
            try await w.add(r, .writtenBy, w.shailendra, role: .lyricist)
        }
        try await w.add(w.duet, .composedBy, w.ravi, role: .composer)
        try await w.add(w.duet, .writtenBy, w.shailendra, role: .lyricist)
        try await w.add(w.awaaraHoon, .featuredIn, w.awaara)
        try await w.add(w.gharAaya, .featuredIn, w.awaara)
        try await w.add(w.kishoreSong, .performedBy, w.kishore, role: .singer, order: 0)
        try await w.add(w.kishoreSong, .featuredIn, w.gaadi)
        try await w.add(w.kishoreSong, .composedBy, w.sj, role: .composer)
        // a local playlist that holds two Mukesh songs
        let playlist = try await store.upsert(MusicEntityDraft(kind: .playlist, name: "Golden Hindi", externalIDs: [ExternalID(.localUUID, "11111111-1111-1111-1111-111111111111")])).id
        try await w.add(playlist, .playlistContains, w.awaaraHoon, by: MusicProvenance(source: .user, license: .user, userOverride: true))
        try await w.add(playlist, .playlistContains, w.joota, by: MusicProvenance(source: .user, license: .user, userOverride: true))
        // the other Anand Bakshi has credits of his own
        try await w.add(w.duet, .writtenBy, w.bakshiA, role: .lyricist)
        return w
    }
}
