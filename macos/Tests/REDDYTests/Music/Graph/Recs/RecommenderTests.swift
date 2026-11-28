import Foundation
import Testing
@testable import REDDY

/// The Awaara (1951) neighbourhood: Shankar-Jaikishan, Shailendra, Mukesh, Raj Kapoor, with a sibling film, a Tamil edition, a 2010 remake and noise.
struct AwaaraGraph {
    let w = RecWorld()
    var sj = MusicEntityID(kind: .person, token: "0000000000000"), shailendra = MusicEntityID(kind: .person, token: "0000000000000")
    var mukesh = MusicEntityID(kind: .person, token: "0000000000000"), lata = MusicEntityID(kind: .person, token: "0000000000000")
    var rafi = MusicEntityID(kind: .person, token: "0000000000000"), rk = MusicEntityID(kind: .person, token: "0000000000000")
    var nargis = MusicEntityID(kind: .person, token: "0000000000000"), naushad = MusicEntityID(kind: .person, token: "0000000000000")
    var hindi = MusicEntityID(kind: .language, token: "0000000000000")
    var awaara = MusicEntityID(kind: .film, token: "0000000000000"), shree = MusicEntityID(kind: .film, token: "0000000000000")
    var barsaat = MusicEntityID(kind: .film, token: "0000000000000"), awaara2010 = MusicEntityID(kind: .film, token: "0000000000000")
    var awaaraOST = MusicEntityID(kind: .album, token: "0000000000000"), awaaraTamil = MusicEntityID(kind: .album, token: "0000000000000")
    var shreeOST = MusicEntityID(kind: .album, token: "0000000000000"), barsaatOST = MusicEntityID(kind: .album, token: "0000000000000")
    var ost2010 = MusicEntityID(kind: .album, token: "0000000000000"), jagteOST = MusicEntityID(kind: .album, token: "0000000000000"), jagte = MusicEntityID(kind: .film, token: "0000000000000")
    var awaaraHoon = MusicEntityID(kind: .recording, token: "0000000000000"), gharAaya = MusicEntityID(kind: .recording, token: "0000000000000")
    var dumBhar = MusicEntityID(kind: .recording, token: "0000000000000"), meraJoota = MusicEntityID(kind: .recording, token: "0000000000000")
    var pyarHua = MusicEntityID(kind: .recording, token: "0000000000000"), aeMere = MusicEntityID(kind: .recording, token: "0000000000000")
    var yehZindagi = MusicEntityID(kind: .recording, token: "0000000000000"), remix = MusicEntityID(kind: .recording, token: "0000000000000")
    var modern = MusicEntityID(kind: .recording, token: "0000000000000"), lonely = MusicEntityID(kind: .recording, token: "0000000000000")

