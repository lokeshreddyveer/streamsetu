import Foundation
import Testing
@testable import REDDY

private typealias F = CreditsFixtures

@Suite("Credits to graph claims") struct CreditsAdapterTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func awaaraSong(_ i: Int = 0) throws -> MusicTrack { try #require(JioSaavnProvider.mapSong(F.songs("jiosaavn-album-awaara-1951.json")[i])) }

    private func edges(_ b: MusicCreditsBatch, _ p: MusicPredicate, role: MusicRole? = nil) -> [MusicEdgeClaim] {
        b.claims.filter { $0.edge.predicate == p && (role == nil || $0.edge.role == role) }
    }
    private func draft(_ b: MusicCreditsBatch, _ id: MusicEntityID) -> MusicEntityDraft? { b.drafts.first { $0.derivedID == id } }

    // MARK: edges, provenance, confidence

    @Test func songCreditsBecomeRoleQualifiedEdgesWithProvenance() throws {
        let t = try awaaraSong()
        let b = MusicCreditsAdapter.batch(track: t, now: now)
        let rec = MusicEntityID.provisional(kind: .recording, providerUID: t.uid)

        let lyric = try #require(edges(b, .writtenBy, role: .lyricist).first)
        #expect(lyric.edge.subject == rec && lyric.edge.creditLevel == .song)
        #expect(draft(b, lyric.edge.object)?.name == "Shailendra" && draft(b, lyric.edge.object)?.kind == .person)
        #expect(abs(lyric.edge.confidence - 0.9) < 0.001)
        let p = lyric.provenance
        #expect(p.source == MusicSourceID("jiosaavn") && p.sourceRef == t.uid && p.license == .providerCache && p.retrievedAt == now)
        #expect(p.expiresAt == now.addingTimeInterval(14 * 86_400) && p.stance == .asserts && !p.statesLink)

        #expect(edges(b, .performedBy, role: .singer).count == 1)
        #expect(edges(b, .musicDirectedBy, role: .musicDirector).count == 1)
        #expect(edges(b, .performedBy, role: .performer).count == 2, "both primary artists")
        // Every claim is allowed by the predicate catalogue, so the store accepts them all.
        #expect(b.claims.allSatisfy { $0.edge.predicate.accepts(subject: $0.edge.subject.kind, object: $0.edge.object.kind) })
    }

    @Test func filmLevelCastIsLowerConfidenceAndTaggedFilmCredit() throws {
        let t = try awaaraSong()
        let b = MusicCreditsAdapter.batch(track: t, now: now)
        let cast = edges(b, .hasCast, role: .actor)
        #expect(cast.count == 4)
        for c in cast {
            #expect(c.edge.subject.kind == .film && c.edge.creditLevel == .film && abs(c.edge.confidence - 0.6) < 0.001)
            #expect(c.provenance.evidence.contains("film credit"))
        }
    }

    @Test func confidenceFollowsTheCreditLevel() {
        #expect(MusicCreditsAdapter.confidence(for: .track) == 0.9)
        #expect(MusicCreditsAdapter.confidence(for: .album) == 0.8)
        #expect(MusicCreditsAdapter.confidence(for: .film) == 0.6)
        var a = MusicAlbum(id: "al", providerID: "x", title: "Album")
        a.credits = [MusicCredit(name: "Maker", role: .primary, providerArtistID: "m1", level: .album)]
        let b = MusicCreditsAdapter.batch(album: a, tracks: [], now: now)
        let e = edges(b, .performedBy).first
        #expect(e?.edge.creditLevel == .album && abs((e?.edge.confidence ?? 0) - 0.8) < 0.001 && e?.edge.subject == MusicEntityID.provisional(kind: .release, providerUID: a.uid))
    }

    @Test func noCreditsMeansNoInventedCredits() {
        let t = MusicTrack(id: "p1", providerID: "somewhere", title: "Plain Song", durationMs: 1000, artists: [MusicArtistRef(id: "a1", name: "Solo")])
        let b = MusicCreditsAdapter.batch(track: t, now: now)
        // Only what the provider's artist list already said (G1's performer claim); no composer, lyricist, cast or film.
        #expect(b.claims.map(\.edge.predicate) == [.performedBy])
        #expect(b.claims[0].edge.role == .performer && abs(b.claims[0].edge.confidence - 0.6) < 0.001)
        #expect(!b.drafts.contains { $0.kind == .film })
    }

