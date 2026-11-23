import Testing
import Foundation
@testable import REDDY

// The hub's negative cache for ids, the failure count and the one pause policy for a refused built-in key.
extension HubTests {
    final class ThrowingArt: ArtworkProvider, @unchecked Sendable {
        let source: HubSource; let status: Int; var calls = 0
        init(_ s: HubSource, status: Int) { source = s; self.status = status }
        func artwork(for id: HubIdentity, kind: HubTitleKind) async throws -> [ArtCandidate] { calls += 1; throw NetworkError.http(status: status, retryAfter: nil) }
    }

    @Test func anIdentityMissIsRememberedAndLiftedByNewIds() throws {
        let store = HubStore(db: try TestSupport.makeDB())
        store.saveIdentity("a", HubIdentity(tvmaze: 5), from: .tvmaze, now: t0)
        store.setIdentityMiss("a", until: t0.addingTimeInterval(1000))
        #expect(store.identity("a")?.missUntil == t0.addingTimeInterval(1000))
        store.saveIdentity("a", HubIdentity(tvmaze: 5), from: .tvmaze, now: t0)
        #expect(store.identity("a")?.missUntil != nil, "the same ids do not lift it")
        store.saveIdentity("a", HubIdentity(tmdb: 9), from: .tmdb, now: t0)
        #expect(store.identity("a")?.missUntil == nil, "a new id does")
    }

    @Test func aFailureIsCountedOnTheRow() throws {
        let store = HubStore(db: try TestSupport.makeDB())
        store.putMiss("a", "art:tvdb", source: .tvdb, until: t0.addingTimeInterval(10), now: t0)
        store.noteFailure("a", "art:tvdb"); store.noteFailure("a", "art:tvdb")
        #expect(store.fact("a", "art:tvdb")?.fact.failCount == 2)
    }

    @Test func aFailedAskIsNotedAndANotFoundIdentityIsRemembered() async throws {
        let db = try TestSupport.makeDB()
        let tvdb = ThrowingArt(.tvdb, status: 404)
        let d = freshDefaults(); let store = HubStore(db: db); let t = t0
        let acc: [HubSource: HubAccess] = [.tvdb: access(.tvdb, builtIn: "FAKE", defaults: d, now: { t })]
        d.set(true, forKey: "hub.tvdb.enabled")
        let hub = MetadataHub(store: store, artwork: [tvdb], episodes: [], access: acc, now: { t }, sleep: { _ in })
        let ids = HubIdentity(tvdb: 81189, kind: .series)
        let r = await hub.refresh("s1", identity: ids, kind: .series)
        #expect(r.asked == [.tvdb] && tvdb.calls == 1)
        #expect(store.fact("s1", "art:tvdb")?.fact.failCount == 1)
        #expect(store.identity("s1")?.missUntil != nil)
        let again = await hub.refresh("s1", identity: ids, kind: .series)
        #expect(again.asked.isEmpty && tvdb.calls == 1, "not asked again while the miss is remembered")
    }

    @Test func oneRefusedBuiltInKeyPausesEveryServiceTheSameWayAndOwnKeysNever() throws {
        var clock = t0
        let box = NSLock(); nonisolated(unsafe) var current = clock
        let now: @Sendable () -> Date = { box.withLock { current } }
        let d = freshDefaults()
        let pause = BuiltInKeyPause(storageKey: "x.rejectedAt", defaults: d, now: now)
        #expect(!pause.isPaused)
        pause.reportRefused(ownKeyInUse: true)
        #expect(!pause.isPaused, "an own key is never paused")
        pause.reportRefused(ownKeyInUse: false)
        #expect(pause.isPaused)
        clock = t0.addingTimeInterval(Retention.builtInKeyPause - 1); box.withLock { current = clock }
        #expect(pause.isPaused)
        clock = t0.addingTimeInterval(Retention.builtInKeyPause + 1); box.withLock { current = clock }
        #expect(!pause.isPaused, "tried again after the shared pause")
        #expect(BuiltInKeyPause.isRefusal(401) && BuiltInKeyPause.isRefusal(403) && !BuiltInKeyPause.isRefusal(404))

        // TMDB, fanart.tv and TheTVDB all pause for that one constant, and none pauses with an own key.
        box.withLock { current = t0 }
        let tmdbBuiltIn = TMDBAccess(ownKey: { nil }, builtIn: { "FAKE" }, defaults: freshDefaults(), now: now)
        tmdbBuiltIn.markBuiltInRejected()
        #expect(tmdbBuiltIn.builtInRejected)
        let tmdbOwn = TMDBAccess(ownKey: { "mine" }, builtIn: { "FAKE" }, defaults: freshDefaults(), now: now)
        tmdbOwn.markBuiltInRejected(); #expect(!tmdbOwn.builtInRejected)
        for s in [HubSource.fanart, .tvdb] {
            let a = access(s, builtIn: "FAKE", defaults: freshDefaults(), now: now)
            a.markBuiltInRejected(); #expect(a.builtInRejected)
            box.withLock { current = t0.addingTimeInterval(Retention.builtInKeyPause + 1) }
            #expect(!a.builtInRejected && !tmdbBuiltIn.builtInRejected)
            box.withLock { current = t0 }
            let own = access(s, builtIn: "FAKE", defaults: freshDefaults(), secrets: { let m = MemorySecretStore(); m.set("mine", for: HubAccess.accessKey(s)); return m }(), now: now)
            own.markBuiltInRejected(); #expect(!own.builtInRejected)
        }
    }
}
