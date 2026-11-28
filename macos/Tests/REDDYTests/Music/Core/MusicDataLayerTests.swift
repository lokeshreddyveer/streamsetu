import Testing
import Foundation
@testable import REDDY

struct FetchTestAlbum: Codable, Sendable, Equatable { var title: String; var tracks: [String] }
final class FetchCounter: @unchecked Sendable { private let l = NSLock(); private var n = 0; func bump() -> Int { l.lock(); defer { l.unlock() }; n += 1; return n }; var value: Int { l.lock(); defer { l.unlock() }; return n } }
final class FetchClock: @unchecked Sendable { private let l = NSLock(); private var t = Date(timeIntervalSince1970: 1_000_000); var now: Date { l.lock(); defer { l.unlock() }; return t }; func advance(_ s: TimeInterval) { l.lock(); t += s; l.unlock() } }

func fetchTmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)/data.sqlite") }
struct FetchBoom: Error {}

@Suite("Music data layer") struct MusicDataLayerTests {
    @Test func savesAndReadsBack() async throws {
        let s = MusicDataStore(path: fetchTmp())
        await s.put("a", data: Data("hello".utf8))
        let got = await s.get("a")
        #expect(got?.data == Data("hello".utf8))
        let none = await s.get("missing")
        #expect(none == nil)
        await s.put("a", data: Data("new".utf8))
        let count = await s.count, again = await s.get("a")
        #expect(count == 1 && again?.data == Data("new".utf8))
    }

    @Test func evictsLeastRecentlyUsedPastTheLimit() async throws {
        let clock = FetchClock()
        let s = MusicDataStore(path: fetchTmp(), maxBytes: 1_000_000, clock: { clock.now })
        let blob = Data(repeating: 7, count: 100_000)
        for i in 0..<9 { await s.put("k\(i)", data: blob); clock.advance(1) }
        _ = await s.get("k0"); clock.advance(1)                      // k0 is now the most recently used
        for i in 9..<12 { await s.put("k\(i)", data: blob); clock.advance(1) }   // crosses 1 MB: the oldest unused rows go
        let bytes = await s.bytes, k0 = await s.get("k0"), k1 = await s.get("k1")
        #expect(bytes <= 1_000_000)
        #expect(k0 != nil)                                           // kept: used recently
        #expect(k1 == nil)                                           // dropped: least recently used
    }

    @Test func removesByPrefixAndWipes() async throws {
        let p = fetchTmp()
        let s = MusicDataStore(path: p)
        await s.put("v1|a|1", data: Data([1])); await s.put("v1|a|2", data: Data([2])); await s.put("v1|b|1", data: Data([3]))
        await s.remove(prefix: "v1|a|")
        let left = await s.count
        #expect(left == 1)
        await s.wipe()
        #expect(!FileManager.default.fileExists(atPath: p.path))
        let gone = await s.get("v1|b|1")
        #expect(gone == nil)
    }

    @Test func firstAskGoesToTheSourceThenSavedCopyAnswers() async throws {
        let f = MusicFetch(store: MusicDataStore(path: fetchTmp()))
        let n = FetchCounter()
        let a = try await f.value("k", policy: MusicFetch.Kind.albumPage) { _ = n.bump(); return FetchTestAlbum(title: "A", tracks: ["x"]) }
        #expect(a.source == .network)
        let b = try await f.value("k", policy: MusicFetch.Kind.albumPage) { _ = n.bump(); return FetchTestAlbum(title: "B", tracks: []) }
        #expect(b.source == .saved && b.value.title == "A" && n.value == 1)
    }

    @Test func manyAsksAtOnceMakeOneRequest() async throws {
        let f = MusicFetch(store: MusicDataStore(path: fetchTmp()))
        let n = FetchCounter()
        let results = try await withThrowingTaskGroup(of: String.self) { g -> [String] in
            for _ in 0..<8 { g.addTask { try await f.value("same", policy: MusicFetch.Kind.artistPage) { _ = n.bump(); try await Task.sleep(for: .milliseconds(150)); return FetchTestAlbum(title: "S", tracks: []) }.value.title } }
            var out: [String] = []; for try await r in g { out.append(r) }; return out
        }
        #expect(results.count == 8 && n.value == 1)
    }

