import Foundation
import Testing
@testable import REDDY

/// The recorded replies under Tests/REDDYTests/Music/Fixtures (MusicBrainz release group, release and work; Wikidata Q858681 and its cast; the JioSaavn
/// album). `MUSIC_FIXTURES_DIR` overrides the folder (the throwaway package sets it).
enum SoundtrackFixtures {
    static var directory: URL {
        if let env = ProcessInfo.processInfo.environment["MUSIC_FIXTURES_DIR"] { return URL(fileURLWithPath: env, isDirectory: true) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures", isDirectory: true)
    }
    static func json(_ name: String) -> [String: Any] {
        let data = (try? Data(contentsOf: directory.appendingPathComponent(name))) ?? Data()
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }
}

/// The Awaara (1951) graph, built from the fixtures the way the enrichment would write it (MusicBrainz tracklist and credits, Wikidata film, cast and
/// crew, a JioSaavn edition), plus clearly synthetic neighbours (other Raj Kapoor films, other Shankar-Jaikishan soundtracks, the 2010 Awaara) so every
/// shelf has something to choose from. The synthetic entries are named in `synthetic` below; nothing else in the graph is invented.
struct SoundtrackFixtureGraph {
    let graph: MusicInMemoryGraph
    var album = MusicEntityID(kind: .album, token: "0000000000000")
    var release = MusicEntityID(kind: .release, token: "0000000000000")
    var film = MusicEntityID(kind: .film, token: "0000000000000")
    var recordings: [String: MusicEntityID] = [:]
    var people: [String: MusicEntityID] = [:]
    var films: [String: MusicEntityID] = [:]
    var albums: [String: MusicEntityID] = [:]
    var hindi = MusicEntityID(kind: .language, token: "0000000000000")
    var era = MusicEntityID(kind: .era, token: "0000000000000")
    var secondRajKapoor = MusicEntityID(kind: .person, token: "0000000000000")
    var providerTracks: [MusicSoundtrackTrackLite] = []

    static let wikidata = MusicProvenance(source: .wikidata, sourceRef: "Q858681", license: .cc0, evidence: [MusicProvenance.statedToken])
    static let musicbrainz = MusicProvenance(source: .musicbrainz, license: .cc0, evidence: [MusicProvenance.statedToken])
    static let provider = MusicProvenance(source: .jiosaavn, license: .providerCache, score: 0.9)
    static let matcher = MusicProvenance(source: .matcher, license: .derived, score: 0.7, evidence: ["title+year"])
    static let tmdb = MusicProvenance(source: .tmdb, license: .termsRestricted, evidence: [MusicProvenance.statedToken])

    static func build(withSynthetic: Bool = true) async throws -> SoundtrackFixtureGraph {
        var f = SoundtrackFixtureGraph(graph: MusicInMemoryGraph())
        try await f.load(withSynthetic: withSynthetic)
        return f
    }

    // MARK: helpers

    func put(_ d: MusicEntityDraft) async throws -> MusicEntityID { try await graph.upsert(d).id }
    func link(_ s: MusicEntityID, _ p: MusicPredicate, _ o: MusicEntityID, role: MusicRole? = nil, _ prov: MusicProvenance, level: CreditLevel = .unknown, order: Int? = nil,
              attrs: EdgeAttributes = [:]) async throws {
        var e = MusicEdge(subject: s, predicate: p, object: o, qualifier: role?.rawValue ?? "", attributes: attrs, creditLevel: level, order: order)
        _ = try await graph.addEdge(e, provenance: prov)
    }
    func person(_ name: String, ids: [ExternalID], year: Int? = nil, yearEnd: Int? = nil, desc: String? = nil) async throws -> MusicEntityID {
        try await put(MusicEntityDraft(kind: .person, name: name, year: year, yearEnd: yearEnd, attrs: desc.map { ["description": $0] } ?? [:], externalIDs: ids))
    }

    private static func wikidataYear(_ entity: [String: Any], _ prop: String) -> Int? {
        guard let claims = (entity["claims"] as? [String: Any])?[prop] as? [[String: Any]],
              let value = ((claims.first?["mainsnak"] as? [String: Any])?["datavalue"] as? [String: Any])?["value"] as? [String: Any],
              let t = value["time"] as? String, t.count > 5 else { return nil }
        return Int(t.dropFirst().prefix(4))
    }

    // MARK: the fixture graph

