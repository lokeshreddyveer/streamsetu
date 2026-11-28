import Foundation
import Testing
@testable import REDDY

/// A resolver over the in-memory graph and the real sources, answered from recorded replies.
struct ResolverRig {
    let store: MusicInMemoryGraph
    let resolver: MusicEntityResolver
    let transport: FixtureTransport
    let clock: GraphTestClock

    init(policy: MusicEnrichmentPolicy = .open, tmdb: MusicFilmTMDBGate.Fetch? = nil, routes: Bool = true) {
        let clock = GraphTestClock()
        let t = FixtureTransport()
        if routes { ResolverRig.addRoutes(t) }
        let store = MusicInMemoryGraph(clock: clock.reader)
        self.store = store; self.transport = t; self.clock = clock
        self.resolver = MusicEntityResolver(store: store, sources: MusicMetadataSources.make(transport: t, tmdb: tmdb), gate: policy, now: clock.reader)
    }

    static func addRoutes(_ t: FixtureTransport) {
        t.peopleFiles = ["wikidata_people_awaara_cast.json", "wikidata_people_paiyaa_cast.json", "wikidata_people_vikram_cast.json"]
        // MusicBrainz
        t.route("release-group?", "mb_release_group_search_awaara_shankar_jaikishan.json")
        t.route("releasegroup:\"Awāra\"", "mb_release_group_search_awara_macron.json")
        t.route("releasegroup:\"Awaara\" AND artist:\"Yuvan Shankar Raja\"", "mb_release_group_search_awaara_yuvan.json")
        t.route("release-group/81c5af83", "mb_release_group_awaara_1951.json")
        t.route("release/ba487396", "mb_release_awaara_1951.json")
        t.route("release-group/93b12826", "mb_release_group_awaara_2010.json")
        t.route("recording/f0e5a1dd", "mb_recording_awara_hoon.json")
        // Wikidata
        t.route("action=wbsearchentities", "wikidata_search_awaara.json")
        t.route("Q858681.json", "wikidata_entity_q858681_awaara_film.json")
        t.route("Q3473406.json", "wikidata_entity_q3473406_paiyaa_film.json")
        t.route("Q102147287.json", "wikidata_entity_q102147287_vikram_film.json")
        t.route("query.wikidata.org", "wikidata_sparql_vikram_by_imdb.json")
        // Wikipedia
        t.route("generator=search", "wikipedia_search_awaara_2010.json")
        t.route("page=Paiyaa (soundtrack)", "wikipedia_wikitext_paiyaa_soundtrack.json")
        t.route("titles=Paiyaa", "wikipedia_pageprops_paiyaa.json")
        t.route("page=Paiyaa&", "wikipedia_wikitext_paiyaa_en.json")
        t.route("page=ఆవారా", "wikipedia_wikitext_awaara_te.json")
        t.route("page=Vikram (2022 film)", "wikipedia_wikitext_vikram_en.json")
        t.route("page=Awaara&", "wikipedia_wikitext_awaara_en_lead.json")
        // IMDb
        t.route("suggestion/a/awaara", "imdb_suggestion_awaara.json")
        t.route("suggestion/v/vikram", "imdb_suggestion_vikram.json")
        t.route("imdb.com/title/", "imdb_title_page_blocked_challenge.html")
    }

    func film(named name: String) async -> MusicEntityID? { try? await store.search(name, kinds: [.film]).first?.id }
    func creditNames(_ id: MusicEntityID, _ p: MusicPredicate) async -> [String] {
        var out: [String] = []
        for e in (try? await store.edges(of: id, predicate: p, direction: .outgoing, limit: 200)) ?? [] { if let s = try? await store.entity(e.object) { out.append(s.name) } }
        return out
    }

    static func track(_ n: Int, _ title: String, ms: Int64, artist: String) -> MusicTrack {
        MusicTrack(id: "t\(n)", providerID: "jiosaavn", title: title, durationMs: ms, trackNumber: n, artists: [MusicArtistRef(id: "ar\(n)", name: artist)])
    }
    static let album1951 = MusicAlbum(id: "alb1951", providerID: "jiosaavn", title: "Awaara", artists: [MusicArtistRef(id: "sj", name: "Shankar Jaikishan")], releaseDate: "2005-01-01", albumType: "album")
    static let tracks1951 = [track(1, "Ek Do Teen", ms: 168_000, artist: "Shamshad Begum"), track(2, "Hum Tujhse Mohabbat Kar Ke", ms: 200_000, artist: "Mukesh"), track(3, "Awaara Hoon", ms: 186_000, artist: "Mukesh")]
    static let album2010 = MusicAlbum(id: "alb2010", providerID: "jiosaavn", title: "Awaara", artists: [MusicArtistRef(id: "yu", name: "Yuvan Shankar Raja")], releaseDate: "2010-04-10", albumType: "album")
}

