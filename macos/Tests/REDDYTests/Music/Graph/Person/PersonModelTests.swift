import Foundation
import Testing
@testable import REDDY

/// An enricher that always fails: the metadata sources are down.
struct DownEnricher: MusicEntityEnriching {
    struct Down: Error {}
    func enrichPerson(_ id: MusicEntityID) async throws -> MusicEnrichmentResult { throw Down() }
    func enrichFilm(_ id: MusicEntityID) async throws -> MusicEnrichmentResult { throw Down() }
}

@MainActor
@Suite struct PersonModelTests {
    struct Rig {
        let world: PersonWorld
        let store: MusicEntityStore
        let center: MusicEntityModelCenter
        let memory: MusicPersonMemoryBox
    }

    private func rig(enricher: any MusicEntityEnriching = MusicNoopEntityEnricher(), graph: (any MusicGraphStoring)? = nil) async throws -> Rig {
        let w = try await PersonWorld.make()
        let store = MusicEntityStore(graph: graph ?? w.store, enricher: enricher)
        return Rig(world: w, store: store, center: MusicEntityModelCenter(store: store), memory: MusicPersonMemoryBox())
    }

    private func model(_ r: Rig, _ id: MusicEntityID, hint: MusicRole? = nil, query: String? = nil, enrich: MusicPersonRoleEnricher? = nil) -> MusicPersonGraphModel {
        MusicPersonGraphModel(id: id, roleHint: hint, nameSearchQuery: query, memoryKey: "entity:" + id.rawValue + (hint.map { "#" + $0.rawValue } ?? ""),
                              center: r.center, memory: .dictionary(r.memory), enrichRoles: enrich)
    }