    @Test func creditsReplaceTheBareArtistClaimInsteadOfDoublingIt() throws {
        let t = try awaaraSong()
        let b = MusicCreditsAdapter.batch(track: t, now: now)
        let primary = edges(b, .performedBy, role: .performer)
        let shamshad = try #require(primary.first { draft(b, $0.edge.object)?.name == "Shamshad Begum" })
        #expect(abs(shamshad.edge.confidence - 0.9) < 0.001, "the credit's 0.9, not the artist list's 0.6")
        let duo = try #require(primary.first { draft(b, $0.edge.object)?.name == "Shankar-Jaikishan" })
        #expect(duo.edge.confidence <= 0.45 && duo.edge.object.kind == .group, "a hyphenated duo is only a group candidate")
    }

    // MARK: people are never merged by name

    @Test func identicalNamesWithDifferentProviderIDsStaySeparatePersons() {
        let t = MusicTrack(id: "p1", providerID: "jiosaavn", title: "Song", durationMs: 1000, artists: [])
        var one = t; one.credits = [MusicCredit(name: "Anil Kumar", role: .lyricist, providerArtistID: "111")]
        var two = t; two.id = "p2"; two.credits = [MusicCredit(name: "Anil Kumar", role: .lyricist, providerArtistID: "222")]
        let a = edges(MusicCreditsAdapter.batch(track: one, now: now), .writtenBy)[0].edge.object
        let b = edges(MusicCreditsAdapter.batch(track: two, now: now), .writtenBy)[0].edge.object
        #expect(a != b)
        #expect(a == MusicEntityID.provisional(kind: .person, providerUID: "jiosaavn:111"))
    }

    @Test func aProviderIDIsTheAliasAndASamePersonKeepsOneEntityAcrossRoles() throws {
        let t = try awaaraSong()
        let b = MusicCreditsAdapter.batch(track: t, now: now)
        let ids = b.claims.filter { $0.edge.object.kind == .group || $0.edge.object.kind == .person }.map(\.edge.object)
        // Shankar-Jaikishan is a primary artist AND the music director: two edges, one entity.
        let sj = b.drafts.filter { $0.name == "Shankar-Jaikishan" }
        #expect(sj.count == 1 && sj[0].externalIDs == [ExternalID(.provider, "jiosaavn:456076")])
        #expect(Set(ids).count == b.drafts.filter { $0.kind != .recording && $0.kind != .release && $0.kind != .film }.count)
    }

    @Test func nameOnlyCreditsAreRoleQualifiedAndNeverShareAnEntityAcrossRoles() {
        var t = MusicTrack(id: "p1", providerID: "local", title: "Song", durationMs: 1000, artists: [])
        t.credits = [MusicCredit(name: "Same Name", role: .composer), MusicCredit(name: "Same Name", role: .lyricist)]
        let b = MusicCreditsAdapter.batch(track: t, now: now)
        let c = edges(b, .composedBy)[0].edge.object, l = edges(b, .writtenBy)[0].edge.object
        #expect(c != l, "a singer and a composer of one name are not assumed to be one person")
        #expect(draft(b, c)?.provisional == true && draft(b, c)?.attrs["credited"] == "name only")
    }

    // MARK: duos and groups