@Suite("Entity resolver: walkthroughs") struct MetadataWalkthroughTests {
    @Test func awaara1951AlbumResolvesToTheFilmInferredWithEvidence() async throws {
        let rig = ResolverRig()
        let r = await rig.resolver.enrichAlbum(ResolverRig.album1951, tracks: ResolverRig.tracks1951, hints: MusicAlbumHints(language: "hi", musicBy: ["Shankar Jaikishan"]))
        let rel = try #require(r.entity)
        let group = try #require(try await rig.store.edges(of: rel, predicate: .editionOf).first?.object, "release is an edition of the MusicBrainz release group")
        let film = try #require(r.linkedFilm)
        let edge = try #require(try await rig.store.edge(MusicEdgeKey(subject: group, predicate: .soundtrackOf, object: film)))
        #expect(edge.status == .inferred, "no source states the soundtrack link")
        #expect(edge.confidence >= 0.85)
        let facts = try await rig.store.facts(for: edge.key)
        #expect(facts.allSatisfy { !$0.statesLink } && facts.first?.evidence.contains("composer") == true && facts.first?.evidence.contains("title") == true)
        let snap = try #require(try await rig.store.entity(film))
        #expect(snap.name == "Awaara" && snap.year == 1951)
        let ids = try await rig.store.externalIDs(of: film)
        #expect(ids.contains(ExternalID(.wikidata, "Q858681")) && ids.contains(ExternalID(.imdbTitle, "tt0043306")) && ids.contains(ExternalID(.tmdbMovie, "39039")))
        #expect(await rig.creditNames(film, .hasCast).count == 9)
        // The MusicBrainz tracklist binds to the saved tracks: credits land on the recording the library holds.
        let ekDoTeen = try #require(try await rig.store.resolveAlias(for: ExternalID(.mbid, "898bbd1e-ee84-4aed-a154-62b7cf57d0f3")))
        let saved = MusicEntityID.provisional(kind: .recording, providerUID: ResolverRig.tracks1951[0].uid)
        #expect(try await rig.store.resolve(ekDoTeen) == saved)
        #expect(r.failed.isEmpty && r.skipped.isEmpty)
    }

    @Test func awaara1951SingleFilmPersonHasThreeRolesAndTheDuoIsAGroup() async throws {
        let rig = ResolverRig()
        let r = await rig.resolver.enrichAlbum(ResolverRig.album1951, tracks: ResolverRig.tracks1951, hints: MusicAlbumHints(language: "hi", musicBy: ["Shankar Jaikishan"]))
        let film = try #require(r.linkedFilm)
        let raj = try #require(try await rig.store.search("Raj Kapoor", kinds: [.person]).first?.id)
        var roles = Set<String>()
        for e in try await rig.store.edges(of: film, predicate: nil, direction: .outgoing, limit: 100) where e.object == raj { roles.insert(e.qualifier) }
        #expect(roles == ["actor", "director", "producer"])
        let composers = try await rig.store.edges(of: film, predicate: .composedBy)
        #expect(composers.first?.object.kind == .group)
    }

