import Foundation
import Testing
@testable import REDDY

@Suite("Graph edge rules") struct GraphRulesTests {
    private func agg(_ p: MusicPredicate, _ facts: [MusicProvenance]) -> MusicEdgeAggregator.Result { MusicEdgeAggregator.aggregate(predicate: p, facts: facts) }
    private func claim(_ source: MusicSourceID, stated: Bool = false, score: Float? = nil, stance: Stance = .asserts) -> MusicProvenance {
        GraphTestSupport.claim(source, stated: stated, score: score, stance: stance)
    }

    @Test func soundtrackAndSongInFilmAreOnlyInferredUnlessASourceStatesThem() {
        for p in [MusicPredicate.soundtrackOf, .featuredIn] {
            #expect(agg(p, [claim(.matcher, score: 0.9)]).status == .inferred)
            #expect(agg(p, [claim(MusicSourceID("jiosaavn"), stated: true)]).status == .inferred, "a provider is not authoritative")
            #expect(agg(p, [claim(.musicbrainz)]).status == .inferred, "an authoritative source that does not state the link")
            #expect(agg(p, [claim(.wikidata, stated: true)]).status == .verified)
            #expect(agg(p, [claim(.tmdb, stated: true)]).status == .verified)
            #expect(agg(p, [claim(.user, stated: false, score: 1)]).status == .inferred)   // untagged user claim is a plain claim
            #expect(agg(p, [MusicProvenance(source: .user, license: .user, score: 1, userOverride: true)]).status == .verified)
        }
        #expect(agg(.performedBy, [claim(.musicbrainz)]).status == .verified)
        #expect(agg(.hasCast, [claim(.tmdb)]).status == .verified)
        #expect(agg(.performedBy, [claim(MusicSourceID("jiosaavn"))]).status == .inferred)
    }

    @Test func confidenceIsANoisyOrCappedBelowOneUnlessVerified() {
        let a = agg(.performedBy, [claim(.matcher, score: 0.5), claim(MusicSourceID("jiosaavn"), score: 0.5)])
        #expect(abs(a.confidence - 0.75) < 0.001 && a.status == .inferred)
        let capped = agg(.performedBy, [claim(.matcher, score: 0.99), claim(MusicSourceID("jiosaavn"), score: 0.99)])
        #expect(capped.confidence <= 0.99 && capped.status == .inferred)
        #expect(agg(.performedBy, [claim(.musicbrainz, score: 1)]).confidence == 1)
    }

    @Test func contradictionsFollowSourceRank() {
        // Equal rank: conflicted, both kept.
        let c = agg(.performedBy, [claim(.musicbrainz), claim(.wikidata, stance: .contradicts)])
        #expect(c.status == .conflicted && !c.tombstone && c.confidence <= 0.6)
        // A higher rank denial retracts; a lower rank denial is ignored.
        #expect(agg(.performedBy, [claim(MusicSourceID("jiosaavn")), claim(.musicbrainz, stance: .contradicts)]).tombstone)
        let ignored = agg(.performedBy, [claim(.musicbrainz), claim(.matcher, stance: .contradicts)])
        #expect(ignored.status == .verified && !ignored.tombstone)
        // The person beats everyone.
        let user = MusicProvenance(source: .user, license: .user, score: 1, stance: .contradicts, userOverride: true)
        #expect(agg(.performedBy, [claim(.musicbrainz), user]).tombstone)
    }

    @Test func expiredFactsStopCounting() {
        let past = MusicProvenance(source: .tmdb, retrievedAt: Date(timeIntervalSince1970: 0), expiresAt: Date(timeIntervalSince1970: 10))
        #expect(MusicEdgeAggregator.aggregate(predicate: .hasCast, facts: [past], now: Date(timeIntervalSince1970: 11)).confidence == 0)
    }

    @Test func predicateKindRules() {
        #expect(MusicPredicate.trackOn.accepts(subject: .recording, object: .release))
        #expect(MusicPredicate.soundtrackOf.accepts(subject: .album, object: .film))
        #expect(MusicPredicate.soundtrackOf.accepts(subject: .release, object: .series))
        #expect(!MusicPredicate.soundtrackOf.accepts(subject: .person, object: .film))
        #expect(MusicPredicate.hasCast.accepts(subject: .film, object: .person))
        #expect(!MusicPredicate.directedBy.accepts(subject: .recording, object: .person))
        #expect(MusicPredicate.hasCast.inverseLabel == "acts-in")
        #expect(MusicPredicate.soundtrackOf.inverseLabel == "film-has-soundtrack")
        #expect(MusicPredicate.trackOn.label == "track-on-album")
        #expect(MusicPredicate.allCases.count == Set(MusicPredicate.allCases.map(\.rawValue)).count)
    }

