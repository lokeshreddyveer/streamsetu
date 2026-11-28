import Foundation
import Testing
@testable import REDDY

/// "ANIMAL - TELUGU" (2023 film Animal), built from recorded replies under Tests/REDDYTests/Music/Fixtures:
/// Wikidata Q115947372 (film, cast, director, composers), the people it names, the MusicBrainz release group "ANIMAL" with its Hindi tracklist, and the
/// JioSaavn Telugu album (6 songs, credited to "Various Artists") and its Deluxe edition (9 songs). The neighbours named in `synthetic` are test data.
enum AnimalFixtures {
    static let synthetic = ["Kabir Singh", "Arjun Reddy", "Brahmastra", "Sanju", "Kabir Singh (soundtrack)", "Arjun Reddy (soundtrack)", "Brahmastra (soundtrack)", "Sanju (soundtrack)", "Kaise Hua"]
    static let wikidata = MusicProvenance(source: .wikidata, sourceRef: "Q115947372", license: .cc0, evidence: [MusicProvenance.statedToken])

    static func entities(_ file: String) -> [String: [String: Any]] { (SoundtrackFixtures.json(file)["entities"] as? [String: [String: Any]]) ?? [:] }

    /// The graph plus the provider tracklist of the standard Telugu album (`providerTracks` of the graph holds the Deluxe edition's nine).
    static func build() async throws -> (graph: SoundtrackFixtureGraph, standard: [MusicSoundtrackTrackLite]) {
        var standard: [MusicSoundtrackTrackLite] = []
        var f = SoundtrackFixtureGraph(graph: MusicInMemoryGraph())
        let mb = SoundtrackFixtureGraph.musicbrainz, provider = SoundtrackFixtureGraph.provider, matcher = SoundtrackFixtureGraph.matcher
        let hindi = try await f.put(MusicEntityDraft(kind: .language, name: "Hindi", lang: "hi", attrs: ["iso639": "hin"], externalIDs: [ExternalID(.wikidata, "Q1568")]))
        let telugu = try await f.put(MusicEntityDraft(kind: .language, name: "Telugu", lang: "te", attrs: ["iso639": "tel"], externalIDs: [ExternalID(.wikidata, "Q8097")]))
        f.hindi = hindi
        f.era = try await f.put(MusicEntityDraft(kind: .era, name: "2020s", attrs: ["decade": "2020s"]))

        // Wikidata: the film, its cast, director and composers
        let filmEntity = entities("wikidata_entity_q115947372_animal_film.json")["Q115947372"] ?? [:]
        let people = entities("wikidata_people_animal_cast.json")
        func claimIDs(_ p: String) -> [String] {
            ((filmEntity["claims"] as? [String: Any])?[p] as? [[String: Any]] ?? []).compactMap {
                ((((($0["mainsnak"] as? [String: Any])?["datavalue"] as? [String: Any])?["value"]) as? [String: Any])?["id"]) as? String
            }
        }
        func label(_ q: String) -> String {
            let l = people[q]?["labels"] as? [String: Any] ?? [:]
            return ((l["en"] as? [String: Any]) ?? (l["mul"] as? [String: Any]))?["value"] as? String ?? q
        }
        func wd(_ q: String) async throws -> MusicEntityID {
            let id = try await f.person(label(q), ids: [ExternalID(.wikidata, q)], desc: (people[q]?["descriptions"] as? [String: Any]).flatMap { ($0["en"] as? [String: Any])?["value"] as? String })
            f.people[label(q)] = id
            return id
        }
        f.film = try await f.put(MusicEntityDraft(kind: .film, name: "Animal", lang: "hi", year: 2023,
                                                  externalIDs: [ExternalID(.wikidata, "Q115947372"), ExternalID(.imdbTitle, "tt13751694"), ExternalID(.tmdbMovie, "781732")]))
        f.films["Animal"] = f.film
        try await f.link(f.film, .inLanguage, hindi, wikidata)
        for (i, q) in claimIDs("P161").enumerated() {
            let p = try await wd(q)
            var a = EdgeAttributes(); a.creditOrder = i
            try await f.link(f.film, .hasCast, p, role: .actor, wikidata, level: .film, order: i, attrs: a)
        }
        let director = try await wd(claimIDs("P57")[0])
        try await f.link(f.film, .directedBy, director, role: .director, wikidata, level: .film)
        var composers: [MusicEntityID] = []
        for q in claimIDs("P86") { let c = try await wd(q); composers.append(c); try await f.link(f.film, .composedBy, c, role: .composer, wikidata, level: .film) }

        // MusicBrainz: the release group and the Hindi release
        let rg = SoundtrackFixtures.json("mb_release_group_animal_2023.json")
        let rel = SoundtrackFixtures.json("mb_release_animal_2023.json")
        let hindiAlbum = try await f.put(MusicEntityDraft(kind: .album, name: "ANIMAL", subkind: MusicAlbumSubkind.soundtrack.rawValue, lang: "hi", year: 2023,
                                                          externalIDs: [ExternalID(.mbReleaseGroup, rg["id"] as? String ?? "157f76af-a5d2-4ea0-8bfd-c65758066531")]))
        f.albums["ANIMAL"] = hindiAlbum
        try await f.link(hindiAlbum, .soundtrackOf, f.film, mb)
        try await f.link(hindiAlbum, .inLanguage, hindi, mb)
        for c in composers { try await f.link(hindiAlbum, .musicDirectedBy, c, role: .musicDirector, mb, level: .album) }
        for t in ((rel["media"] as? [[String: Any]])?.first?["tracks"] as? [[String: Any]]) ?? [] {
            let title = t["title"] as? String ?? ""
            let rec = t["recording"] as? [String: Any] ?? [:]
            let rid = try await f.put(MusicEntityDraft(kind: .recording, name: title, year: 2023, externalIDs: [ExternalID(.mbid, rec["id"] as? String ?? title)]))
            f.recordings[title] = rid
            try await f.link(rid, .trackOn, hindiAlbum, mb, order: t["position"] as? Int)
            for (i, c) in (t["artist-credit"] as? [[String: Any]] ?? []).enumerated() {
                guard let a = c["artist"] as? [String: Any], let aid = a["id"] as? String, let name = a["name"] as? String else { continue }
                let pid = try await f.person(name, ids: [ExternalID(.mbid, aid)])
                f.people[name] = f.people[name] ?? pid
                try await f.link(rid, .performedBy, pid, role: .singer, mb, level: .song, order: i)
            }
        }

        // JioSaavn: the Telugu album and its Deluxe edition, credited to "Various Artists" at the album level
        let va = try await f.put(MusicEntityDraft(kind: .group, name: "Various Artists", externalIDs: [ExternalID(.provider, "jiosaavn:artist-various")], provisional: true))
        f.people["Various Artists"] = va
        let teluguAlbum = try await f.put(MusicEntityDraft(kind: .album, name: "ANIMAL - TELUGU", subkind: MusicAlbumSubkind.soundtrack.rawValue, lang: "te", year: 2023,
                                                           externalIDs: [ExternalID(.provider, "jiosaavn:49986025")], provisional: true))
        f.albums["ANIMAL - TELUGU"] = teluguAlbum; f.album = teluguAlbum
        try await f.link(teluguAlbum, .soundtrackOf, f.film, matcher)
        try await f.link(teluguAlbum, .inLanguage, telugu, provider)
        try await f.link(teluguAlbum, .performedBy, va, role: .performer, provider, level: .album)
        for c in composers { try await f.link(teluguAlbum, .musicDirectedBy, c, role: .musicDirector, matcher, level: .album) }
        let deluxe = try await f.put(MusicEntityDraft(kind: .release, name: "ANIMAL (Telugu) (Deluxe Edition Album)", subkind: MusicAlbumSubkind.soundtrack.rawValue, lang: "te", year: 2024,
                                                      externalIDs: [ExternalID(.provider, "jiosaavn:51348041")], provisional: true))
        f.release = deluxe
        try await f.link(deluxe, .editionOf, teluguAlbum, provider)
        for (name, albumID, file) in [("standard", teluguAlbum, "jiosaavn-album-animal-telugu-49986025.json"), ("deluxe", deluxe, "jiosaavn-album-animal-telugu-deluxe-51348041.json")] {
            let jio = SoundtrackFixtures.json(file)
            for (i, item) in ((jio["list"] as? [[String: Any]]) ?? []).enumerated() {
                let id = item["id"] as? String ?? "\(name)\(i)"
                let title = item["title"] as? String ?? ""
                let uid = "jiosaavn:" + id
                let rid = try await f.put(MusicEntityDraft(kind: .recording, name: title, year: 2023, externalIDs: [ExternalID(.provider, uid)], provisional: true))
                f.recordings[name == "standard" ? title : "deluxe:" + title] = rid
                try await f.link(rid, .trackOn, albumID, provider, order: i + 1)
                let line = ((item["subtitle"] as? String) ?? "").components(separatedBy: " - ").first ?? ""
                for (k, s) in line.components(separatedBy: ", ").filter({ !$0.isEmpty }).enumerated() {
                    let pid = try await f.person(s, ids: [ExternalID(.provider, "jiosaavn:artist-" + s)])
                    f.people[s] = f.people[s] ?? pid
                    try await f.link(rid, .performedBy, pid, role: .singer, provider, level: .song, order: k)
                }
                if let comp = ((item["more_info"] as? [String: Any])?["music"] as? String), !comp.isEmpty {
                    let cid: MusicEntityID
                    if let known = f.people[comp] { cid = known } else { cid = try await f.person(comp, ids: [ExternalID(.provider, "jiosaavn:artist-" + comp)]) }
                    f.people[comp] = cid
                    try await f.link(rid, .composedBy, cid, role: .composer, provider, level: .song)
                }
                f.providerTracks.append(MusicSoundtrackTrackLite(uid: uid, title: title, durationMs: Int64((Int(item["duration"] as? String ?? "") ?? 0) * 1000),
                                                                 artistLine: line, disc: 1, number: i + 1))
            }
            if name == "standard" { standard = f.providerTracks; f.providerTracks = [] }
        }

        // Synthetic neighbours (test data): other films of the director and the lead, with soundtracks, in Telugu and Hindi
        let ranbir = f.people["Ranbir Kapoor"]!, vishal = f.people["Vishal Mishra"]!, pritam = f.people["Pritam Chakraborty"]!
        func neighbour(_ name: String, _ year: Int, lang: String, langID: MusicEntityID, cast: [MusicEntityID], director d: MusicEntityID?, composer: MusicEntityID, singers: [MusicEntityID], q: String) async throws {
            let film = try await f.put(MusicEntityDraft(kind: .film, name: name, lang: lang, year: year, externalIDs: [ExternalID(.wikidata, "Q-SYNTH-" + q)]))
            f.films[name] = film
            try await f.link(film, .inLanguage, langID, wikidata)
            for (i, c) in cast.enumerated() { try await f.link(film, .hasCast, c, role: .actor, wikidata, level: .film, order: i) }
            if let d { try await f.link(film, .directedBy, d, role: .director, wikidata, level: .film) }
            try await f.link(film, .composedBy, composer, role: .composer, wikidata, level: .film)
            let a = try await f.put(MusicEntityDraft(kind: .album, name: name, subkind: MusicAlbumSubkind.soundtrack.rawValue, lang: lang, year: year, externalIDs: [ExternalID(.mbReleaseGroup, "SYNTH-RG-" + q)]))
            f.albums[name] = a
            try await f.link(a, .soundtrackOf, film, mb)
            try await f.link(a, .inLanguage, langID, mb)
            try await f.link(a, .musicDirectedBy, composer, role: .musicDirector, mb, level: .album)
            let r = try await f.put(MusicEntityDraft(kind: .recording, name: name + " (title song)", year: year, externalIDs: [ExternalID(.mbid, "SYNTH-REC-" + q)]))
            f.recordings[name + " (title song)"] = r
            try await f.link(r, .trackOn, a, mb, order: 1)
            for (i, s) in singers.enumerated() { try await f.link(r, .performedBy, s, role: .singer, mb, level: .song, order: i) }
            try await f.link(r, .composedBy, composer, role: .composer, mb, level: .song)
        }
        try await neighbour("Kabir Singh", 2019, lang: "hi", langID: hindi, cast: [], director: director, composer: vishal, singers: [vishal], q: "KABIR")
        try await neighbour("Arjun Reddy", 2017, lang: "te", langID: telugu, cast: [], director: director, composer: pritam, singers: [], q: "ARJUN")
        try await neighbour("Brahmastra", 2022, lang: "hi", langID: hindi, cast: [ranbir], director: nil, composer: pritam, singers: [vishal], q: "BRAHMASTRA")
        try await neighbour("Sanju", 2018, lang: "hi", langID: hindi, cast: [ranbir], director: nil, composer: pritam, singers: [], q: "SANJU")
        return (f, standard)
    }
}