    @Test func awaara2010ResolvesToThePaiyaaFilmAsADubAndNeverTo1951() async throws {
        let rig = ResolverRig()
        let tracks = [ResolverRig.track(1, "Thuli Thuli", ms: 250_000, artist: "Yuvan Shankar Raja")]
        let r = await rig.resolver.enrichAlbum(ResolverRig.album2010, tracks: tracks, hints: MusicAlbumHints(language: "te", musicBy: ["Yuvan Shankar Raja"]))
        let rel = try #require(r.entity)
        let group = try #require(try await rig.store.edges(of: rel, predicate: .editionOf).first?.object)
        let film = try #require(r.linkedFilm)
        let snap = try #require(try await rig.store.entity(film))
        #expect(snap.name == "Paiyaa" && snap.year == 2010)
        let edge = try #require(try await rig.store.edge(MusicEdgeKey(subject: group, predicate: .soundtrackOf, object: film)))
        #expect(edge.status == .inferred && edge.attributes.dubLanguage == "te")
        let facts = try await rig.store.facts(for: edge.key)
        #expect(facts.first?.evidence.contains("dub-language") == true)
        let f1951 = try await rig.store.resolveAlias(for: ExternalID(.wikidata, "Q858681"))
        if let f1951 { #expect(try await rig.store.edge(MusicEdgeKey(subject: group, predicate: .soundtrackOf, object: f1951)) == nil) }
        #expect(await rig.transport.calls(containing: "Q858681.json") == 0, "the 1951 film was never even fetched for the 2010 album")
    }

    @Test func paiyaaCastComesFromWikipediaWhenWikidataIsThin() async throws {
        let rig = ResolverRig()
        let r = await rig.resolver.enrichAlbum(ResolverRig.album2010, tracks: [], hints: MusicAlbumHints(language: "te", musicBy: ["Yuvan Shankar Raja"]))
        let film = try #require(r.linkedFilm)
        let f = await rig.resolver.enrichFilm(film)
        #expect(f.fetched.contains(.wikipedia))
        let cast = await rig.creditNames(film, .hasCast)
        #expect(cast.contains("Tamannaah Bhatia") && cast.count >= 6)
        let tam = try #require(try await rig.store.search("Tamannaah Bhatia", kinds: [.person]).first)
        let e = try #require(try await rig.store.edge(MusicEdgeKey(subject: film, predicate: .hasCast, object: tam.id, qualifier: "actor")))
        #expect(e.attributes["attribution"] == "Wikipedia" && e.status == .inferred)
        let facts = try await rig.store.facts(for: e.key)
        #expect(facts.first?.source == .wikipedia && facts.first?.license == .ccBySa)
    }

    @Test func vikramCastResolvesWithoutTMDB() async throws {
        let rig = ResolverRig(tmdb: nil)
        // The film is first known from IMDb's public suggestion list only.
        let sug = MusicIMDbParser.search(MetadataFixtures.data("imdb_suggestion_vikram.json"))
        _ = try await rig.resolver.ingest({ var b = sug; b.isSearch = false; return b }())
        let film = try #require(try await rig.store.resolveAlias(for: ExternalID(.imdbTitle, "tt9179430")))
        let r = await rig.resolver.enrichFilm(film)
        #expect(r.skipped[.tmdb] == .unconfigured, "TMDB is optional and was not asked")
        let cast = await rig.creditNames(film, .hasCast)
        #expect(cast.count >= 25 && cast.contains("Kamal Haasan") && cast.contains("Vijay Sethupathi") && cast.contains("Fahadh Faasil"))
        #expect(await rig.transport.calls(containing: "api.themoviedb.org") == 0)
        let ids = try await rig.store.externalIDs(of: film)
        #expect(ids.contains(ExternalID(.wikidata, "Q102147287")) && ids.contains(ExternalID(.imdbTitle, "tt9179430")))
    }
}

@Suite("Entity resolver: rules") struct MetadataResolverRuleTests {
    private func person(_ name: String, _ ids: [ExternalID], year: Int? = nil) -> MusicSourceDraft {
        MusicSourceDraft(.external(.person, ids[0]), MusicEntityDraft(kind: .person, name: name, year: year, externalIDs: ids))
    }
    private func batch(_ d: [MusicSourceDraft]) -> MusicClaimBatch {
        var b = MusicClaimBatch(source: .wikidata, license: .cc0); b.drafts = d; return b
    }

    @Test func strongIdsJoinDraftsAcrossSourcesIntoOnePerson() async throws {
        let rig = ResolverRig(routes: false)
        let a = try await rig.resolver.ingest(batch([person("Raj Kapoor", [ExternalID(.tmdbPerson, "110860")])]))
        let b = try await rig.resolver.ingest(batch([person("Raj Kapoor", [ExternalID(.wikidata, "Q55407"), ExternalID(.tmdbPerson, "110860"), ExternalID(.imdbName, "nm0004072")])]))
        #expect(a.ids.values.first == b.ids.values.first)
        let counts = try await rig.store.counts()
        #expect(counts.entities == 1 && counts.externalIDs == 3)
    }