    static func make() async -> AwaaraGraph {
        var a = AwaaraGraph()
        let w = a.w
        a.hindi = await w.ent(.language, "Hindi", uid: "lang:hi")
        a.sj = await w.ent(.person, "Shankar-Jaikishan", year: 1922)
        a.shailendra = await w.ent(.person, "Shailendra", year: 1923)
        a.mukesh = await w.ent(.person, "Mukesh", year: 1923)
        a.lata = await w.ent(.person, "Lata Mangeshkar", year: 1929)
        a.rafi = await w.ent(.person, "Mohammed Rafi", year: 1924)
        a.rk = await w.ent(.person, "Raj Kapoor", year: 1924)
        a.nargis = await w.ent(.person, "Nargis", year: 1929)
        a.naushad = await w.ent(.person, "Naushad", year: 1919)
        let shakeel = await w.ent(.person, "Shakeel Badayuni", year: 1916), talat = await w.ent(.person, "Talat Mahmood", year: 1924)
        let anu = await w.ent(.person, "Anu Malik", year: 1960)
        let premnath = await w.ent(.person, "Premnath", year: 1926)

        a.awaara = await w.ent(.film, "Awaara", lang: "hi", year: 1951)
        a.shree = await w.ent(.film, "Shree 420", lang: "hi", year: 1955)
        a.barsaat = await w.ent(.film, "Barsaat", lang: "hi", year: 1949)
        a.awaara2010 = await w.ent(.film, "Awaara", lang: "hi", year: 2010)
        for (f, cast, director) in [(a.awaara, [a.rk, a.nargis], a.rk), (a.shree, [a.rk, a.nargis], a.rk), (a.barsaat, [premnath], a.rk), (a.awaara2010, [anu], anu)] as [(MusicEntityID, [MusicEntityID], MusicEntityID)] {
            for (i, p) in cast.enumerated() { await w.link(f, .hasCast, p, role: .actor, order: i, level: .film) }
            await w.link(f, .directedBy, director, role: .director, level: .film)
            await w.link(f, .inLanguage, a.hindi)
        }
        for f in [a.awaara, a.shree, a.barsaat] { await w.link(f, .musicDirectedBy, a.sj, role: .musicDirector, level: .film) }

        a.awaaraOST = await w.ent(.album, "Awaara (Original Motion Picture Soundtrack)", lang: "hi", year: 1951, img: "art:awaara")
        a.awaaraTamil = await w.ent(.album, "Awaara (Original Motion Picture Soundtrack)", lang: "ta", year: 1951, img: "art:awaara-ta")
        a.shreeOST = await w.ent(.album, "Shree 420 (Original Motion Picture Soundtrack)", lang: "hi", year: 1955)
        a.barsaatOST = await w.ent(.album, "Barsaat (Original Motion Picture Soundtrack)", lang: "hi", year: 1949)
        a.ost2010 = await w.ent(.album, "Awaara 2010 Songs", lang: "hi", year: 2010)
        for (alb, film) in [(a.awaaraOST, a.awaara), (a.awaaraTamil, a.awaara), (a.shreeOST, a.shree), (a.barsaatOST, a.barsaat), (a.ost2010, a.awaara2010)] {
            await w.link(alb, .soundtrackOf, film)
            await w.link(alb, .inLanguage, a.hindi)
        }
        for alb in [a.awaaraOST, a.awaaraTamil, a.shreeOST, a.barsaatOST] { await w.link(alb, .musicDirectedBy, a.sj, role: .musicDirector, level: .album) }

        a.jagte = await w.ent(.film, "Jagte Raho", lang: "hi", year: 1956)
        for (i, p) in [a.rk, a.nargis].enumerated() { await w.link(a.jagte, .hasCast, p, role: .actor, order: i, level: .film) }
        a.jagteOST = await w.ent(.album, "Jagte Raho (Original Motion Picture Soundtrack)", lang: "hi", year: 1956)
        await w.link(a.jagteOST, .soundtrackOf, a.jagte)
        await w.link(a.jagteOST, .musicDirectedBy, a.sj, role: .musicDirector, level: .album)
        await w.link(a.jagteOST, .inLanguage, a.hindi)
        a.awaaraHoon = await w.song("Awaara Hoon", year: 1951, lang: "hi", album: a.awaaraOST, order: 1, film: a.awaara, md: a.sj, lyricist: a.shailendra, singers: [a.mukesh])
        a.gharAaya = await w.song("Ghar Aaya Mera Pardesi", year: 1951, lang: "hi", album: a.awaaraOST, order: 2, film: a.awaara, md: a.sj, lyricist: a.shailendra, singers: [a.lata])
        a.dumBhar = await w.song("Dum Bhar Udhar Munh Phere", year: 1951, lang: "hi", album: a.awaaraOST, order: 3, film: a.awaara, md: a.sj, lyricist: a.shailendra, singers: [a.mukesh, a.lata])
        a.meraJoota = await w.song("Mera Joota Hai Japani", year: 1955, lang: "hi", album: a.shreeOST, order: 1, film: a.shree, md: a.sj, lyricist: a.shailendra, singers: [a.mukesh])
        a.pyarHua = await w.song("Pyar Hua Ikrar Hua", year: 1955, lang: "hi", album: a.shreeOST, order: 2, film: a.shree, md: a.sj, lyricist: a.shailendra, singers: [a.lata])
        a.aeMere = await w.song("Ae Mere Dil Kahin Aur Chal", year: 1949, lang: "hi", md: a.sj, lyricist: await w.ent(.person, "Hasrat Jaipuri"), singers: [a.rafi])
        a.yehZindagi = await w.song("Yeh Zindagi Ke Mele", year: 1952, lang: "hi", md: a.naushad, lyricist: shakeel, singers: [talat])
        a.remix = await w.song("Awaara Hoon (Remix 2022)", year: 2022, lang: "hi", md: a.sj, singers: [a.mukesh], attrs: ["versionKind": "remix"])
        await w.link(a.remix, .alternateOf, a.awaaraHoon, attrs: { var x = EdgeAttributes(); x.versionKind = .remix; return x }())
        a.modern = await w.song("Chikni Chameli", year: 1995, lang: "hi", md: anu, singers: [talat])
        a.lonely = await w.song("Lonely Song", year: 1995, lang: "en")
        for s in [a.awaaraHoon, a.gharAaya, a.dumBhar, a.meraJoota, a.pyarHua, a.aeMere, a.yehZindagi, a.remix, a.modern] { await w.link(s, .inLanguage, a.hindi) }
        return a
    }
}

