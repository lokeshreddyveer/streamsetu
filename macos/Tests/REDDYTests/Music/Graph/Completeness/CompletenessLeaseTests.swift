import Foundation
import Testing
@testable import REDDY

@MainActor
@Suite("Completeness: it lives and dies with the entity model's lease") struct CompletenessLeaseTests {
    typealias F = CompletenessFixtures

    private final class Recorder: MusicEntityCompleting {
        var began: [MusicEntityID] = [], ended: [MusicEntityID] = []
        func begin(_ id: MusicEntityID) { began.append(id) }
        func end(_ id: MusicEntityID) { ended.append(id) }
    }

    @Test func oneRunPerEntityHoweverManyViewsAndCancelledWhenTheModelIsDropped() async throws {
        let g = MusicInMemoryGraph()
        let p = try await g.upsert(MusicEntityDraft(kind: .person, name: "Anirudh", externalIDs: [ExternalID(.canon, "p|a")])).id
        let store = MusicEntityStore(graph: g)
        let rec = Recorder()
        let center = MusicEntityModelCenter(store: store, graceWindow: .milliseconds(20), sleeper: { try await Task.sleep(for: $0) })
        center.completeness = rec
        let a = center.acquire(p), b = center.acquire(p)
        #expect(rec.began == [p], "two views, one run")
        a.release(); #expect(rec.ended.isEmpty)
        b.release(); #expect(rec.ended.isEmpty, "inside the grace window the run continues")
        try await Task.sleep(for: .milliseconds(120))
        #expect(rec.ended == [p], "after the grace window the run is cancelled")
        let c = center.acquire(p)
        #expect(rec.began == [p, p], "a new model starts a new run (stages that are still fresh cost nothing)")
        c.release()
    }

    @Test func theCoordinatorRunsOnceAnnouncesAndStopsOnEnd() async throws {
        let g = MusicInMemoryGraph()
        let t = CompletenessTransport()
        t.add("action=wbsearchentities", F.data("{\"search\":[]}"))
        t.add("query.wikidata.org", F.sparql([]))
        t.hold = true
        let p = try await g.upsert(MusicEntityDraft(kind: .person, name: "Nobody Known", externalIDs: [ExternalID(.canon, "p|n")])).id
        let pass = MusicPersonCompleteness(resolver: MusicEntityResolver(store: g, sources: []), transport: t)
        let tracker = MusicCompletenessTracker()
        let coord = MusicEntityCompletenessCoordinator(pass: pass, tracker: tracker) { _ in }
        coord.begin(p); coord.begin(p)
        #expect(coord.started == 1 && tracker.isRunning(p))
        try await Task.sleep(for: .milliseconds(40))
        coord.end(p)
        t.hold = false
        #expect(!tracker.isRunning(p))
        try await Task.sleep(for: .milliseconds(60))
        #expect(!tracker.isRunning(p), "a cancelled run never reports itself as running or done")
        #expect(tracker.state(p) == .idle)
    }

    @Test func songsAndPlaylistsAreIgnored() {
        #expect(!MusicEntityCompletenessCoordinator.handles(.recording) && !MusicEntityCompletenessCoordinator.handles(.playlist))
        #expect(MusicEntityCompletenessCoordinator.handles(.person) && MusicEntityCompletenessCoordinator.handles(.film) && MusicEntityCompletenessCoordinator.handles(.release))
    }
}