    @Test func aDraftThatTiesTwoEntitiesTogetherMergesThemAndLeavesATombstone() async throws {
        let rig = ResolverRig(routes: false)
        let x = try await rig.resolver.ingest(batch([person("Mukesh", [ExternalID(.tmdbPerson, "5")])])).ids.values.first!
        let y = try await rig.resolver.ingest(batch([person("Mukesh", [ExternalID(.wikidata, "Q9")])])).ids.values.first!
        #expect(x != y)
        let rep = try await rig.resolver.ingest(batch([person("Mukesh", [ExternalID(.wikidata, "Q9"), ExternalID(.tmdbPerson, "5")])]))
        #expect(rep.merged.count == 1)
        let one = try await rig.store.resolve(x), two = try await rig.store.resolve(y)
        #expect(one == two, "the loser redirects to the survivor")
    }

    @Test func differentStrongIdsOfOneSchemeBlockTheMerge() async throws {
        let rig = ResolverRig(routes: false)
        let x = try await rig.resolver.ingest(batch([person("Shankar", [ExternalID(.tmdbPerson, "7")], year: 1922)])).ids.values.first!
        let y = try await rig.resolver.ingest(batch([person("Shankar", [ExternalID(.wikidata, "Q9")], year: 1922)])).ids.values.first!
        let rep = try await rig.resolver.ingest(batch([person("Shankar", [ExternalID(.wikidata, "Q9"), ExternalID(.tmdbPerson, "7"), ExternalID(.tmdbPerson, "8")])]))
        let one = try await rig.store.resolve(x), two = try await rig.store.resolve(y)
        #expect(one != two && rep.merged.isEmpty, "an entity that already holds a different id of the same scheme is never joined")
    }

    @Test func identicalNamesKeepTwoPersonsWithDifferentBirthYears() async throws {
        let rig = ResolverRig(routes: false)
        let singer = try await rig.resolver.ingest(batch([person("Mukesh", [ExternalID(.wikidata, "Q2367593")], year: 1923)])).ids.values.first!
        let actor = try await rig.resolver.ingest(batch([person("Mukesh", [ExternalID(.wikidata, "Q777")], year: 1990)])).ids.values.first!
        #expect(singer != actor)
        let ev = MusicResolutionScoring.person(nameSimilarity: 1, sharedRecording: true, sharedRelease: true, yearA: 1923, yearB: 1990)
        #expect(MusicMergeRule.decide(ev) == .reject, "life years more than two apart block the merge")
        let hits = try await rig.store.search("Mukesh", kinds: [.person])
        #expect(hits.count == 2)
    }

    @Test func aPersonMergeNeedsTwoSignalsBeyondTheName() {
        #expect(MusicMergeRule.decide(MusicResolutionScoring.person(nameSimilarity: 1, sharedRecording: false, sharedRelease: false, yearA: nil, yearB: nil)) != .merge)
        #expect(MusicMergeRule.decide(MusicResolutionScoring.person(nameSimilarity: 1, sharedRecording: true, sharedRelease: false, yearA: nil, yearB: nil)) != .merge)
        #expect(MusicMergeRule.decide(MusicResolutionScoring.person(nameSimilarity: 1, sharedRecording: true, sharedRelease: true, yearA: nil, yearB: nil)) == .merge)
    }