@Suite("Recommender") struct RecommenderTests {
    func rec(_ a: AwaaraGraph, store: (any MusicGraphStoring)? = nil, affinity: MusicAffinityStore? = nil) -> MusicRecommender {
        MusicRecommender(store: store ?? a.w.g, affinity: affinity)
    }
    var cold: MusicRecContext { var c = MusicRecContext(affinity: .empty); c.useCache = false; return c }

    @Test func awaaraRelatedSongsFollowTheBandsAndTheExplanationsNameRealPeople() async throws {
        let a = await AwaaraGraph.make()
        let r = await rec(a).recommend(for: a.awaaraHoon, kinds: [.recording], limit: 20, context: cold)
        let byID = Dictionary(uniqueKeysWithValues: r.items.map { ($0.id, $0) })
        #expect(r.coldStart)
        #expect(byID[a.gharAaya]?.band == .verifiedDirect)
        #expect(byID[a.dumBhar]?.band == .verifiedDirect)
        #expect(byID[a.gharAaya]?.explanation.text() == "From the same album: Awaara (Original Motion Picture Soundtrack)")
        #expect(byID[a.meraJoota]?.band == .sharedCreators)
        #expect(byID[a.meraJoota]?.explanation.text() == "Same creators: Shankar-Jaikishan, Shailendra and Mukesh")
        #expect(byID[a.pyarHua]?.band == .sharedCreators)
        #expect(byID[a.pyarHua]?.explanation.text() == "Same creators: Shankar-Jaikishan and Shailendra")
        #expect(byID[a.aeMere]?.band == .sameArtist)
        #expect(byID[a.aeMere]?.explanation.text() == "Same music director: Shankar-Jaikishan")
        #expect(byID[a.yehZindagi]?.band == .languageEra)
        #expect(byID[a.yehZindagi]?.explanation.text() == "Same era and language: 1950s Hindi")
        // The seed never recommends itself, noise stays out, and a 1995 song is not "same era" as 1951.
        #expect(byID[a.awaaraHoon] == nil && byID[a.lonely] == nil && byID[a.modern] == nil)
        // Strict order: band first, then score.
        for (x, y) in zip(r.items, r.items.dropFirst()) { #expect(x.band < y.band || (x.band == y.band && x.score >= y.score)) }
        // The song's own remix is a version of the same song: left out of related songs.
        #expect(byID[a.remix] == nil)
    }

    @Test func versionsSectionListsTheRemixAsBandOne() async throws {
        let a = await AwaaraGraph.make()
        let r = await rec(a).versions(of: a.awaaraHoon, context: cold)
        #expect(r.items.map(\.id) == [a.remix])
        #expect(r.items.first?.explanation.text() == "Another version of Awaara Hoon")
    }

    @Test func relatedSoundtracksViaCastDirectorAndMusicDirector() async throws {
        let a = await AwaaraGraph.make()
        let r = await rec(a).relatedSoundtracks(forAlbum: a.awaaraOST, limit: 10, context: cold)
        let by = Dictionary(uniqueKeysWithValues: r.items.map { ($0.id, $0) })
        // Same film, other language: a verified direct relationship, flagged as a dub (not folded into the original).
        #expect(by[a.awaaraTamil]?.band == .verifiedDirect)
        #expect(by[a.awaaraTamil]?.flags.contains(.dub) == true)
        #expect(by[a.awaaraTamil]?.explanation.text() == "Soundtrack of Awaara")
        // A soundtrack whose songs share the music director, lyricist and singers.
        #expect(by[a.shreeOST]?.band == .sharedCreators)
        #expect(by[a.shreeOST]?.explanation.text().hasPrefix("Same creators: Shankar-Jaikishan") == true)
        // A soundtrack of a film with the same cast (Raj Kapoor, Nargis) and nothing else in common but the music director.
        #expect(by[a.jagteOST]?.band == .sharedFilm)
        #expect(by[a.jagteOST]?.explanation.reason == .sharedCast)
        #expect(Set(by[a.jagteOST]?.explanation.subjects.compactMap(\.id) ?? []) == [a.rk, a.nargis])
        // Same music director only.
        #expect(by[a.barsaatOST]?.band == .sameArtist)
        #expect(by[a.barsaatOST]?.explanation.text() == "Same music director: Shankar-Jaikishan")
        // The 2010 remake's soundtrack is never tied to this film.
        #expect(by[a.ost2010] == nil)
        // Bands decide the order: edition, creators, cast, music director.
        let order = r.items.map(\.id)
        #expect(order.firstIndex(of: a.awaaraTamil)! < order.firstIndex(of: a.shreeOST)!)
        #expect(order.firstIndex(of: a.shreeOST)! < order.firstIndex(of: a.jagteOST)! && order.firstIndex(of: a.jagteOST)! < order.firstIndex(of: a.barsaatOST)!)
    }

    @Test func awaara1951AndTheRemakeStayApartAndTheRemakeIsFlagged() async throws {
        let a = await AwaaraGraph.make()
        var ctx = cold; ctx.includeBroad = true
        let r = await rec(a).relatedFilms(forFilm: a.awaara, limit: 10, context: ctx)
        let by = Dictionary(uniqueKeysWithValues: r.items.map { ($0.id, $0) })
        #expect(by[a.shree]?.band == .sharedFilm)
        #expect(by[a.shree]?.explanation.reason == .sharedCast)
        let remake = try #require(by[a.awaara2010])
        #expect(remake.band == .broad)
        #expect(remake.flags.contains(.remake))
        #expect(remake.explanation.text() == "Also in Hindi")
        // Without the explicit ask there is no broad band in a cold start.
        let strict = await rec(a).relatedFilms(forFilm: a.awaara, limit: 10, context: cold)
        #expect(strict.items.allSatisfy { $0.band <= .genre })
        #expect(!strict.items.contains { $0.id == a.awaara2010 })
    }

    @Test func listeningAffinityNeverLiftsALowerBandAboveAHigherOne() async throws {
        let a = await AwaaraGraph.make()
        // A huge affinity for Naushad and the 1950s Hindi language: the Naushad song is band 6 and must stay below the band 2 and 5 songs.
        let events = (0..<200).map { _ in MusicPlayEvent(kind: .liked, at: Date(), recording: a.yehZindagi, composers: [a.naushad], singers: [], film: nil, language: "hindi", year: 1952) }
        let loved = MusicAffinityBuilder.build(events: events, now: Date())
        var ctx = MusicRecContext(affinity: loved); ctx.useCache = false
        let r = await rec(a).recommend(for: a.awaaraHoon, kinds: [.recording], limit: 20, context: ctx)
        let bands = r.items.map(\.band)
        #expect(bands == bands.sorted())
        let by = Dictionary(uniqueKeysWithValues: r.items.map { ($0.id, $0) })
        let top = try #require(by[a.yehZindagi])
        #expect(top.affinityBoost > 0.9)
        #expect(top.band == .languageEra)
        for other in [a.meraJoota, a.pyarHua, a.aeMere, a.gharAaya] { #expect(by[other]!.score > top.score) }
        // The in-band part never reaches the next band's base.
        for c in r.items { #expect(c.score - c.band.base < 100 && c.score >= c.band.base) }
        #expect(!r.coldStart)
    }

    @Test func affinityReordersInsideABand() async throws {
        let a = await AwaaraGraph.make()
        // Two band 2 songs: Mera Joota (strength higher) vs Pyar Hua. Love Lata and the order inside the band may change, the band may not.
        let none = await rec(a).recommend(for: a.awaaraHoon, kinds: [.recording], limit: 20, context: cold)
        let nb2 = none.items.filter { $0.band == .sharedCreators }.map(\.id)
        #expect(nb2 == [a.meraJoota, a.pyarHua])
        let events = (0..<3).map { _ in MusicPlayEvent(kind: .completed, at: Date(), recording: a.pyarHua, composers: [], singers: [a.lata], film: a.shree, language: nil, year: nil) }
        var ctx = MusicRecContext(affinity: MusicAffinityBuilder.build(events: events, now: Date())); ctx.useCache = false
        let loved = await rec(a).recommend(for: a.awaaraHoon, kinds: [.recording], limit: 20, context: ctx)
        let lb2 = loved.items.filter { $0.band == .sharedCreators }.map(\.id)
        #expect(Set(lb2) == Set(nb2))
        #expect(lb2.first == a.pyarHua)
    }

    @Test func coldStartServesBandsOneToSevenAndNoHomeShelves() async throws {
        let a = await AwaaraGraph.make()
        let engine = rec(a)
        let r = await engine.recommend(for: a.awaaraHoon, limit: 50, context: cold)
        #expect(r.coldStart && !r.items.isEmpty)
        #expect(r.items.allSatisfy { $0.band.rawValue <= 7 })
        for kind in MusicHomeSection.Kind.allCases { #expect(await engine.homeSection(kind, context: cold) == nil) }
    }

    @Test func historyAddsBandEightAndTheHomeShelvesNeedSixItems() async throws {
        let a = await AwaaraGraph.make()
        // Plays of Awaara Hoon: the shelf "Soundtracks from movies you like" is seeded from the film Awaara.
        let events = (0..<5).map { _ in MusicPlayEvent(kind: .completed, at: Date(), recording: a.awaaraHoon, composers: [a.sj], singers: [a.mukesh], film: a.awaara, language: "hindi", year: 1951) }
        let v = MusicAffinityBuilder.build(events: events, now: Date())
        #expect(!v.isEmpty && v.top(.film, count: 1).first?.id == a.awaara)
        var ctx = MusicRecContext(affinity: v); ctx.useCache = false
        let engine = rec(a)
        let section = await engine.homeSection(.soundtracksFromMoviesYouLike, context: ctx)
        let shelf = try #require(section)
        #expect(shelf.items.count >= MusicHomeSection.minimumItems)
        #expect(shelf.seeds == [a.awaara] && shelf.items.allSatisfy { $0.kind == .album || $0.kind == .release })
        #expect(shelf.items.contains { $0.id == a.awaaraOST })
        // One composer in the history: the composers shelf stays below the six-item rule and is hidden.
        #expect(await engine.homeSection(.composersYouListenTo, context: ctx) == nil)
    }

    @Test func bandEightCarriesBecauseYouPlayWording() async throws {
        let w = RecWorld()
        let te = await w.ent(.language, "Telugu", uid: "lang:te")
        let dsp = await w.ent(.person, "Devi Sri Prasad", year: 1979)
        let film = await w.ent(.film, "Pushpa", lang: "te", year: 2021)
        let seed = await w.song("Srivalli", year: 2021, lang: "te", film: film, md: dsp)
        let far = await w.song("Some Telugu Song", year: 1975, lang: "te")
        for s in [seed, far] { await w.link(s, .inLanguage, te) }
        let events = (0..<8).map { _ in MusicPlayEvent(kind: .completed, at: Date(), recording: nil, composers: [], singers: [], film: film, language: "telugu", year: 2021) }
        var ctx = MusicRecContext(affinity: MusicAffinityBuilder.build(events: events, now: Date())); ctx.useCache = false
        let r = await MusicRecommender(store: w.g).recommend(for: seed, kinds: [.recording], limit: 5, context: ctx)
        let hit = try #require(r.items.first { $0.id == far })
        #expect(hit.band == .affinity)
        #expect(hit.explanation.text() == "Because you play Telugu music")
        // Without history the same song is not recommended at all (and nothing is invented about it).
        let coldR = await MusicRecommender(store: w.g).recommend(for: seed, kinds: [.recording], limit: 5, context: { var c = MusicRecContext(affinity: .empty); c.useCache = false; return c }())
        #expect(!coldR.items.contains { $0.id == far })
    }

    @Test func teluguSoundtrackWithAnInferredFilmLinkIsHedged() async throws {
        let w = RecWorld()
        let dsp = await w.ent(.person, "Devi Sri Prasad", year: 1979)
        let sid = await w.ent(.person, "Sid Sriram", year: 1990)
        let pushpa = await w.ent(.film, "Pushpa: The Rise", lang: "te", year: 2021)
        let album = await w.ent(.album, "Pushpa (Telugu Original Soundtrack)", lang: "te", year: 2021)
        // The film link comes from provider wording only: inferred, below the 0.75 line.
        await w.link(album, .soundtrackOf, pushpa, verified: false)
        let seed = await w.song("Srivalli", year: 2021, lang: "te", album: album, md: dsp, singers: [sid])
        await w.link(seed, .featuredIn, pushpa, verified: false)
        let sibling = await w.song("Eyy Bidda", year: 2021, lang: "te", md: await w.ent(.person, "Someone Else"))
        await w.link(sibling, .featuredIn, pushpa, verified: false)
        let r = await MusicRecommender(store: w.g).recommend(for: seed, kinds: [.recording], limit: 5, context: { var c = MusicRecContext(affinity: .empty); c.useCache = false; return c }())
        let hit = try #require(r.items.first { $0.id == sibling })
        #expect(hit.band == .sharedFilm)
        #expect(hit.explanation.tentative && hit.flags.contains(.inferredLink))
        #expect(hit.explanation.text() == "From the film Pushpa: The Rise")
        // The film itself is offered with the same hedge, and no cast, composer or relationship beyond the edges was invented.
        let f = await MusicRecommender(store: w.g).recommend(for: seed, kinds: [.film], limit: 5, context: { var c = MusicRecContext(affinity: .empty); c.useCache = false; return c }())
        #expect(f.items.map(\.id) == [pushpa])
        #expect(f.items[0].explanation.tentative)
    }

    @Test func nearIdenticalVersionsFoldIntoOneWithACount() async throws {
        let w = RecWorld()
        let md = await w.ent(.person, "Yuvan Shankar Raja"), singer = await w.ent(.person, "Karthik")
        let seed = await w.song("Seed Song", year: 2010, lang: "ta", md: md, singers: [singer])
        let work = await w.ent(.work, "Munbe Vaa")
        let orig = await w.song("Munbe Vaa", year: 2010, lang: "ta", md: md, singers: [singer], attrs: ["versionKind": "original"])
        let remix = await w.song("Munbe Vaa (Remix)", year: 2018, lang: "ta", md: md, singers: [singer], attrs: ["versionKind": "remix"])
        let karaoke = await w.song("Munbe Vaa - Karaoke Version", year: 2018, lang: "ta", md: md, singers: [singer], attrs: ["versionKind": "karaoke"])
        for r in [orig, remix, karaoke] { await w.link(r, .recordingOf, work) }
        // Same title and same cover art by the same singer, with no work link at all.
        let twinA = await w.song("Pachai Nirame", year: 2010, lang: "ta", md: md, singers: [singer], img: "art:pn")
        let twinB = await w.song("Pachai Nirame", year: 2010, lang: "ta", md: md, singers: [singer], img: "art:pn")
        let ids = [seed, orig, remix, karaoke, twinA, twinB]
        _ = ids
        let r = await MusicRecommender(store: w.g).recommend(for: seed, kinds: [.recording], limit: 20, context: { var c = MusicRecContext(affinity: .empty); c.useCache = false; return c }())
        let munbe = r.items.filter { [orig, remix, karaoke].contains($0.id) }
        #expect(munbe.count == 1)
        #expect(munbe.first?.id == orig && munbe.first?.versionCount == 3)
        let pn = r.items.filter { [twinA, twinB].contains($0.id) }
        #expect(pn.count == 1 && pn[0].versionCount == 2)
    }

    @Test func identicalNamePeopleAreNeverConflated() async throws {
        let w = RecWorld()
        let md = await w.ent(.person, "Salil Chowdhury", year: 1925), other = await w.ent(.person, "Other Composer")
        let bakshi1 = await w.ent(.person, "Anand Bakshi", year: 1930, uid: "mb:ab1"), bakshi2 = await w.ent(.person, "Anand Bakshi", year: 1962, uid: "mb:ab2")
        #expect(bakshi1 != bakshi2)
        let seed = await w.song("Seed", year: 1970, lang: "hi", md: md, lyricist: bakshi1)
        let sameName = await w.song("By The Other Bakshi", year: 1970, lang: "hi", md: other, lyricist: bakshi2)
        let sameMD = await w.song("Same MD With The Other Bakshi", year: 1971, lang: "hi", md: md, lyricist: bakshi2)
        let sameLyricist = await w.song("Same Lyricist", year: 1972, lang: "hi", md: other, lyricist: bakshi1)
        let r = await MusicRecommender(store: w.g).recommend(for: seed, kinds: [.recording], limit: 10, context: { var c = MusicRecContext(affinity: .empty); c.useCache = false; return c }())
        let by = Dictionary(uniqueKeysWithValues: r.items.map { ($0.id, $0) })
        #expect(by[sameName] == nil)                       // a name is not a link
        #expect(by[sameMD]?.band == .sameArtist)            // one shared person (the music director), never "two creators"
        #expect(by[sameMD]?.explanation.subjects.map(\.id) == [md])
        #expect(by[sameLyricist]?.explanation.text() == "Same lyricist: Anand Bakshi")
        #expect(by[sameLyricist]?.explanation.subjects.first?.id == bakshi1)
    }

    @Test func unrelatedEntitiesGetNoExplanation() async throws {
        let a = await AwaaraGraph.make()
        let e = await rec(a).explain(a.lonely, for: a.awaaraHoon, context: cold)
        #expect(e.isEmpty)
        let real = await rec(a).explain(a.meraJoota, for: a.awaaraHoon, context: cold)
        #expect(real.first?.reason == .sharedCreators)
        #expect(real.count >= 1)
    }

    @Test func everyExplanationRestsOnARealEdge() async throws {
        let a = await AwaaraGraph.make()
        let g = a.w.g
        let r = await rec(a).recommend(for: a.awaaraHoon, kinds: [.recording, .album, .film, .person], limit: 50, context: cold)
        func credited(_ id: MusicEntityID) async -> Set<MusicEntityID> {
            var out: Set<MusicEntityID> = []
            var nodes: [MusicEntityID] = [id]
            for e in try! await g.edges(of: id, predicate: nil, direction: .outgoing, limit: 100) where [.trackOn, .featuredIn, .soundtrackOf].contains(e.predicate) { nodes.append(e.object) }
            if id.kind == .album || id.kind == .release { for t in try! await g.edges(of: id, predicate: .trackOn, direction: .incoming, limit: 100) { nodes.append(t.subject) } }
            for n in nodes { for e in try! await g.edges(of: n, predicate: nil, direction: .outgoing, limit: 100) where e.object.kind.isAgent { out.insert(e.object) } }
            return out
        }
        let seedPeople = await credited(a.awaaraHoon)
        for c in r.items {
            let candPeople = await credited(c.id)
            for e in [c.explanation] + c.otherReasons {
                switch e.reason {
                case .sharedCreators, .sameMusicDirector, .sameComposer, .sameSinger, .sameLyricist, .sameArtist:
                    for s in e.subjects { if let id = s.id { #expect(seedPeople.contains(id) && candPeople.contains(id), "\(e.reason) \(s.name)") } }
                case .sameAlbum, .onAlbum:
                    for s in e.subjects { let ids = try await g.edges(of: a.awaaraHoon, predicate: .trackOn).map(\.object); #expect(ids.contains(s.id!)) }
                case .sameFilm, .featuredInFilm:
                    for s in e.subjects { let films = try await g.edges(of: a.awaaraHoon, predicate: .featuredIn).map(\.object); #expect(films.contains(s.id!)) }
                default: break
                }
                #expect(!e.text().isEmpty)
            }
        }
    }

    @Test func outageAnswersFromTheCacheAndOfflineWorksFromCachedEdges() async throws {
        let a = await AwaaraGraph.make()
        let store = CountingStore(a.w.g)
        let engine = MusicRecommender(store: store, cache: MusicRecommendationCache(capacity: 8, ttl: 120))
        var ctx = MusicRecContext(affinity: .empty)
        let first = await engine.recommend(for: a.awaaraHoon, kinds: [.recording], limit: 10, context: ctx)
        #expect(!first.items.isEmpty && !first.fromCache)
        // A repeat inside the TTL costs no graph reads.
        store.resetCounts()
        let second = await engine.recommend(for: a.awaaraHoon, kinds: [.recording], limit: 10, context: ctx)
        #expect(second.fromCache && store.edgeCalls == 0 && store.neighbourCalls == 0)
        #expect(second.items.map(\.id) == first.items.map(\.id))
        // Past the TTL with the graph down: the old answer is served and marked stale.
        store.down = true
        ctx.now = Date().addingTimeInterval(3_600)
        let stale = await engine.recommend(for: a.awaaraHoon, kinds: [.recording], limit: 10, context: ctx)
        #expect(stale.stale && stale.items.map(\.id) == first.items.map(\.id))
        // Never seen and the graph down: nothing, and no crash.
        let none = await engine.recommend(for: a.shreeOST, kinds: [.album], limit: 10, context: ctx)
        #expect(none.items.isEmpty)
        // No network is involved at all: the same engine over cached edges answers with the graph back.
        store.down = false
        let back = await engine.recommend(for: a.awaaraHoon, kinds: [.recording], limit: 10, context: ctx)
        #expect(!back.stale && back.items.map(\.id) == first.items.map(\.id))
    }

    @Test func traversalStaysInsideItsBounds() async throws {
        let a = await AwaaraGraph.make()
        let store = CountingStore(a.w.g)
        let r = await MusicRecommender(store: store).recommend(for: a.awaaraHoon, kinds: [.recording], limit: 10, context: cold)
        #expect(store.neighbourCalls == 1 && store.lastDepth <= 2 && store.lastFan <= 40)
        #expect(r.visitedNodes <= MusicTraversal.maxNodes)
        var ctx = cold; ctx.depth = 9; ctx.fanOut = 999
        _ = await MusicRecommender(store: store).recommend(for: a.awaaraHoon, kinds: [.recording], limit: 10, context: ctx)
        #expect(store.lastDepth == 9)   // the engine passes the ask on; the store clamps it to 2 and 40 (see the store's own tests)
        let nb = try await a.w.g.neighbours(of: a.awaaraHoon, depth: 9, fanOut: 999)
        #expect(nb.nodes.allSatisfy { $0.depth <= MusicTraversal.maxDepth } && nb.nodes.count <= MusicTraversal.maxNodes)
    }

    @Test func cacheEvictsLeastRecentlyUsedAndInvalidatesByEntity() async throws {
        let cache = MusicRecommendationCache(capacity: 2, ttl: 10)
        let ids = (0..<3).map { MusicEntityID.derive(kind: .recording, aliasKey: "c\($0)") }
        for id in ids { await cache.store(.empty(id), for: .init(seed: id, signature: "x")) }
        #expect(await cache.count == 2)
        #expect(await cache.stale(.init(seed: ids[0], signature: "x")) == nil)
        #expect(await cache.fresh(.init(seed: ids[1], signature: "x")) != nil)
        await cache.invalidate(ids[1])
        #expect(await cache.stale(.init(seed: ids[1], signature: "x")) == nil)
        #expect(await cache.fresh(.init(seed: ids[2], signature: "x"), now: Date().addingTimeInterval(60)) == nil)
    }

    @Test func radioCandidatesAreSpacedAndPlayableOnly() async throws {
        let a = await AwaaraGraph.make()
        let blocked: Set<MusicEntityID> = [a.pyarHua]
        let r = await rec(a).radioCandidates(seed: a.awaaraHoon, limit: 10, maxRun: 1, context: cold, isPlayable: { !blocked.contains($0) })
        #expect(!r.items.contains { $0.id == a.pyarHua })
        for (x, y) in zip(r.items, r.items.dropFirst()) { #expect(x.artist == nil || x.artist != y.artist || r.items.allSatisfy { $0.artist == x.artist }) }
    }

    @Test func continueExploringIsBuiltFromTheSeedsOwnEdges() async throws {
        let a = await AwaaraGraph.make()
        let steps = await rec(a).continueExploring(for: a.awaaraOST)
        #expect(steps.contains { $0.kind == .film && $0.target == a.awaara && $0.title == "Awaara" })
        #expect(steps.contains { if case .person = $0.kind { return $0.target == a.sj } else { return false } })
        #expect(steps.contains { $0.kind == .era(decade: 1950) })
        #expect(steps.last?.kind == .radio)
        let empty = await rec(a).continueExploring(for: a.lonely)
        #expect(empty.map(\.kind) == [.era(decade: 1990), .radio])
    }

    @Test func affinityBuilderDecaysAndPropagates() async throws {
        let now = Date()
        let id = MusicEntityID.derive(kind: .recording, aliasKey: "r"), c = MusicEntityID.derive(kind: .person, aliasKey: "c")
        let old = MusicPlayEvent(kind: .completed, at: now.addingTimeInterval(-60 * 86_400), recording: id, composers: [c], film: nil, language: "tel", year: 1999)
        let v = MusicAffinityBuilder.build(events: [old], now: now)
        #expect(abs(v.recording[id]! - 0.5) < 0.001)                   // one half-life
        #expect(abs(v.composer[c]! - 0.25) < 0.001)                    // 0.5 propagation
        #expect(v.decade[1990] != nil && v.language["tel"] != nil)
        // A like then an unlike of the same song cancel out; a skip alone never goes below zero.
        let ev = [MusicPlayEvent(kind: .liked, at: now, recording: id), MusicPlayEvent(kind: .unliked, at: now, recording: id), MusicPlayEvent(kind: .skipped, at: now, recording: c)]
        #expect(MusicAffinityBuilder.build(events: ev, now: now).isEmpty)
        // Reset floor ignores older plays.
        #expect(MusicAffinityBuilder.build(events: [old], now: now, since: now).isEmpty)
        // History plays are classified as the design says.
        #expect(MusicHistoryPlay(providerUID: "x", at: now, playedMs: 200_000, durationMs: 210_000).eventKind == .completed)
        #expect(MusicHistoryPlay(providerUID: "x", at: now, playedMs: 40_000, durationMs: 300_000).eventKind == .partial)
        #expect(MusicHistoryPlay(providerUID: "x", at: now, playedMs: 5_000, durationMs: 300_000).eventKind == .skipped)
    }

    @Test func affinityStoreResetsAndWipes() async throws {
        let id = MusicEntityID.derive(kind: .recording, aliasKey: "r")
        let clock = GraphTestClock()
        let t0 = clock.now
        let store = MusicAffinityStore(clock: clock.reader) { [MusicPlayEvent(kind: .completed, at: t0, recording: id)] }
        #expect(await store.vector().recording[id] == 1)
        clock.advance(10)
        await store.reset()
        #expect(await store.vector().isEmpty)
        await store.wipe(); await store.invalidate()
        #expect(await store.vector().recording[id] != nil)
    }
}
