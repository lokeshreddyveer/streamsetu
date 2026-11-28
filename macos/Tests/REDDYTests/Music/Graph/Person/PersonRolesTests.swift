import Foundation
import Testing
@testable import REDDY

@Suite struct PersonRolesTests {
    private func summary(_ w: PersonWorld, _ id: MusicEntityID) async throws -> MusicPersonRoleSummary {
        MusicPersonRoles.summarize(incoming: try await w.store.edges(of: id, predicate: nil, direction: .incoming, limit: 500))
    }

    @Test func rajKapoorIsActorAndDirectorAndProducerOnlyFromEdges() async throws {
        let w = try await PersonWorld.make()
        let s = try await summary(w, w.raj)
        #expect(s.views.map(\.view).sorted { $0.priority < $1.priority } == [.actor, .director, .producer])
        #expect(s.summary(.actor)?.count == 4 && s.summary(.director)?.count == 4)
        #expect(s.extras.isEmpty && s.has(.producer))
        #expect(!s.has(.singer) && !s.has(.composer) && !s.has(.lyricist))
        #expect(s.needsSwitcher)
    }

    @Test func singersAreNotActorsAndActorsAreNotSingers() async throws {
        let w = try await PersonWorld.make()
        let mukesh = try await summary(w, w.mukesh)
        #expect(mukesh.views.map(\.view) == [.singer] && !mukesh.needsSwitcher && mukesh.views[0].label == .singer)
        let nargis = try await summary(w, w.nargis)
        #expect(nargis.views.map(\.view) == [.actor] && nargis.extras.isEmpty)
        #expect(!nargis.has(.singer))
    }

    @Test func personWhoIsBothActorAndSingerGetsBothViews() async throws {
        let w = try await PersonWorld.make()
        let s = try await summary(w, w.kishore)
        #expect(Set(s.views.map(\.view)) == [.actor, .singer])
        // equal counts: the owner's order breaks the tie (singer before actor)
        #expect(s.views.map(\.view) == [.singer, .actor])
    }

    @Test func lyricistAndGroupComposer() async throws {
        let w = try await PersonWorld.make()
        #expect(try await summary(w, w.shailendra).views.map(\.view) == [.lyricist])
        let sj = try await summary(w, w.sj)
        #expect(Set(sj.views.map(\.view)) == [.composer])
        #expect(sj.summary(.composer)?.count == 9)
    }

    @Test func personWithNoEdgesHasNoRoles() async throws {
        let w = try await PersonWorld.make()
        let s = try await summary(w, w.nobody)
        #expect(s.isEmpty && !s.needsSwitcher)
    }

    @Test func mismatchedAndWeakEdgesDoNotCount() {
        let a = MusicEntityID.derive(kind: .film, aliasKey: "a"), p = MusicEntityID.derive(kind: .person, aliasKey: "p")
        let wrongRole = MusicEdge(subject: a, predicate: .performedBy, object: p, qualifier: "actor", confidence: 0.9, status: .verified)
        #expect(MusicPersonRoles.effectiveRole(wrongRole) == nil && !MusicPersonRoles.counts(wrongRole))
        let weak = MusicEdge(subject: a, predicate: .hasCast, object: p, qualifier: "actor", confidence: 0.2, status: .inferred)
        #expect(!MusicPersonRoles.counts(weak))
        var tomb = MusicEdge(subject: a, predicate: .hasCast, object: p, qualifier: "actor", confidence: 0.9, status: .verified); tomb.tombstone = true
        #expect(!MusicPersonRoles.counts(tomb))
        let bare = MusicEdge(subject: a, predicate: .directedBy, object: p, qualifier: "", confidence: 0.9, status: .verified)
        #expect(MusicPersonRoles.effectiveRole(bare) == .director)
        let junk = MusicEdge(subject: a, predicate: .directedBy, object: p, qualifier: "singer", confidence: 0.9, status: .verified)
        #expect(MusicPersonRoles.effectiveRole(junk) == nil)
    }

    @Test func providerPerformerWithoutSingerRoleIsLabelledArtist() {
        let r = MusicEntityID.derive(kind: .recording, aliasKey: "r"), p = MusicEntityID.derive(kind: .person, aliasKey: "p")
        let e = MusicEdge(subject: r, predicate: .performedBy, object: p, qualifier: "performer", confidence: 0.6, status: .inferred)
        let s = MusicPersonRoles.summarize(incoming: [e])
        #expect(s.views.map(\.view) == [.singer] && s.views[0].label == .artist)
    }

    @Test func initialViewFollowsMemoryThenHintThenMostCredits() async throws {
        let w = try await PersonWorld.make()
        let s = try await summary(w, w.raj)
        #expect(MusicPersonRoles.initialView(summary: s, remembered: "director", hint: .actor) == .director)
        #expect(MusicPersonRoles.initialView(summary: s, remembered: nil, hint: .director) == .director)
        #expect(MusicPersonRoles.initialView(summary: s, remembered: nil, hint: .singer) == .actor)   // no singer edges: the hint is not honoured once edges are known
        #expect(MusicPersonRoles.initialView(summary: s, remembered: "singer", hint: nil) == .actor)  // remembered role the person does not have
        #expect(MusicPersonRoles.initialView(summary: .empty, remembered: nil, hint: .actor, loaded: false) == .actor)   // nothing loaded yet: hold the hint
        #expect(MusicPersonRoles.initialView(summary: .empty, remembered: nil, hint: .actor, loaded: true) == nil)
    }
}