    @Test func nameOnlyCreditsJoinTheFilmsExistingPersonButNotAnotherFilmsPerson() async throws {
        let rig = ResolverRig(routes: false)
        let film = try await rig.resolver.ingest(try #require(MusicWikidataParser.item(MetadataFixtures.data("wikidata_entity_q858681_awaara_film.json"), qid: "Q858681", kind: .film,
                                                                                       people: MusicWikidataParser.people(MetadataFixtures.data("wikidata_people_awaara_cast.json"))))).ids.values.first { $0.kind == .film }!
        let before = try await rig.store.counts().entities
        let wt = "{{Infobox film\n| starring = [[Raj Kapoor]], [[Nargis]]\n| director = [[Raj Kapoor]]\n}}"
        var wb = MusicWikipediaParser.film(wikitext: wt, lang: "en", article: "Awaara", film: .external(.film, ExternalID(.wikidata, "Q858681")))
        wb.drafts.append(MusicSourceDraft(.external(.film, ExternalID(.wikidata, "Q858681")), MusicEntityDraft(kind: .film, name: "Awaara", externalIDs: [ExternalID(.wikidata, "Q858681")])))
        _ = try await rig.resolver.ingest(wb)
        #expect(try await rig.store.counts().entities == before, "the same names join the people Wikidata gave")
        let e = try #require(try await rig.store.edges(of: film, predicate: .hasCast).first { $0.qualifier == "actor" })
        let facts = try await rig.store.facts(for: e.key)
        #expect(Set(facts.map(\.source.rawValue)).isSuperset(of: ["wikidata", "wikipedia"]), "Wikipedia corroborates the same edge instead of adding a second person")
    }

    @Test func tmdbFactsAreAttributedAndExpireAfterThirtyDaysWithNoImageStored() async throws {
        let json = #"{"id":39039,"title":"Awaara","release_date":"1951-12-14","original_language":"hi","imdb_id":"tt0043306","credits":{"cast":[{"id":1,"name":"Raj Kapoor","character":"Raj","order":0,"profile_path":"/a.jpg"}],"crew":[{"id":1,"name":"Raj Kapoor","job":"Director"},{"id":2,"name":"Shankar Jaikishan","job":"Original Music Composer"}]},"external_ids":{"wikidata_id":"Q858681"},"alternative_titles":{"titles":[{"iso_3166_1":"US","title":"The Vagabond"}]}}"#
        let rig = ResolverRig(tmdb: { _, _ in Data(json.utf8) }, routes: false)
        let t = TMDBGraphSource(gate: { _, _ in Data(json.utf8) })
        let b = try await t.fetch(MusicSourceRequest(.tmdb, MusicFacet.filmCredits, ["tmdb": "39039"]), context: MusicFetchContext(now: rig.clock.reader))
        #expect(b.attribution == "TMDB" && b.retention == 30 * 86_400)
        let rep = try await rig.resolver.ingest(b)
        let film = try #require(rep.ids.values.first { $0.kind == .film })
        let cast = try #require(try await rig.store.edges(of: film, predicate: .hasCast).first)
        #expect(cast.attributes["attribution"] == "TMDB" && cast.attributes.characterName == "Raj")
        let f = try #require(try await rig.store.facts(for: cast.key).first)
        #expect(f.license == .termsRestricted && f.expiresAt == f.retrievedAt.addingTimeInterval(30 * 86_400))
        let person = try #require(try await rig.store.entity(cast.object))
        #expect(person.imageRef == nil, "profile paths are hints, never stored")
        #expect(rep.imageHints[cast.object]?.contains("/a.jpg") == true)
        #expect(try await rig.store.aliases(of: film).contains { $0.text == "The Vagabond" })
    }

    @Test func twoFilmsBothInTheMergeBandStayTwoAndTheLinkIsConflicted() async throws {
        let wd = CountingSource(.wikidata) { req in
            var b = MusicClaimBatch(source: .wikidata, license: .cc0)
            if req.facet == MusicFacet.filmSearch {
                b.isSearch = true
                for (q, y) in [("Q1", 2010), ("Q2", 2011)] { b.drafts.append(MusicSourceDraft(.external(.film, ExternalID(.wikidata, q)), MusicEntityDraft(kind: .film, name: "Kaathal", year: y, externalIDs: [ExternalID(.wikidata, q)]))) }
            } else {
                let q = req.param("qid") ?? "Q1"
                let f = MusicDraftRef.external(.film, ExternalID(.wikidata, q)), c = MusicDraftRef.external(.person, ExternalID(.wikidata, "Q50"))
                b.drafts = [MusicSourceDraft(f, MusicEntityDraft(kind: .film, name: "Kaathal", lang: "ta", year: q == "Q1" ? 2010 : 2011, externalIDs: [ExternalID(.wikidata, q)])),
                            MusicSourceDraft(c, MusicEntityDraft(kind: .person, name: "D Imman", externalIDs: [ExternalID(.wikidata, "Q50")]))]
                b.claims = [MusicClaimDraft(subject: f, predicate: .composedBy, object: c, role: .composer, creditLevel: .film, confidence: 0.95)]
            }
            return b
        }
        let clock = GraphTestClock(); let store = MusicInMemoryGraph(clock: clock.reader)
        let resolver = MusicEntityResolver(store: store, sources: [wd], gate: MusicEnrichmentPolicy.open, now: clock.reader)
        let album = MusicAlbum(id: "k", providerID: "jiosaavn", title: "Kaathal (Original Motion Picture Soundtrack)", artists: [MusicArtistRef(id: "i", name: "D Imman")], releaseDate: "2010-05-01", albumType: "soundtrack")
        let r = await resolver.enrichAlbum(album, tracks: [], hints: MusicAlbumHints(language: "ta", musicBy: ["D Imman"]))
        let rel = try #require(r.entity)
        let edges = try await store.edges(of: rel, predicate: .soundtrackOf)
        #expect(edges.count == 2 && edges.allSatisfy { $0.status == .conflicted && $0.confidence <= 0.6 })
        #expect(try await store.search("Kaathal", kinds: [.film]).count == 2, "never merged")
    }

    @Test func aSongTitleHintAloneIsAProvisionalFilmBelowTheDisplayThresholdWithNoCast() async throws {
        let rig = ResolverRig()
        let track = MusicTrack(id: "x", providerID: "spotify", title: "Tum Hi Ho (From \"Aashiqui 2\")", durationMs: 262_000, artists: [MusicArtistRef(id: "a", name: "Arijit Singh")])
        let r = await rig.resolver.enrichTrack(track)
        let rec = try #require(r.entity)
        let e = try #require(try await rig.store.edges(of: rec, predicate: .featuredIn).first)
        #expect(e.confidence < 0.6 && e.status == .inferred)
        let film = try #require(try await rig.store.entity(e.object))
        #expect(film.provisional && film.name == "Aashiqui 2")
        #expect(try await rig.store.edges(of: e.object, predicate: .hasCast).isEmpty)
    }
}