    @Test func hyphenatedDuoIsAGroupCandidateAtLowConfidence() throws {
        for name in ["Shankar-Jaikishan", "Shankar–Jaikishan", "Vishal-Shekhar", "Shankar - Jaikishan"] {
            #expect(MusicCreditsAdapter.isDuoName(name), "\(name)")
        }
        for name in ["Jay-Z", "Arijit Singh", "A. R. Rahman", "Lata Mangeshkar", "Anirudh"] { #expect(!MusicCreditsAdapter.isDuoName(name), "\(name)") }
        var t = MusicTrack(id: "p1", providerID: "x", title: "Song", durationMs: 1000, artists: [])
        t.credits = [MusicCredit(name: "Vishal-Shekhar", role: .music)]
        let b = MusicCreditsAdapter.batch(track: t, now: now)
        let e = try #require(edges(b, .musicDirectedBy).first)
        #expect(e.edge.object.kind == .group && e.edge.confidence <= 0.45)
        #expect(e.provenance.evidence.contains("group-candidate") && draft(b, e.edge.object)?.attrs["groupCandidate"] == "1")
        #expect(edges(b, .memberOf).isEmpty, "no member edges unless a source listed the members")
    }

    @Test func membersListedBySourceBecomeMemberEdges() {
        var t = MusicTrack(id: "p1", providerID: "x", title: "Song", durationMs: 1000, artists: [])
        t.credits = [MusicCredit(name: "Shankar-Jaikishan", role: .music, providerArtistID: "g1",
                                 members: [MusicCredit(name: "Shankar", role: .music, providerArtistID: "m1"), MusicCredit(name: "Jaikishan", role: .music, providerArtistID: "m2")])]
        let b = MusicCreditsAdapter.batch(track: t, now: now)
        #expect(edges(b, .memberOf).count == 2)
        let e = edges(b, .musicDirectedBy)[0]
        #expect(e.edge.object.kind == .group && abs(e.edge.confidence - 0.9) < 0.001, "a group with listed members is not a mere candidate")
        #expect(edges(b, .memberOf).allSatisfy { $0.edge.object == e.edge.object && $0.edge.subject.kind == .person })
    }

    // MARK: version typing

    @Test func versionHintsComeFromTitlePatternsAndProviderFlags() {
        func kind(_ title: String, _ hints: MusicProviderHints? = nil) -> MusicVersionKind? { MusicCreditsAdapter.versionHint(title: title, hints: hints)?.kind }
        #expect(kind("Tum Hi Ho (Cover)") == .cover)
        #expect(kind("Kun Faya Kun - Remix") == .remix && kind("Song (DJ Name Remix)") == .remix)
        #expect(kind("Hotel California (Live at Hampton)") == .live && kind("Song - Live") == .live)
        #expect(kind("Kaavaalaa (Karaoke Version)") == .karaoke)
        #expect(kind("Kaavaalaa (Originally Performed by A, B) (Karaoke Version)") == .karaoke, "karaoke wins over originally-performed")
        #expect(kind("Tere Bina (Reprise)") == .reprise)
        #expect(kind("Song (Unplugged)") == .acoustic)
        #expect(kind("Awara Hoon (Re-recorded)") == .reRecording)
        #expect(kind("Plain Title") == nil && kind("Live and Let Die") == nil && kind("Discover Me") == nil)
        #expect(kind("Plain Title", MusicProviderHints(version: "remix")) == .remix, "Audius flag")
        #expect(kind("Plain Title", MusicProviderHints(version: "cover")) == .cover)
    }

    @Test func theRecordingDraftCarriesTheVersionHint() throws {
        let raw = F.json("deezer-track-kaavaalaa-karaoke.json")
        var t = MusicTrack(id: "2385199085", providerID: "discover-deezer", title: raw.str("title") ?? "", durationMs: 185_000, artists: [MusicArtistRef(id: "63495032", name: "Backing Business")])
        t.creditBundle = DeezerCreditMapper.trackBundle(raw)
        let b = MusicCreditsAdapter.batch(track: t, now: now)
        let rec = try #require(b.drafts.first { $0.kind == .recording })
        #expect(rec.attrs["versionKind"] == "karaoke" && rec.attrs["versionEvidence"] == "title-karaoke")
        #expect(edges(b, .featuredIn).count == 1, "the title says From \"Jailer\"")
        #expect(edges(b, .featuredIn)[0].edge.confidence <= 0.4)
    }

    // MARK: soundtrack inference

    @Test func soundtrackLinkIsAlwaysInferredWithItsEvidence() throws {
        let h = try #require(MusicCreditsAdapter.soundtrackHint(albumTitle: "Jailer 2 (Original Motion Picture Soundtrack)"))
        #expect(h.film == "Jailer 2" && h.evidence == ["title-soundtrack"])
        #expect(MusicCreditsAdapter.soundtrackHint(albumTitle: "Squid Game OST")?.film == "Squid Game")
        #expect(MusicCreditsAdapter.soundtrackHint(albumTitle: "Awara (The Bollywood Soundtrack)")?.film == "Awara")
        #expect(MusicCreditsAdapter.soundtrackHint(albumTitle: "Kaavaali (From \"Jailer\")")?.film == "Jailer")
        #expect(MusicCreditsAdapter.soundtrackHint(albumTitle: "Greatest Hits") == nil)
        let g = MusicCreditsAdapter.soundtrackHint(albumTitle: "Awaara", hints: MusicProviderHints(genre: "Soundtrack"))
        #expect(g?.film == "Awaara" && g?.evidence == ["genre-soundtrack"])
        let strong = try #require(MusicCreditsAdapter.soundtrackHint(albumTitle: "Jailer (Original Motion Picture Soundtrack)", hints: MusicProviderHints(genre: "Soundtrack"), hasStarring: true))
        #expect(strong.confidence <= 0.75 && strong.confidence > g!.confidence)
    }

    @Test func albumIngestMakesAnInferredSoundtrackEdgeFromTheCastCredits() throws {
        let a = try #require(JioSaavnProvider.mapAlbum(F.json("jiosaavn-album-awaara-1951.json")))
        let tracks = F.songs("jiosaavn-album-awaara-1951.json").compactMap(JioSaavnProvider.mapSong)
        let b = MusicCreditsAdapter.batch(album: a, tracks: tracks, now: now)
        let s = try #require(edges(b, .soundtrackOf).first)
        #expect(s.edge.subject == MusicEntityID.provisional(kind: .release, providerUID: a.uid))
        #expect(draft(b, s.edge.object)?.name == "Awaara" && draft(b, s.edge.object)?.kind == .film)
        #expect(s.provenance.evidence == ["starring-credits"] && !s.provenance.statesLink)
        #expect(s.edge.confidence < 0.6)
        // The film's cast appears once, even though every song and the album carry it.
        #expect(edges(b, .hasCast).count == 4)
        // Each song keeps its own lyricist.
        #expect(Set(edges(b, .writtenBy, role: .lyricist).map { draft(b, $0.edge.object)?.name ?? "" }) == ["Shailendra", "Hasrat Jaipuri"])
        #expect(edges(b, .trackOn).count == 3)
    }

    @Test func soundtrackLinkNeverBecomesVerifiedInTheStore() async throws {
        let a = try #require(JioSaavnProvider.mapAlbum(F.json("jiosaavn-album-awaara-1951.json")))
        let tracks = F.songs("jiosaavn-album-awaara-1951.json").compactMap(JioSaavnProvider.mapSong)
        let store = MusicInMemoryGraph()
        try await MusicCreditsAdapter.commit(MusicCreditsAdapter.batch(album: a, tracks: tracks, now: Date()), to: store)
        let release = MusicEntityID.provisional(kind: .release, providerUID: a.uid)
        let s = try #require(try await store.edges(of: release, predicate: .soundtrackOf).first)
        #expect(s.status == .inferred)
        let credits = try await store.edges(of: MusicEntityID.provisional(kind: .recording, providerUID: tracks[1].uid), predicate: .writtenBy)
        #expect(credits.count == 1 && credits[0].role == .lyricist && credits[0].status == .inferred, "a provider cannot verify a credit")
        let cast = try await store.edges(of: s.object, predicate: .hasCast)
        #expect(cast.count == 4 && cast.allSatisfy { $0.creditLevel == .film })
    }

    @Test func twoFilmsOfOneTitleStaySeparate() {
        func film(_ year: Int, _ lang: String) -> MusicEntityID? {
            var a = MusicAlbum(id: "al\(year)", providerID: "jiosaavn", title: "Awaara (Original Motion Picture Soundtrack)")
            a.hints = MusicProviderHints(year: year, language: lang)
            return edges(MusicCreditsAdapter.batch(album: a, tracks: [], now: now), .soundtrackOf).first?.edge.object
        }
        #expect(film(1951, "hindi") != film(2010, "telugu"))
        #expect(film(1951, "hindi") == film(1951, "hindi"))
    }

    // MARK: store round trip

    @Test func commitWritesCreditsAndAnOldGraphReadsThemBack() async throws {
        let t = try awaaraSong(1)
        let store = MusicInMemoryGraph()
        try await MusicCreditsAdapter.commit(MusicCreditsAdapter.batch(track: t, now: Date()), to: store)
        let rec = MusicEntityID.provisional(kind: .recording, providerUID: t.uid)
        let snap = try #require(try await store.entity(rec))
        #expect(snap.name == "Awara Hoon")
        let singers = try await store.edges(of: rec, predicate: .performedBy).filter { $0.role == .singer }
        #expect(singers.count == 1)
        let name = try await store.entity(singers[0].object)?.name
        #expect(name == "Mukesh")
        // Committing again changes nothing (idempotent claims).
        let before = try await store.counts()
        try await MusicCreditsAdapter.commit(MusicCreditsAdapter.batch(track: t, now: Date()), to: store)
        let after = try await store.counts()
        #expect(before.entities == after.entities && before.edges == after.edges)
    }
}