    @Test func oldCopyIsUsedAtOnceAndRefreshedBehind() async throws {
        let clock = FetchClock()
        let f = MusicFetch(store: MusicDataStore(path: fetchTmp(), clock: { clock.now }), clock: { clock.now })
        let n = FetchCounter()
        _ = try await f.value("k", policy: MusicFetch.Kind.albumPage) { _ = n.bump(); return FetchTestAlbum(title: "old", tracks: []) }
        clock.advance(2 * 86_400)                                     // past `fresh` (6 h), inside `ttl` (7 d)
        let r = try await f.value("k", policy: MusicFetch.Kind.albumPage) { _ = n.bump(); return FetchTestAlbum(title: "new", tracks: []) }
        #expect(r.value.title == "old" && r.source == .saved)         // answered at once from the old copy
        try await Task.sleep(for: .milliseconds(300))                 // the quiet refresh lands
        let again = try await f.value("k", policy: MusicFetch.Kind.albumPage) { _ = n.bump(); return FetchTestAlbum(title: "newer", tracks: []) }
        #expect(again.value.title == "new" && n.value == 2)
    }

    @Test func fallsBackToAnOlderCopyWhenTheSourceIsDown() async throws {
        let clock = FetchClock()
        let f = MusicFetch(store: MusicDataStore(path: fetchTmp(), clock: { clock.now }), clock: { clock.now }, sleep: { _ in })
        _ = try await f.value("k", policy: MusicFetch.Kind.albumPage) { FetchTestAlbum(title: "kept", tracks: []) }
        clock.advance(10 * 86_400)                                    // past `ttl`, inside ttl + staleIfError
        let r = try await f.value("k", policy: MusicFetch.Kind.albumPage) { () async throws -> FetchTestAlbum in throw URLError(.notConnectedToInternet) }
        #expect(r.value.title == "kept" && r.source == .savedBecauseOffline)
        clock.advance(40 * 86_400)                                    // too old even for a fallback
        await #expect(throws: URLError.self) { _ = try await f.value("k", policy: MusicFetch.Kind.albumPage) { () async throws -> FetchTestAlbum in throw URLError(.notConnectedToInternet) } }
    }

    @Test func retriesAShortFailureButNotARefusal() async throws {
        let f = MusicFetch(store: MusicDataStore(path: fetchTmp()), sleep: { _ in })
        let n = FetchCounter()
        let r = try await f.value("flaky", policy: MusicFetch.Kind.search) { if n.bump() < 2 { throw URLError(.timedOut) }; return FetchTestAlbum(title: "ok", tracks: []) }
        #expect(r.value.title == "ok" && n.value == 2)
        let m = FetchCounter()
        await #expect(throws: FetchBoom.self) { _ = try await f.value("refused", policy: MusicFetch.Kind.albumPage) { () async throws -> FetchTestAlbum in _ = m.bump(); throw FetchBoom() } }
        #expect(m.value == 1)                                         // a refusal is not retried
    }

    @Test func aBadSavedPayloadIsAMissNotACrash() async throws {
        let s = MusicDataStore(path: fetchTmp())
        let f = MusicFetch(store: s)
        await s.put("k", data: Data("not json".utf8))
        let r = try await f.value("k", policy: MusicFetch.Kind.albumPage) { FetchTestAlbum(title: "fresh", tracks: []) }
        #expect(r.value.title == "fresh" && r.source == .network)
    }
}

@Suite("Music data layer: keep rule") struct MusicDataLayerKeepTests {
    @Test func anEmptyAnswerIsReturnedButNotSaved() async throws {
        let f = MusicFetch(store: MusicDataStore(path: fetchTmp()))
        let n = FetchCounter()
        _ = try await f.value("k", policy: MusicFetch.Kind.albumPage, keep: { !$0.tracks.isEmpty }) { _ = n.bump(); return FetchTestAlbum(title: "empty", tracks: []) }
        let again = try await f.value("k", policy: MusicFetch.Kind.albumPage, keep: { !$0.tracks.isEmpty }) { _ = n.bump(); return FetchTestAlbum(title: "full", tracks: ["x"]) }
        #expect(again.value.title == "full" && n.value == 2)   // the empty one was not remembered
    }
}