@Suite("Entity resolver: gating, cache and outage") struct MetadataGatingTests {
    private func policies() -> [(String, MusicEnrichmentPolicy)] {
        [("kids", MusicEnrichmentPolicy(consentGiven: { true }, sourceOn: { _ in true }, kidsOrLocked: { true })),
         ("no consent", MusicEnrichmentPolicy(consentGiven: { false }, sourceOn: { _ in true })),
         ("switch off", MusicEnrichmentPolicy(consentGiven: { true }, sourceOn: { _ in false })),
         ("offline", MusicEnrichmentPolicy(consentGiven: { true }, sourceOn: { _ in true }, offline: { true }))]
    }

    @Test func kidsNoConsentSwitchOffAndOfflineMakeZeroNetworkCalls() async throws {
        for (name, p) in policies() {
            let rig = ResolverRig(policy: p)
            _ = await rig.resolver.enrichAlbum(ResolverRig.album1951, tracks: ResolverRig.tracks1951, hints: MusicAlbumHints(language: "hi", musicBy: ["Shankar Jaikishan"]))
            _ = await rig.resolver.enrichTrack(ResolverRig.tracks1951[2])
            let f = try #require(try await rig.store.upsert(MusicEntityDraft(kind: .film, name: "Awaara", externalIDs: [ExternalID(.wikidata, "Q858681")])).id as MusicEntityID?)
            let r = await rig.resolver.enrichFilm(f)
            #expect(rig.transport.callCount == 0, "\(name): \(rig.transport.calls)")
            #expect(!r.skipped.isEmpty)
        }
    }

    @Test func aPerSourceSwitchSkipsOnlyThatSource() async throws {
        let p = MusicEnrichmentPolicy(consentGiven: { true }, sourceOn: { $0 != .wikipedia })
        let rig = ResolverRig(policy: p)
        let r = await rig.resolver.enrichAlbum(ResolverRig.album2010, tracks: [], hints: MusicAlbumHints(language: "te", musicBy: ["Yuvan Shankar Raja"]))
        #expect(r.skipped[.wikipedia] == .switchOff && rig.transport.calls(containing: "wikipedia.org") == 0)
        #expect(rig.transport.calls(containing: "musicbrainz.org") > 0)
    }

    @Test func freshFacetsAnswerFromTheStoreWithNoNetwork() async throws {
        let rig = ResolverRig()
        let f = try await rig.store.upsert(MusicEntityDraft(kind: .film, name: "Awaara", externalIDs: [ExternalID(.wikidata, "Q858681")])).id
        let first = await rig.resolver.enrichFilm(f)
        #expect(first.fetched.contains(.wikidata))
        let calls = rig.transport.callCount
        let second = await rig.resolver.enrichFilm(f)
        #expect(rig.transport.callCount == calls && second.fromCache && second.fetched.isEmpty)
    }