    /// Polls until the condition holds, calling `sync()` on each model the way the page does when its state changes (`syncToken`).
    private func settle(_ models: MusicPersonGraphModel..., until: @MainActor () -> Bool) async {
        for _ in 0..<400 {
            for m in models { m.sync() }
            if until() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func rajKapoorShowsTwoRoleChipsAndSwitchingKeepsEachRolesData() async throws {
        let r = try await rig()
        let m = model(r, r.world.raj, hint: .director)
        m.open()
        await settle(m) { m.viewData?.complete == true }
        #expect(m.activeView == .director && m.roles.needsSwitcher && Set(m.roles.views.map(\.view)) == [.actor, .director, .producer])
        #expect(m.roles.extras.isEmpty && m.roles.has(.producer))
        #expect(m.viewData?.section(.composersCollaborated) != nil && m.viewData?.section(.coStars) == nil)
        m.select(.actor)
        await settle(m) { m.viewData?.complete == true && m.viewData?.view == .actor }
        #expect(m.activeView == .actor && m.viewData?.section(.coStars) != nil)
        m.select(.director)
        #expect(m.viewData?.view == .director && m.viewData?.complete == true)   // instant: kept, not reloaded
        #expect(m.runs(of: .director) == 1 && m.runs(of: .actor) == 1)
        #expect(r.memory.values[m.memoryKey] == "director")
        m.close()
    }

    @Test func backRestoresTheRememberedRoleOverTheHint() async throws {
        let r = try await rig()
        let first = model(r, r.world.raj, hint: .actor)
        first.open(); await settle(first) { first.rolesSettled }
        first.select(.director)
        first.close()
        let again = model(r, r.world.raj, hint: .actor)
        again.open(); await settle(again) { again.rolesSettled }
        #expect(again.activeView == .director)     // remembered role (the same memory key restores it)
        again.close()
    }

    @Test func routeRoleHintIsHeldWhileNothingHasLoadedThenYieldsToRealRoles() async throws {
        let r = try await rig()
        let m = model(r, r.world.mukesh, hint: .actor)     // the route said actor; the graph has only singer edges
        m.open()
        #expect(m.activeView == .actor)                     // before the profile loads, the hint is held (no flip later for a true hint)
        await settle(m) { m.rolesSettled }
        #expect(m.activeView == .singer && !m.roles.needsSwitcher)
        m.close()
    }

    @Test func personWithNoCreditsRendersAHeaderOnly() async throws {
        let r = try await rig()
        let m = model(r, r.world.nobody)
        m.open()
        await settle(m) { m.rolesSettled }
        #expect(m.activeView == nil && m.viewData == nil && m.roles.isEmpty)
        #expect(m.header?.initials == "US" && m.header?.portrait == nil)
        m.close()
    }

    @Test func groupPageListsMembersOnlyWhenListedAndPersonPageLinksBack() async throws {
        let r = try await rig()
        let g = model(r, r.world.sj)
        g.open()
        await settle(g) { g.viewData?.complete == true && !g.members.isEmpty }
        #expect(g.isGroup && g.activeView == .composer && g.members.map(\.name) == ["Jaikishan", "Shankar"])
        let p = model(r, r.world.shankar)
        p.open()
        await settle(p) { !p.memberOf.isEmpty }
        #expect(p.memberOf.map(\.name) == ["Shankar-Jaikishan"] && p.activeView == nil)
        g.close(); p.close()
    }

    @Test func didYouMeanOnlyForNameSearchRoutes() async throws {
        let r = try await rig()
        let viaSearch = model(r, r.world.bakshiA, query: "anand bakshi")
        viaSearch.open()
        await settle(viaSearch) { !viaSearch.candidates.isEmpty }
        #expect(viaSearch.candidates.map(\.id) == [r.world.bakshiB])
        let direct = model(r, r.world.bakshiB)
        direct.open()
        await settle(direct) { direct.snapshot != nil }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(direct.candidates.isEmpty && direct.candidateLoads == 0)
        viaSearch.close(); direct.close()
    }

    @Test func metadataOutageStillShowsCachedPartialData() async throws {
        // every enricher call throws and the store fails some reads: the page renders what the graph holds, with no failed state for the page
        let w = try await PersonWorld.make()
        let flaky = FlakyGraph(base: w.store, failIncoming: [.playlistContains], failEntities: [w.lata])
        let store = MusicEntityStore(graph: flaky, enricher: DownEnricher())
        let center = MusicEntityModelCenter(store: store)
        let calls = CallCounter()
        let m = MusicPersonGraphModel(id: w.mukesh, roleHint: .singer, nameSearchQuery: nil, memoryKey: "k", center: center, memory: .dictionary(MusicPersonMemoryBox()),
                                      enrichRoles: { _, _ in calls.bump(); return false })
        m.open()
        await settle(m) { m.viewData?.complete == true }
        #expect(m.phase == .loaded && m.activeView == .singer)
        #expect(m.viewData?.section(.topSongs)?.entries.first?.name == "Awaara Hoon")
        #expect(m.viewData?.section(.playlists) == nil && m.viewLoadFailed == false)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(calls.count == 1)     // one role-limited refresh per role, failure ignored
        m.close()
    }

    @Test func unknownIdIsNotFoundNotACrash() async throws {
        let r = try await rig()
        let m = model(r, .derive(kind: .person, aliasKey: "nobody:here"))
        m.open()
        await settle(m) { m.phase == .failed }
        #expect(m.phase == .failed && m.activeView == nil && m.header == nil)
        m.close()
    }

    @Test func tombstonedIdOpensTheSurvivor() async throws {
        let r = try await rig()
        let loser = try await PersonWorld.person(r.world.store, "Mukesh Chand Mathur", wikidata: "Q9999")
        _ = try await r.world.store.mergeEntities(winner: r.world.mukesh, loser: loser, byUser: true)
        let m = model(r, loser)
        m.open()
        await settle(m) { m.rolesSettled }
        #expect(m.snapshot?.id == r.world.mukesh && m.activeView == .singer)
        m.close()
    }
}

final class CallCounter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var count: Int { lock.withLock { n } }
}