    @Test func twoSignalMergeRule() {
        typealias E = MusicMergeRule.Evidence
        // A shared strong id is enough.
        #expect(MusicMergeRule.decide(E(kind: .person, sharedStrongID: true)) == .merge)
        // Name alone never merges, however high.
        #expect(MusicMergeRule.decide(E(kind: .recording, signals: [.init(.name, 1.0)])) != .merge)
        // Two independent families at a combined 0.85 or more merge.
        #expect(MusicMergeRule.decide(E(kind: .recording, signals: [.init(.name, 0.8), .init(.duration, 0.8)])) == .merge)
        // Two weak signals stay a candidate.
        #expect(MusicMergeRule.decide(E(kind: .recording, signals: [.init(.name, 0.5), .init(.date, 0.5)])) == .probable)
        // A person needs two signals that are not the name.
        #expect(MusicMergeRule.decide(E(kind: .person, signals: [.init(.name, 0.99), .init(.creditOverlap, 0.9)])) != .merge)
        #expect(MusicMergeRule.decide(E(kind: .person, signals: [.init(.creditOverlap, 0.9), .init(.workOverlap, 0.9)])) == .merge)
        // Two signals of the SAME family do not count twice.
        #expect(MusicMergeRule.decide(E(kind: .recording, signals: [.init(.name, 0.9), .init(.name, 0.9)])) != .merge)
        // Any blocker rejects, even with a shared strong id.
        #expect(MusicMergeRule.decide(E(kind: .person, sharedStrongID: true, blockers: [.lifeYearsApart])) == .reject)
        #expect(MusicMergeRule.decide(E(kind: .film, signals: [])) == .reject)
    }

    @Test func mergeBlockersFromFields() {
        let ids1 = [ExternalID(.mbid, "A")], ids2 = [ExternalID(.mbid, "B")]
        #expect(MusicMergeRule.blockers(kind: .person, strongIDsA: ids1, strongIDsB: ids2, yearA: nil, yearB: nil, durationMsA: nil, durationMsB: nil).contains(.differentStrongIDSameScheme))
        #expect(MusicMergeRule.blockers(kind: .person, strongIDsA: ids1, strongIDsB: ids1, yearA: 1923, yearB: 1990, durationMsA: nil, durationMsB: nil) == [.lifeYearsApart])
        #expect(MusicMergeRule.blockers(kind: .film, strongIDsA: [], strongIDsB: [], yearA: 1951, yearB: 2010, durationMsA: nil, durationMsB: nil) == [.filmYearsApart])
        #expect(MusicMergeRule.blockers(kind: .film, strongIDsA: [], strongIDsB: [], yearA: 2010, yearB: 2011, durationMsA: nil, durationMsB: nil).isEmpty)
        #expect(MusicMergeRule.blockers(kind: .recording, strongIDsA: [], strongIDsB: [], yearA: nil, yearB: nil, durationMsA: 200_000, durationMsB: 300_000) == [.durationApart])
        #expect(MusicMergeRule.blockers(kind: .recording, strongIDsA: [], strongIDsB: [], yearA: nil, yearB: nil, durationMsA: 200_000, durationMsB: 300_000, hasVersionEdge: true).isEmpty)
        // Provider uids are many per item and never contradict.
        #expect(MusicMergeRule.blockers(kind: .recording, strongIDsA: [ExternalID(.provider, "a:1")], strongIDsB: [ExternalID(.provider, "b:2")], yearA: nil, yearB: nil, durationMsA: nil, durationMsB: nil).isEmpty)
    }

    @Test func roleQualifiedCreditsGroupByRole() {
        let song = MusicEntityID.derive(kind: .recording, aliasKey: "s"), p = MusicEntityID.derive(kind: .person, aliasKey: "p")
        let edges = [MusicEdge(subject: song, predicate: .composedBy, object: p, role: .composer), MusicEdge(subject: song, predicate: .performedBy, object: p, role: .singer),
                     MusicEdge(subject: song, predicate: .writtenBy, object: p, qualifier: "unknown-role")]
        let credits = MusicRoleCredits(edges: edges)
        #expect(credits.roles == [.singer, .composer])
        #expect(credits.edges(for: .composer).count == 1)
        #expect(edges[0].key != edges[1].key)
    }

    @Test func edgeAttributesTypedAccessors() {
        var a = EdgeAttributes()
        a.characterName = "Raj"; a.creditOrder = 2; a.versionKind = .remix; a.disc = 1; a.position = 4
        #expect(a.characterName == "Raj" && a.creditOrder == 2 && a.versionKind == .remix && a.disc == 1 && a.position == 4)
        a.creditOrder = nil
        #expect(a["creditOrder"] == nil)
    }

    @Test func typedNodesCheckTheKind() {
        let s = MusicEntitySnapshot(id: .derive(kind: .film, aliasKey: "f"), subkind: nil, name: "Awaara", nameLatin: "avara", lang: "hin", year: 1951, yearEnd: nil, country: nil, durationMs: nil,
                                    imageRef: nil, attrs: [:], provisional: false, state: .live, pinned: false, mergedInto: nil, createdAt: Date(), updatedAt: Date())
        #expect(MusicFilmNode(snapshot: s)?.year == 1951)
        #expect(MusicPersonNode(snapshot: s) == nil)
        var album = s; album.id = .derive(kind: .album, aliasKey: "a"); album.subkind = "soundtrack"
        #expect(MusicAlbumNode(snapshot: album)?.isSoundtrack == true)
    }
}