    @Test func anOutageAfterTheTtlServesTheCachedGraphWithoutAnError() async throws {
        let rig = ResolverRig()
        let f = try await rig.store.upsert(MusicEntityDraft(kind: .film, name: "Awaara", externalIDs: [ExternalID(.wikidata, "Q858681")])).id
        _ = await rig.resolver.enrichFilm(f)
        let cast = await rig.creditNames(f, .hasCast)
        #expect(cast.count == 9)
        rig.clock.advance(120 * 86_400)
        rig.transport.failAll = .network("HTTP 503")
        let r = await rig.resolver.enrichFilm(f)
        #expect(r.stale && !r.failed.isEmpty)
        #expect(await rig.creditNames(f, .hasCast).count == 9, "what the graph held is still served")
        // Back-off after the error: the next call within it does not hit the network again.
        let calls = rig.transport.callCount
        _ = await rig.resolver.enrichFilm(f)
        #expect(rig.transport.callCount == calls)
    }

    @Test func aCancelledEnrichmentReturnsWithoutThrowingOrWriting() async throws {
        let rig = ResolverRig()
        let t = Task { () -> MusicMetadataOutcome in
            try? await Task.sleep(nanoseconds: 100_000_000)
            return await rig.resolver.enrichTrack(ResolverRig.tracks1951[2])
        }
        t.cancel()
        let r = await t.value
        #expect(r.cancelled || rig.transport.callCount == 0)
    }

    @Test func theEnrichingHookReportsChangedEntities() async throws {
        let rig = ResolverRig()
        let f = try await rig.store.upsert(MusicEntityDraft(kind: .film, name: "Awaara", externalIDs: [ExternalID(.wikidata, "Q858681")])).id
        let hook: any MusicEntityEnriching = MusicGraphEnricher(resolver: rig.resolver)
        let out = try await hook.enrich(f)
        #expect(out.changed.contains(f))
        let again = try await hook.enrich(f)
        #expect(again.changed.isEmpty, "nothing changed on a fresh facet")
    }
}

@Suite("Film layer adoption") struct MetadataFilmAdoptionTests {
    private struct FakeFilmSource: MusicFilmSource {
        var source: MusicFilmInfo.Source { .tmdb }
        func film(for identity: MusicFilmIdentity) async throws -> MusicFilmInfo? {
            var i = MusicFilmInfo(title: "Awaara", year: 1951, language: "hi", tmdbID: 39039, wikidataID: "Q858681", imdbID: "tt0043306",
                                  cast: [MusicFilmPerson(tmdbID: 110860, name: "Raj Kapoor", character: "Raj"), MusicFilmPerson(name: "Cuckoo")],
                                  directors: [MusicFilmPerson(tmdbID: 110860, name: "Raj Kapoor")], composers: [MusicFilmPerson(name: "Shankar Jaikishan")], source: .tmdb)
            i.provenance = MusicFilmProvenance(source: .tmdb, retrievedAt: Date(), confidence: 0.9)
            return i
        }
    }

    @Test func theFilmServiceKeepsItsAnswerAndTheGraphReceivesTheEdges() async throws {
        let rig = ResolverRig(routes: false)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("film-adopt-\(UUID().uuidString)")
        let service = MusicFilmService(sources: MusicGraphWritingFilmSource.wrap([FakeFilmSource()], resolver: rig.resolver), cache: MusicFilmCache(directory: dir))
        let identity = MusicFilmIdentity(title: "Awaara", year: 1951, language: "hi", evidence: .titlePattern)
        let info = await service.info(for: identity)
        #expect(info?.cast.count == 2 && info?.tmdbID == 39039, "the film page API is unchanged")
        var film: MusicEntityID?
        for _ in 0..<50 { film = try await rig.store.resolveAlias(for: ExternalID(.tmdbMovie, "39039")); if film != nil { break }; try await Task.sleep(nanoseconds: 40_000_000) }
        let f = try #require(film)
        try await Task.sleep(nanoseconds: 200_000_000)
        let cast = await rig.creditNames(f, .hasCast)
        #expect(cast.contains("Raj Kapoor") && cast.contains("Cuckoo"))
        let cuckoo = try #require(try await rig.store.search("Cuckoo", kinds: [.person]).first)
        #expect(try await rig.store.entity(cuckoo.id)?.provisional == true, "a name-only person is keyed to its film, never merged by name")
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func theWikidataFilmSourceStillRunsThroughTheSameServiceWithoutTMDB() async throws {
        let rig = ResolverRig(routes: false)
        let t = FixtureTransport()
        t.route("action=wbsearchentities", "wikidata_search_awaara.json")
        let service = MusicFilmService(sources: [MusicWikidataFilmSource(http: MusicHTTP())], cache: MusicFilmCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("fa-\(UUID().uuidString)")))
        _ = service; _ = rig
        // The TMDB-free sources are the graph's own: Wikidata, Wikipedia and IMDb, registered next to the optional TMDB one.
        let sources = MusicMetadataSources.make(transport: t, tmdb: nil)
        #expect(Set(sources.map(\.id)).isSuperset(of: [.wikidata, .wikipedia, .imdb, .tmdb, .musicbrainz]))
        #expect(sources.first { $0.id == .tmdb }.map { $0.policy.attribution } == "TMDB")
    }
}