    mutating func load(withSynthetic: Bool) async throws {
        // Facets
        hindi = try await put(MusicEntityDraft(kind: .language, name: "Hindi", lang: "hi", attrs: ["iso639": "hin"], externalIDs: [ExternalID(.wikidata, "Q1568")]))
        era = try await put(MusicEntityDraft(kind: .era, name: "1950s", attrs: ["decade": "1950s"]))
        let filmi = try await put(MusicEntityDraft(kind: .genre, name: "filmi", attrs: ["slug": "filmi"]))

        // Wikidata: the film and its people
        let filmJSON = SoundtrackFixtures.json("wikidata_entity_q858681_awaara_film.json")
        let peopleJSON = (SoundtrackFixtures.json("wikidata_people_awaara_cast.json")["entities"] as? [String: [String: Any]]) ?? [:]
        let filmEntity = ((filmJSON["entities"] as? [String: [String: Any]]) ?? [:])["Q858681"] ?? [:]
        func ids(_ prop: String) -> [String] {
            ((filmEntity["claims"] as? [String: Any])?[prop] as? [[String: Any]] ?? []).compactMap {
                (((($0["mainsnak"] as? [String: Any])?["datavalue"] as? [String: Any])?["value"]) as? [String: Any])?["id"] as? String
            }
        }
        func label(_ q: String) -> String { (((peopleJSON[q]?["labels"] as? [String: Any])?["en"]) as? [String: Any])?["value"] as? String ?? q }
        func wikidataPerson(_ q: String, extra: [ExternalID] = []) async throws -> MusicEntityID {
            let e = peopleJSON[q] ?? [:]
            let name = label(q)
            return try await self.person(name, ids: extra + [ExternalID(.wikidata, q)], year: Self.wikidataYear(e, "P569"), yearEnd: Self.wikidataYear(e, "P570"))
        }

        film = try await put(MusicEntityDraft(kind: .film, name: "Awaara", lang: "hi", year: Self.wikidataYear(filmEntity, "P577"),
                                              externalIDs: [ExternalID(.wikidata, "Q858681"), ExternalID(.imdbTitle, "tt0043306"), ExternalID(.tmdbMovie, "39039")]))
        try await link(film, .inLanguage, hindi, Self.wikidata)
        let rajKapoor = try await wikidataPerson("Q55407", extra: [ExternalID(.imdbName, "nm0004292")])
        people["Raj Kapoor"] = rajKapoor
        for (i, q) in ids("P161").enumerated() {
            let p = q == "Q55407" ? rajKapoor : try await wikidataPerson(q)
            people[label(q)] = p
            // Wikidata says who is in the film; TMDB adds the character (the character names are the film's own; the TMDB claim is the test's stand-in).
            var attrs = EdgeAttributes(); attrs.creditOrder = i
            if let c = ["Q55407": "Raj", "Q159169": "Rita", "Q560197": "Judge Raghunath"][q] { attrs.characterName = c }
            _ = try await graph.addEdge(MusicEdge(subject: film, predicate: .hasCast, object: p, role: .actor, attributes: attrs, creditLevel: .film, order: i), provenance: Self.wikidata)
            _ = try await graph.addEdge(MusicEdge(subject: film, predicate: .hasCast, object: p, role: .actor, attributes: attrs, creditLevel: .film, order: i), provenance: Self.tmdb)
        }
        try await link(film, .directedBy, rajKapoor, role: .director, Self.wikidata, level: .film)
        try await link(film, .producedBy, rajKapoor, role: .producer, Self.wikidata, level: .film)
        let sjQ = ids("P86").first ?? "Q3631402"
        let sj = try await put(MusicEntityDraft(kind: .group, name: "Shankar-Jaikishan", subkind: "duo", year: 1949,
                                                externalIDs: [ExternalID(.mbid, "44795277-c4ee-4a78-ae1e-d27fa62995f0"), ExternalID(.wikidata, sjQ)]))
        people["Shankar-Jaikishan"] = sj
        try await link(film, .composedBy, sj, role: .composer, Self.wikidata, level: .film)

        // MusicBrainz: the release group, its release and tracklist, the work credits
        let rg = SoundtrackFixtures.json("mb_release_group_awaara_1951.json")
        let rel = SoundtrackFixtures.json("mb_release_awaara_1951.json")
        let rgID = rg["id"] as? String ?? "81c5af83-1b9f-47cf-8ca9-2fcbc51b9448"
        album = try await put(MusicEntityDraft(kind: .album, name: "Awaara", subkind: MusicAlbumSubkind.soundtrack.rawValue, lang: "hi", year: 1951,
                                               externalIDs: [ExternalID(.mbReleaseGroup, rgID)]))
        try await link(album, .soundtrackOf, film, Self.musicbrainz)
        try await link(album, .inLanguage, hindi, Self.musicbrainz)
        try await link(album, .ofEra, era, Self.musicbrainz)
        try await link(album, .hasGenre, filmi, Self.musicbrainz)
        try await link(album, .musicDirectedBy, sj, role: .musicDirector, Self.musicbrainz, level: .album)

        let shailendra = try await person("Shailendra", ids: [ExternalID(.mbid, "1524db6d-9778-4d6c-985a-3b35558d2f7e")], year: 1923, yearEnd: 1966)
        people["Shailendra"] = shailendra
        let tracks = ((rel["media"] as? [[String: Any]])?.first?["tracks"] as? [[String: Any]]) ?? []
        for t in tracks {
            let title = (t["title"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let rec = t["recording"] as? [String: Any] ?? [:]
            let rid = try await put(MusicEntityDraft(kind: .recording, name: title, year: 1951, durationMs: t["length"] as? Int, externalIDs: [ExternalID(.mbid, rec["id"] as? String ?? title)]))
            recordings[title] = rid
            var attrs = EdgeAttributes(); attrs.disc = 1; attrs.position = t["position"] as? Int
            try await link(rid, .trackOn, album, Self.musicbrainz, order: t["position"] as? Int, attrs: attrs)
            for (i, c) in (t["artist-credit"] as? [[String: Any]] ?? []).enumerated() {
                guard let a = c["artist"] as? [String: Any], let aid = a["id"] as? String, let name = a["name"] as? String else { continue }
                let pid = try await person(name, ids: [ExternalID(.mbid, aid)], desc: (a["disambiguation"] as? String).flatMap { $0.isEmpty ? nil : $0 })
                people[name] = pid
                try await link(rid, .performedBy, pid, role: .singer, Self.musicbrainz, level: .song, order: i)
            }
        }
        if let hoon = recordings["Awaara Hoon"] { try await link(hoon, .writtenBy, shailendra, role: .lyricist, Self.musicbrainz, level: .song) }

        // The JioSaavn edition: the provider's own album, linked to the album concept
        let jio = SoundtrackFixtures.json("jiosaavn-album-awaara-1951.json")
        release = try await put(MusicEntityDraft(kind: .release, name: "Awaara", subkind: MusicAlbumSubkind.soundtrack.rawValue, year: 1951,
                                                 imageRef: jio["image"] as? String, externalIDs: [ExternalID(.provider, "jiosaavn:" + (jio["id"] as? String ?? "1064999"))], provisional: true))
        try await link(release, .editionOf, album, Self.provider)
        for (i, item) in ((jio["list"] as? [[String: Any]]) ?? []).enumerated() {
            let id = item["id"] as? String ?? "x\(i)"
            providerTracks.append(MusicSoundtrackTrackLite(uid: "jiosaavn:" + id, title: item["title"] as? String ?? "", durationMs: Int64((Int(item["duration"] as? String ?? "") ?? 0) * 1000),
                                                           artistLine: ((item["subtitle"] as? String) ?? "").components(separatedBy: " - ").first ?? "", disc: 1, number: i + 1))
        }

        // A second person with the same name (a different Raj Kapoor), credited as a singer on one song: the two stay separate.
        secondRajKapoor = try await person("Raj Kapoor", ids: [ExternalID(.wikidata, "Q-SYNTH-RK2")], year: 1960, desc: "playback singer")
        if let r = recordings["Naiya Meri Manjhdhar"] { try await link(r, .performedBy, secondRajKapoor, role: .singer, Self.provider, level: .song) }

        guard withSynthetic else { return }
        try await loadSynthetic(sj: sj, rajKapoor: rajKapoor, hindi: hindi, era: era, filmi: filmi)
    }

    /// Synthetic neighbours. These are test data, not facts: other films with Raj Kapoor or Nargis, other soundtracks by Shankar-Jaikishan or Naushad,
    /// a Telugu film also called Awaara (2010), a film with no soundtrack album, an indie album and a compilation.
    static let synthetic = ["Shree 420", "Barsaat", "Sangam", "Mother India", "Mughal-e-Azam", "Jagte Raho", "Awaara (2010)", "Sholay", "Devadasu",
                            "Mukesh Golden Hits", "Quiet Hours"]

    mutating func loadSynthetic(sj: MusicEntityID, rajKapoor: MusicEntityID, hindi: MusicEntityID, era: MusicEntityID, filmi: MusicEntityID) async throws {
        let nargis = people["Nargis"]!, prithviraj = people["Prithviraj Kapoor"]!, mukesh = people["Mukesh"]!, lata = people["Lata Mangeshkar"]!
        let naushad = try await person("Naushad", ids: [ExternalID(.wikidata, "Q-SYNTH-NAUSHAD")], year: 1919, yearEnd: 2006)
        let rd = try await person("R. D. Burman", ids: [ExternalID(.wikidata, "Q-SYNTH-RDB")], year: 1939, yearEnd: 1994)
        let sunil = try await person("Sunil Dutt", ids: [ExternalID(.wikidata, "Q-SYNTH-SUNIL")], year: 1929, yearEnd: 2005)
        people["Naushad"] = naushad

        func makeFilm(_ name: String, _ year: Int, lang: String = "hi", cast: [MusicEntityID], q: String) async throws -> MusicEntityID {
            let f = try await put(MusicEntityDraft(kind: .film, name: name, lang: lang, year: year, externalIDs: [ExternalID(.wikidata, q)]))
            films[name] = f
            if lang == "hi" { try await link(f, .inLanguage, hindi, Self.wikidata) }
            for (i, p) in cast.enumerated() {
                try await link(f, .hasCast, p, role: .actor, Self.wikidata, level: .film, order: i)
            }
            return f
        }
        func makeAlbum(_ name: String, _ year: Int, film: MusicEntityID?, director: MusicEntityID, singers: [MusicEntityID], q: String, inferred: Bool = false, hindiAlbum: Bool = true) async throws -> MusicEntityID {
            let a = try await put(MusicEntityDraft(kind: .album, name: name, subkind: MusicAlbumSubkind.soundtrack.rawValue, lang: "hi", year: year, externalIDs: [ExternalID(.mbReleaseGroup, q)]))
            albums[name] = a
            if let film { try await link(a, .soundtrackOf, film, inferred ? Self.matcher : Self.musicbrainz) }
            try await link(a, .musicDirectedBy, director, role: .musicDirector, Self.musicbrainz, level: .album)
            for (i, s) in singers.enumerated() { try await link(a, .performedBy, s, role: .singer, Self.musicbrainz, level: .album, order: i) }
            if hindiAlbum { try await link(a, .inLanguage, hindi, Self.musicbrainz) }
            return a
        }

        let shree = try await makeFilm("Shree 420", 1955, cast: [rajKapoor, nargis], q: "Q-SYNTH-SHREE420")
        let barsaat = try await makeFilm("Barsaat", 1949, cast: [rajKapoor, nargis], q: "Q-SYNTH-BARSAAT")
        _ = try await makeFilm("Jagte Raho", 1956, cast: [rajKapoor], q: "Q-SYNTH-JAGTE")   // no soundtrack album in the graph
        let mother = try await makeFilm("Mother India", 1957, cast: [nargis, sunil], q: "Q-SYNTH-MOTHER")
        let mughal = try await makeFilm("Mughal-e-Azam", 1960, cast: [prithviraj], q: "Q-SYNTH-MUGHAL")
        let sholay = try await makeFilm("Sholay", 1975, cast: [], q: "Q-SYNTH-SHOLAY")
        let devadasu = try await makeFilm("Devadasu", 1953, lang: "te", cast: [], q: "Q-SYNTH-DEVADASU")
        let awaara2010 = try await makeFilm("Awaara (2010)", 2010, lang: "te", cast: [], q: "Q-SYNTH-AWAARA2010")
        films["Awaara (2010)"] = awaara2010

        let shreeAlbum = try await makeAlbum("Shree 420", 1955, film: shree, director: sj, singers: [mukesh, lata], q: "SYNTH-RG-SHREE")
        _ = try await makeAlbum("Barsaat", 1949, film: barsaat, director: sj, singers: [lata], q: "SYNTH-RG-BARSAAT")
        _ = try await makeAlbum("Mother India", 1957, film: mother, director: naushad, singers: [lata], q: "SYNTH-RG-MOTHER")
        _ = try await makeAlbum("Mughal-e-Azam", 1960, film: mughal, director: naushad, singers: [lata], q: "SYNTH-RG-MUGHAL")
        _ = try await makeAlbum("Sholay", 1975, film: sholay, director: rd, singers: [lata], q: "SYNTH-RG-SHOLAY")
        _ = try await makeAlbum("Devadasu", 1953, film: devadasu, director: naushad, singers: [], q: "SYNTH-RG-DEVADASU", hindiAlbum: false)
        let yuvan = try await person("Yuvan Shankar Raja", ids: [ExternalID(.mbid, "94439fdd-273b-4255-9608-04cb1969fcfa")], year: 1979)
        let a2010 = try await makeAlbum("Awaara (2010)", 2010, film: awaara2010, director: yuvan, singers: [], q: "93b12826-f581-47a5-8086-0cc88e61cbbe", hindiAlbum: false)
        _ = a2010
        let sangam = try await put(MusicEntityDraft(kind: .album, name: "Sangam", subkind: MusicAlbumSubkind.soundtrack.rawValue, lang: "hi", year: 1964, externalIDs: [ExternalID(.mbReleaseGroup, "SYNTH-RG-SANGAM")]))
        albums["Sangam"] = sangam
        try await link(sangam, .musicDirectedBy, sj, role: .musicDirector, Self.musicbrainz, level: .album)
        try await link(sangam, .performedBy, lata, role: .singer, Self.musicbrainz, level: .album)
        try await link(sangam, .performedBy, mukesh, role: .singer, Self.musicbrainz, level: .album)
        try await link(sangam, .inLanguage, hindi, Self.musicbrainz)

        // Songs: Mera Joota Hai Japani (Shree 420, composed by SJ, sung by Mukesh), two-singer song, a karaoke version of Awaara Hoon
        func song(_ name: String, year: Int, singers: [MusicEntityID], on album: MusicEntityID?, composer: MusicEntityID? = nil, popularity: Int = 0, version: MusicVersionKind? = nil) async throws -> MusicEntityID {
            var attrs: [String: String] = popularity > 0 ? ["popularity": String(popularity)] : [:]
            if let version { attrs["versionKind"] = version.rawValue }
            let r = try await put(MusicEntityDraft(kind: .recording, name: name, year: year, attrs: attrs, externalIDs: [ExternalID(.mbid, "SYNTH-REC-" + name)]))
            recordings[name] = r
            for (i, s) in singers.enumerated() { try await link(r, .performedBy, s, role: .singer, Self.musicbrainz, level: .song, order: i) }
            if let album { try await link(r, .trackOn, album, Self.musicbrainz) }
            if let composer { try await link(r, .composedBy, composer, role: .composer, Self.musicbrainz, level: .song) }
            return r
        }
        _ = try await song("Mera Joota Hai Japani", year: 1955, singers: [mukesh], on: shreeAlbum, composer: sj, popularity: 95)
        _ = try await song("Pyar Hua Ikrar Hua", year: 1955, singers: [lata, mukesh], on: shreeAlbum, composer: sj, popularity: 90)
        _ = try await song("Awaara Hoon (Karaoke)", year: 2019, singers: [mukesh], on: nil, popularity: 99, version: .karaoke)
        let goldenHits = try await put(MusicEntityDraft(kind: .album, name: "Mukesh Golden Hits", subkind: MusicAlbumSubkind.compilation.rawValue, year: 1976, externalIDs: [ExternalID(.mbReleaseGroup, "SYNTH-RG-MUKESH")]))
        albums["Mukesh Golden Hits"] = goldenHits
        try await link(goldenHits, .performedBy, mukesh, role: .performer, Self.musicbrainz, level: .album)
        _ = try await song("Kabhi Kabhie Mere Dil Mein", year: 1976, singers: [mukesh], on: goldenHits, popularity: 80)

        // An indie album with no film, no external ids beyond the provider's
        let indie = try await put(MusicEntityDraft(kind: .release, name: "Quiet Hours", subkind: MusicAlbumSubkind.album.rawValue, year: 2021, externalIDs: [ExternalID(.provider, "jiosaavn:indie1")], provisional: true))
        albums["Quiet Hours"] = indie
        let artist = try await put(MusicEntityDraft(kind: .person, name: "Mira Sol", externalIDs: [ExternalID(.provider, "jiosaavn:artist-mira")], provisional: true))
        people["Mira Sol"] = artist
        try await link(indie, .performedBy, artist, role: .performer, Self.provider, level: .album)
        let indieTrack = try await put(MusicEntityDraft(kind: .recording, name: "Lantern", externalIDs: [ExternalID(.provider, "jiosaavn:indie-track-1")], provisional: true))
        recordings["Lantern"] = indieTrack
        try await link(indieTrack, .trackOn, indie, Self.provider, order: 1)
        try await link(indieTrack, .performedBy, artist, role: .performer, Self.provider, level: .song)
    }
}
