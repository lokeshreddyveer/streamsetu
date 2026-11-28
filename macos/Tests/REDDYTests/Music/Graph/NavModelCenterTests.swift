import Foundation
import Testing
@testable import REDDY

/// Counts calls from any thread.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    func set() { lock.withLock { v = true } }
    var isSet: Bool { lock.withLock { v } }
}

private struct CountingEnricher: MusicEntityEnriching {
    let albums: Counter
    var changes: Set<MusicEntityID> = []
    func enrichAlbum(_ id: MusicEntityID) async throws -> MusicEnrichmentResult { albums.bump(); return MusicEnrichmentResult(changed: changes) }
}

private struct GatedEnricher: MusicEntityEnriching {
    let gate: AsyncStream<Void>
    func enrichAlbum(_ id: MusicEntityID) async throws -> MusicEnrichmentResult {
        for await _ in gate { break }
        return MusicEnrichmentResult(changed: [])
    }
}

@MainActor
private func waitUntil(_ timeout: Duration = .seconds(3), _ cond: @MainActor () -> Bool) async -> Bool {
    let end = ContinuousClock.now + timeout
    while ContinuousClock.now < end {
        if cond() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return cond()
}

@MainActor
@Suite("Music graph navigation: entity store, shared models, sections") struct NavModelCenterTests {
    private func makeStore(enricher: any MusicEntityEnriching = MusicNoopEntityEnricher()) -> (MusicEntityStore, MusicInMemoryGraph) {
        let g = MusicInMemoryGraph()
        return (MusicEntityStore(graph: g, enricher: enricher), g)
    }

    private func mintAlbum(_ g: MusicInMemoryGraph, uid: String = "p:album1", provisional: Bool = false) async throws -> MusicEntityID {
        try await g.upsert(MusicEntityDraft(kind: .album, name: "Awaara", year: 1951, externalIDs: [ExternalID(.provider, uid)], provisional: provisional)).id
    }

    // MARK: open by id

    @Test func openByIdFindsTheRowAndCachesIt() async throws {
        let (store, g) = makeStore()
        let id = try await mintAlbum(g)
        guard case .found(let s) = await store.load(id) else { Issue.record("not found"); return }
        #expect(s.name == "Awaara")
        #expect(store.snapshot(id)?.name == "Awaara")
        let reads = store.graphReads
        _ = await store.load(id)
        #expect(store.graphReads == reads)
    }

    @Test func aMissingIdIsMissingNotAnError() async {
        let (store, _) = makeStore()
        #expect(await store.load(.provisional(kind: .film, providerUID: "p:none")) == .missing)
    }

    @Test func theFetchHookMintsAMissingProvisionalEntity() async {
        let (store, _) = makeStore()
        let id = MusicEntityID.provisional(kind: .film, providerUID: "p:f")
        store.fetchMissing = { want in
            MusicEntitySnapshot(id: want, subkind: nil, name: "Fetched", nameLatin: "fetched", lang: nil, year: nil, yearEnd: nil, country: nil, durationMs: nil, imageRef: nil,
                                attrs: [:], provisional: true, state: .live, pinned: false, mergedInto: nil, createdAt: Date(), updatedAt: Date())
        }
        guard case .found(let s) = await store.load(id) else { Issue.record("not found"); return }
        #expect(s.name == "Fetched")
    }

    @Test func aProvisionalIdFollowsAMergeToTheSurvivor() async throws {
        let (store, g) = makeStore()
        let loser = try await mintAlbum(g, uid: "p:a")
        let winner = try await g.upsert(MusicEntityDraft(kind: .album, name: "Awaara", externalIDs: [ExternalID(.mbReleaseGroup, "rg-1")])).id
        _ = try await g.mergeEntities(winner: winner, loser: loser, byUser: false)
        guard case .found(let s) = await store.load(loser) else { Issue.record("not found"); return }
        #expect(s.id == winner)
        #expect(store.canonical(loser) == winner)
        #expect(store.snapshot(loser)?.id == winner)
    }

    @Test func theCacheIsBounded() async throws {
        let (store0, g) = makeStore()
        let store = MusicEntityStore(graph: g, capacity: 8)
        _ = store0
        for i in 0..<30 { let id = try await mintAlbum(g, uid: "p:\(i)"); _ = await store.load(id) }
        #expect(store.cachedCount <= 8)
    }

    // MARK: changes

    @Test func changesReachSubscribersAndDropCachedRows() async throws {
        let (store, g) = makeStore()
        let id = try await mintAlbum(g)
        _ = await store.load(id)
        let stream = store.changes()
        var it = stream.makeAsyncIterator()
        store.notifyChanged([id])
        let change = await it.next()
        #expect(change?.ids == [id])
        #expect(store.snapshot(id) == nil)
        #expect(store.revision == 1)
    }

    @Test func enrichmentRunsOnceAndAnnouncesItsChanges() async throws {
        let counter = Counter()
        let (store, g) = makeStore()
        let id = try await mintAlbum(g, provisional: true)
        store.enricher = CountingEnricher(albums: counter, changes: [id])
        let stream = store.changes(); var it = stream.makeAsyncIterator()
        let t1 = store.enrich(id), t2 = store.enrich(id)
        await t1.value; await t2.value
        #expect(counter.value == 1)
        #expect(store.enrichmentRuns == 1)
        #expect(await it.next()?.ids == [id])
        #expect(try await MusicNoopEntityEnricher().enrich(id) == .none)
    }

    // MARK: shared models

    @Test func twoViewsShareOneModelAndOneRowLoad() async throws {
        let (store, g) = makeStore()
        let id = try await mintAlbum(g)
        let center = MusicEntityModelCenter(store: store, graceWindow: .seconds(60))
        let a = center.acquire(id), b = center.acquire(id)
        #expect(a.model === b.model)
        #expect(center.leaseCount(id) == 2)
        #expect(await waitUntil { a.model.phase == .loaded })
        #expect(a.model.snapshotLoads == 1)
        #expect(store.graphReads == 1)
        #expect(a.model.node(MusicAlbumNode.self)?.name == "Awaara")
        #expect(a.model.node(MusicFilmNode.self) == nil)
    }

    @Test func aSectionLoadsOnceHoweverManyViewsAsk() async throws {
        let (store, g) = makeStore()
        let id = try await mintAlbum(g)
        let center = MusicEntityModelCenter(store: store, graceWindow: .seconds(60))
        let page = center.acquire(id), related = center.acquire(id)
        let runs = Counter()
        let gate = AsyncStream<Void>.makeStream()
        let loader = MusicClosureSectionLoader(key: "moreByComposers") { _, _, _ in
            runs.bump()
            for await _ in gate.stream { break }
            return MusicSectionResult(items: ["a", "b"], provenance: [MusicSectionProvenance(source: .musicbrainz)], explanation: "Same composer")
        }
        page.model.load(loader); related.model.load(loader); page.model.load(loader)
        #expect(page.model.section("moreByComposers").phase == .loading)
        gate.continuation.yield()
        #expect(await waitUntil { page.model.section("moreByComposers").phase == .loaded })
        #expect(runs.value == 1)
        #expect(page.model.sectionRuns["moreByComposers"] == 1)
        #expect(related.model.section("moreByComposers").items(String.self) == ["a", "b"])
        #expect(page.model.section("moreByComposers").explanation == "Same composer")
        // loaded: asking again does not rerun; force does
        page.model.load(loader)
        #expect(runs.value == 1)
    }

    @Test func partialItemsShowBeforeTheSectionFinishes() async throws {
        let (store, g) = makeStore()
        let id = try await mintAlbum(g)
        let center = MusicEntityModelCenter(store: store, graceWindow: .seconds(60))
        let lease = center.acquire(id)
        let gate = AsyncStream<Void>.makeStream()
        lease.model.load(MusicClosureSectionLoader(key: "cast") { _, _, report in
            await report.partial(MusicSectionResult(items: ["lead"]))
            for await _ in gate.stream { break }
            return MusicSectionResult(items: ["lead", "support"])
        })
        #expect(await waitUntil { lease.model.section("cast").phase == .partial })
        #expect(lease.model.section("cast").items(String.self) == ["lead"])
        gate.continuation.yield()
        #expect(await waitUntil { lease.model.section("cast").phase == .loaded })
        #expect(lease.model.section("cast").items(String.self) == ["lead", "support"])
    }

    @Test func anEntityIsWorkingWhileItsBackgroundEnrichmentRuns() async throws {
        let gate = AsyncStream<Void>.makeStream()
        let (store, g) = makeStore(enricher: GatedEnricher(gate: gate.stream))
        let id = try await mintAlbum(g)
        let center = MusicEntityModelCenter(store: store, graceWindow: .seconds(60))
        let m = center.acquire(id).model
        #expect(await waitUntil { m.phase == .loaded || m.phase == .partial })
        #expect(await waitUntil { m.enriching })
        #expect(m.isWorking, "a page must not say 'nothing found' while enrichment may still add it")
        gate.continuation.yield()
        #expect(await waitUntil { !m.isWorking })
    }

    @Test func aForcedReloadIgnoresFirstStagePartialsSoThePageDoesNotShrink() async throws {
        let (store, g) = makeStore()
        let id = try await mintAlbum(g)
        let center = MusicEntityModelCenter(store: store, graceWindow: .seconds(60))
        let m = center.acquire(id).model
        let runs = Counter()
        let gate = AsyncStream<Void>.makeStream()
        let loader = MusicClosureSectionLoader(key: "cast") { _, _, report in
            runs.bump()
            if runs.value == 1 { return MusicSectionResult(items: ["a", "b"]) }
            await report.partial(MusicSectionResult(items: ["a"]))
            for await _ in gate.stream { break }
            return MusicSectionResult(items: ["a", "b", "c"])
        }
        m.load(loader)
        #expect(await waitUntil { m.section("cast").phase == .loaded })
        m.load(loader, force: true)
        #expect(await waitUntil { runs.value == 2 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(m.section("cast").items(String.self) == ["a", "b"])
        gate.continuation.yield()
        #expect(await waitUntil { m.section("cast").items(String.self) == ["a", "b", "c"] })
    }

    @Test func aChangeThatArrivesWhileASectionLoadsRunsItAgain() async throws {
        let (store, g) = makeStore()
        let id = try await mintAlbum(g)
        let center = MusicEntityModelCenter(store: store, graceWindow: .seconds(60))
        let m = center.acquire(id).model
        let runs = Counter()
        let gate = AsyncStream<Void>.makeStream()
        let loader = MusicClosureSectionLoader(key: "albums") { _, _, _ in
            runs.bump()
            if runs.value == 1 {
                for await _ in gate.stream { break }
                return MusicSectionResult(items: ["old"])
            }
            return MusicSectionResult(items: ["old", "new"])
        }
        m.load(loader)
        #expect(await waitUntil { runs.value == 1 })
        await m.refresh()
        gate.continuation.yield()
        #expect(await waitUntil { m.section("albums").items(String.self) == ["old", "new"] })
        #expect(runs.value == 2)
    }

    @Test func emptyAndFailedSectionsKeepWhatTheyHad() async throws {
        let (store, g) = makeStore()
        let id = try await mintAlbum(g)
        let center = MusicEntityModelCenter(store: store, graceWindow: .seconds(60))
        let m = center.acquire(id).model
        m.load(MusicClosureSectionLoader(key: "none") { _, _, _ in MusicSectionResult() })
        #expect(await waitUntil { m.section("none").phase == .empty })
        struct Boom: Error {}
        let fail = Flag()
        let loader = MusicClosureSectionLoader(key: "flaky") { _, _, _ in
            if fail.isSet { throw Boom() }
            return MusicSectionResult(items: ["x"])
        }
        m.load(loader)
        #expect(await waitUntil { m.section("flaky").phase == .loaded })
        fail.set()
        m.load(loader, force: true)
        #expect(await waitUntil { m.section("flaky").phase == .failed })
        #expect(m.section("flaky").items(String.self) == ["x"])
        #expect(m.section("flaky").errorMessage != nil)
    }

    @Test func aProvisionalEntityRendersPartiallyThenRefreshesWhenEnrichmentLands() async throws {
        let (store, g) = makeStore()
        let id = try await mintAlbum(g, provisional: true)
        let center = MusicEntityModelCenter(store: store, graceWindow: .seconds(60))
        let m = center.acquire(id).model
        #expect(await waitUntil { m.phase == .partial })
        #expect(m.name == "Awaara")
        // enrichment lands: the row is no longer provisional
        _ = try await g.upsert(MusicEntityDraft(kind: .album, name: "Awaara", externalIDs: [ExternalID(.provider, "p:album1"), ExternalID(.mbReleaseGroup, "rg-9")], provisional: false))
        store.notifyChanged([id])
        #expect(await waitUntil { m.phase == .loaded || m.snapshot?.provisional == false })
    }

    @Test func aMissingEntityFailsCleanly() async {
        let (store, _) = makeStore()
        let center = MusicEntityModelCenter(store: store, graceWindow: .seconds(60))
        let m = center.acquire(.provisional(kind: .film, providerUID: "p:none")).model
        #expect(await waitUntil { m.phase == .failed })
        #expect(m.snapshot == nil)
    }

    // MARK: lifecycle

    @Test func aReleasedModelStaysForTheGraceWindowThenGoes() async throws {
        let (store, g) = makeStore()
        let id = try await mintAlbum(g)
        let center = MusicEntityModelCenter(store: store, graceWindow: .milliseconds(150))
        let first = center.acquire(id)
        let model = first.model
        first.release(); first.release()                       // idempotent
        #expect(center.leaseCount(id) == 0)
        #expect(center.holds(id))
        let again = center.acquire(id)                           // inside the window: the same model, no reload
        #expect(again.model === model)
        again.release()
        #expect(await waitUntil { !center.holds(id) })
        let fresh = center.acquire(id)
        #expect(fresh.model !== model)
    }

    @Test func leavingCancelsForegroundWorkAfterTheGraceWindow() async throws {
        let (store, g) = makeStore()
        let id = try await mintAlbum(g)
        let center = MusicEntityModelCenter(store: store, graceWindow: .milliseconds(40))
        let lease = center.acquire(id)
        let started = Flag(), cancelled = Flag()
        lease.model.load(MusicClosureSectionLoader(key: "slow") { _, _, _ in
            started.set()
            do { try await Task.sleep(for: .seconds(30)) } catch { cancelled.set(); throw error }
            return MusicSectionResult(items: ["late"])
        })
        #expect(await waitUntil { started.isSet })
        lease.release()
        #expect(!cancelled.isSet)                                // still inside the window
        #expect(await waitUntil { cancelled.isSet })
        #expect(!center.holds(id))
    }

    @Test func aDroppedLeaseReleasesItself() async throws {
        let (store, g) = makeStore()
        let id = try await mintAlbum(g)
        let center = MusicEntityModelCenter(store: store, graceWindow: .milliseconds(30))
        do { _ = center.acquire(id) }
        #expect(await waitUntil { !center.holds(id) })
    }

    @Test func idleModelsAreBounded() async throws {
        let (store, g) = makeStore()
        let center = MusicEntityModelCenter(store: store, graceWindow: .seconds(60), maxIdleModels: 3)
        var ids: [MusicEntityID] = []
        for i in 0..<8 { ids.append(try await mintAlbum(g, uid: "p:\(i)")) }
        for id in ids { center.acquire(id).release() }
        #expect(center.idleCount <= 3)
        let held = center.acquire(ids[0])
        #expect(center.leaseCount(ids[0]) == 1)
        _ = held
    }

    @Test func aMergedIdHandsOverToTheSurvivorsModel() async throws {
        let (store, g) = makeStore()
        let loser = try await mintAlbum(g, uid: "p:a")
        let winner = try await g.upsert(MusicEntityDraft(kind: .album, name: "Awaara", externalIDs: [ExternalID(.mbReleaseGroup, "rg-2")])).id
        let center = MusicEntityModelCenter(store: store, graceWindow: .seconds(60))
        let held = center.acquire(loser)
        #expect(await waitUntil { held.model.phase == .loaded })
        _ = try await g.mergeEntities(winner: winner, loser: loser, byUser: false)
        store.notifyChanged([loser, winner], merged: [loser: winner])
        #expect(await waitUntil { held.model.id == winner })
        let next = center.acquire(loser)                         // a saved provisional route now opens the survivor
        #expect(next.model.requestedID == winner || next.model.id == winner)
    }

    @Test func theAppliedEnricherRunsForTheEntityKind() async throws {
        let counter = Counter()
        let (store, g) = makeStore()
        let id = try await mintAlbum(g, provisional: true)
        store.enricher = CountingEnricher(albums: counter)
        let center = MusicEntityModelCenter(store: store, graceWindow: .seconds(60))
        let a = center.acquire(id), b = center.acquire(id)
        #expect(await waitUntil { counter.value >= 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(counter.value == 1)
        _ = (a, b)
    }
}
