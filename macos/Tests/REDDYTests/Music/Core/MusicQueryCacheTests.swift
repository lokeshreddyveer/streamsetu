import Testing
import Foundation
@testable import REDDY

final class QueryCacheCounter: @unchecked Sendable { private let l = NSLock(); private var n = 0; func bump() -> Int { l.lock(); defer { l.unlock() }; n += 1; return n }; var value: Int { l.lock(); defer { l.unlock() }; return n } }
final class QueryCacheClock: @unchecked Sendable { private let l = NSLock(); private var t = Date(timeIntervalSince1970: 1_000); var now: Date { l.lock(); defer { l.unlock() }; return t }; func advance(_ s: TimeInterval) { l.lock(); t += s; l.unlock() } }

@Suite("Music query cache") struct MusicQueryCacheTests {
    @Test func theSameQuestionInAnyCaseIsOneKey() {
        #expect(MusicQueryCache<Int>.key("yt", "songs", " Arijit  SINGH ") == MusicQueryCache<Int>.key("yt", "songs", "arijit singh"))
        #expect(MusicQueryCache<Int>.key("yt", "songs", "arijit") != MusicQueryCache<Int>.key("yt", "albums", "arijit"))
    }
    @Test func repeatedAskIsServedWithoutARequest() async throws {
        let c = MusicQueryCache<String>(); let n = QueryCacheCounter()
        let a = try await c.value(for: "k") { _ = n.bump(); return "one" }
        let b = try await c.value(for: "k") { _ = n.bump(); return "two" }
        #expect(a == "one" && b == "one" && n.value == 1)
    }
    @Test func anOlderEntryIsServedAndRefreshedBehind() async throws {
        let clock = QueryCacheClock(); let c = MusicQueryCache<String>(clock: { clock.now }); let n = QueryCacheCounter()
        _ = try await c.value(for: "k") { _ = n.bump(); return "old" }
        clock.advance(120)                                            // past fresh (60 s), inside ttl (300 s)
        let r = try await c.value(for: "k") { _ = n.bump(); return "new" }
        #expect(r == "old")
        try await Task.sleep(for: .milliseconds(200))
        let again = try await c.value(for: "k") { _ = n.bump(); return "newer" }
        #expect(again == "new" && n.value == 2)
    }
    @Test func anExpiredEntryAsksAgainAndAFailureKeepsNothingWrong() async throws {
        let clock = QueryCacheClock(); let c = MusicQueryCache<String>(clock: { clock.now })
        _ = try await c.value(for: "k") { "old" }
        clock.advance(400)
        struct Down: Error {}
        await #expect(throws: Down.self) { _ = try await c.value(for: "k") { () async throws -> String in throw Down() } }
        let r = try await c.value(for: "k") { "fresh" }
        #expect(r == "fresh")
    }
    @Test func theLeastRecentlyUsedEntryGoesAtTheCap() async throws {
        let clock = QueryCacheClock(); let c = MusicQueryCache<Int>(capacity: 3, clock: { clock.now })
        for i in 0..<3 { _ = try await c.value(for: "k\(i)") { i }; clock.advance(1) }
        _ = try await c.value(for: "k0") { 99 }; clock.advance(1)      // k0 used again
        _ = try await c.value(for: "k3") { 3 }                          // over the cap: k1 is the oldest
        let n = QueryCacheCounter()
        _ = try await c.value(for: "k1") { _ = n.bump(); return 1 }     // asked again: it was dropped
        let kept = try await c.value(for: "k0") { _ = n.bump(); return 42 }
        #expect(n.value == 1 && kept == 0)
        #expect(await c.count <= 3)
    }
    @Test func clearForgetsEverything() async throws {
        let c = MusicQueryCache<Int>(); _ = try await c.value(for: "k") { 1 }
        await c.clear()
        #expect(await c.count == 0)
    }
}

@Suite("Music library change counters") @MainActor struct MusicLibraryRevisionTests {
    @Test func everyChangeRaisesItsOwnCounterOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rev-\(UUID().uuidString)")
        let lib = MusicLibrary(directory: dir, debounce: .seconds(60))
        let t = MusicTrack(id: "1", providerID: "x", title: "T", durationMs: 1000, artists: [])
        let (l0, p0) = (lib.likedRevision, lib.playlistsRevision)
        lib.toggleLike(t)
        #expect(lib.likedRevision > l0 && lib.playlistsRevision == p0)
        let p1 = lib.playlistsRevision
        let pl = lib.createPlaylist(name: "A")
        #expect(lib.playlistsRevision > p1)
        let p2 = lib.playlistsRevision
        lib.rename(pl.id, to: "B")
        #expect(lib.playlistsRevision > p2)               // a rename is seen, which the old count-based check also saw only by name text
    }
}
@Suite("Identical questions share one request") struct MusicQueryCacheInflightTests {
    actor Counter { var n = 0; func bump() -> Int { n += 1; return n } }

    @Test func tenAsksAtOnceSendOneRequest() async throws {
        let cache = MusicQueryCache<Int>()
        let counter = Counter()
        let results = try await withThrowingTaskGroup(of: Int.self) { group -> [Int] in
            for _ in 0..<10 { group.addTask { try await cache.value(for: "k") { try await Task.sleep(for: .milliseconds(80)); return await counter.bump() } } }
            var out: [Int] = []
            for try await r in group { out.append(r) }
            return out
        }
        #expect(await counter.n == 1)
        #expect(Set(results) == [1])
    }

    @Test func differentQuestionsAreNotMerged() async throws {
        let cache = MusicQueryCache<Int>()
        let counter = Counter()
        async let a = cache.value(for: "a") { await counter.bump() }
        async let b = cache.value(for: "b") { await counter.bump() }
        _ = try await (a, b)
        #expect(await counter.n == 2)
    }

    @Test func aFailedRequestIsNotKeptAndTheNextAskTriesAgain() async throws {
        struct Boom: Error {}
        let cache = MusicQueryCache<Int>()
        await #expect(throws: Boom.self) { try await cache.value(for: "k") { throw Boom() } }
        let v = try await cache.value(for: "k") { 7 }
        #expect(v == 7)
    }
}
