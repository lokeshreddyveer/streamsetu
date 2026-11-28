import Foundation
import Testing
@testable import REDDY

@Suite("Credits ingest queue") struct CreditsIngestTests {
    private func track(_ n: Int, credits: [MusicCredit] = []) -> MusicTrack {
        var t = MusicTrack(id: "t\(n)", providerID: "jiosaavn", title: "Song \(n)", durationMs: 1000, artists: [MusicArtistRef(id: "a\(n)", name: "Artist \(n)")])
        if !credits.isEmpty { t.credits = credits }
        return t
    }

    @Test func theQueueIsBoundedAndDropsTheOldest() async {
        let store = MusicInMemoryGraph()
        // A gate that never opens keeps the worker from draining while we fill the queue.
        let ingest = MusicGraphIngest(store: { store }, gate: { try? await Task.sleep(for: .seconds(30)); return false }, queueLimit: 5, pause: .zero)
        for n in 0..<12 { await ingest.enqueue(.track(track(n))) }
        // One item was taken by the worker (and is held at the gate); the rest wait, never more than the cap.
        let v_depth = await ingest.depth; #expect(v_depth <= 5)
        let v_dropped = await ingest.dropped; #expect(v_dropped >= 6)
        await ingest.reset()
        let after = await ingest.depth; #expect(after == 0)
    }

    @Test func repeatsAreSkippedAndChangedCreditsAreWrittenAgain() async throws {
        let store = MusicInMemoryGraph()
        let ingest = MusicGraphIngest(store: { store }, pause: .zero)
        let t = track(1)
        await ingest.enqueue(.track(t)); await ingest.enqueue(.track(t)); await ingest.drain()
        let v_written = await ingest.written; #expect(v_written == 1)
        await ingest.enqueue(.track(t)); await ingest.drain()
        let w1 = await ingest.written
        #expect(w1 == 1, "seen recently and unchanged")
        let richer = track(1, credits: [MusicCredit(name: "Lyr", role: .lyricist, providerArtistID: "l1")])
        await ingest.enqueue(.track(richer)); await ingest.drain()
        let w2 = await ingest.written; #expect(w2 == 2)
        let rec = MusicEntityID.provisional(kind: .recording, providerUID: t.uid)
        #expect(try await store.edges(of: rec, predicate: .writtenBy).count == 1)
    }

    @Test func theMemoryOfWhatWasWrittenIsCapped() async {
        let store = MusicInMemoryGraph()
        let ingest = MusicGraphIngest(store: { store }, queueLimit: 400, seenLimit: 16, pause: .zero)
        for n in 0..<60 { await ingest.enqueue(.track(track(n))) }
        await ingest.drain()
        let v_seenCount = await ingest.seenCount; #expect(v_seenCount <= 16)
    }

    @Test func aClosedGateWritesNothing() async throws {
        let store = MusicInMemoryGraph()
        let ingest = MusicGraphIngest(store: { store }, gate: { false }, pause: .zero)
        for n in 0..<5 { await ingest.enqueue(.track(track(n))) }
        await ingest.drain()
        let v_written = await ingest.written; #expect(v_written == 0)
        #expect(try await store.counts().entities == 0)
    }

    @Test func resetForgetsEverythingLikeThePrivacyWipe() async {
        let store = MusicInMemoryGraph()
        let ingest = MusicGraphIngest(store: { store }, pause: .zero)
        await ingest.enqueue(.track(track(1))); await ingest.drain()
        let v_seenCount = await ingest.seenCount; #expect(v_seenCount == 1)
        await ingest.reset()
        let seen0 = await ingest.seenCount, depth0 = await ingest.depth
        #expect(seen0 == 0 && depth0 == 0)
    }

    @Test func fireAndForgetReturnsAtOnceAndEventuallyWrites() async throws {
        let store = MusicInMemoryGraph()
        let ingest = MusicGraphIngest(store: { store }, pause: .zero)
        let started = Date()
        ingest.ingest(tracks: (0..<30).map { track($0) }, limit: 20)
        #expect(Date().timeIntervalSince(started) < 0.5)
        for _ in 0..<300 {
            if await ingest.written >= 20 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let w20 = await ingest.written
        #expect(w20 == 20, "only the top 20 results are ingested")
    }
}