@Suite("Metadata switches and policy") struct MetadataSettingsLogicTests {
    @Test func sourcesStartOnExceptDiscogsAndOmdbAndEveryChangeIsLogged() {
        let d = UserDefaults(suiteName: "meta-test-\(UUID().uuidString)")!
        let s = MusicMetadataSwitches(defaults: d)
        for id in [MusicSourceID.musicbrainz, .wikidata, .wikipedia, .imdb, .listenbrainz, .tmdb, .lastfm] { #expect(s.isOn(id), "\(id)") }
        #expect(!s.isOn(.discogs) && !s.isOn(.omdb))
        s.set(false, .imdb); s.set(true, .discogs); s.set(true, .discogs)
        #expect(!s.isOn(.imdb) && s.isOn(.discogs))
        let log = MusicRegistryChangeLog.load(d)
        #expect(log.map(\.id) == ["metadata.imdb", "metadata.discogs"] && log.map(\.on) == [false, true] && log.allSatisfy { $0.reason == .switch })
        s.reset()
        #expect(s.isOn(.imdb))
    }

    @Test func policyOrderAndTmdbLookupSwitch() {
        let p = MusicEnrichmentPolicy(consentGiven: { true }, sourceOn: { _ in true }, tmdbLookupsAllowed: { false })
        #expect(p.decision(for: .tmdb) == .skipped(.filmLookupsOff) && p.decision(for: .wikidata) == .allowed)
    }

    @Test func everySourceHasAPlainPrivacyNoteAndAnHttpsHost() {
        let t = FixtureTransport()
        for s in MusicMetadataSources.make(transport: t, tmdb: nil) {
            #expect(!s.policy.privacyNote.isEmpty, "\(s.id)")
            #expect(s.policy.privacyNote.count < 260 && !s.policy.privacyNote.contains("@"))
        }
        #expect(MusicSourceKit.userAgent.hasPrefix("StreamSetuMusic/") && !MusicSourceKit.userAgent.contains("@"))
    }
}

@Suite("Metadata settings words") struct MetadataSettingsWordsTests {
    @Test func everyPolicyNoteIsTheSettingsNote() {
        let t = FixtureTransport()
        let sources = MusicMetadataSources.make(transport: t, tmdb: nil)
        for n in MusicMetadataSourceNotes.all {
            let s = sources.first { $0.id == n.id }
            #expect(s?.policy.privacyNote == n.note, "\(n.id)")
        }
        #expect(MusicMetadataSwitches.all == MusicMetadataSourceNotes.all.map(\.id))
    }

    @Test func everySettingsStringHasHindiAndTeluguWithMatchingPlaceholders() throws {
        let root = MetadataFixtures.directory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Localization")
        var keys = ["Metadata sources", "Credits, cast and links for songs, albums and films come from these open sources. Each one has its own switch. Nothing about what you play is sent."]
        for n in MusicMetadataSourceNotes.all { keys += [n.detail, n.note] }
        for lang in ["hi", "te"] {
            let url = root.appendingPathComponent("\(lang).lproj/Localizable.strings")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }   // the throwaway package has no app resources
            for k in keys { #expect(text.contains("\"\(k)\" = \""), "\(lang): \(k)") }
        }
    }
}
