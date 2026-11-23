import Testing
import Foundation
@testable import REDDY

/// Timings against the 04 section 7 budget (cold index under 100 ms, query under 20 ms p95). Debug builds are slower than release, so the hard limit here is 2x the budget; the printed numbers are the record.
@MainActor @Suite("Atlas: timings", .serialized) struct AtlasPerfTests {
    private func ms(_ block: () -> Void) -> Double {
        let t = DispatchTime.now().uptimeNanoseconds; block(); return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
    }

    @Test func coldIndexAndQueryTimings() async throws {
        let entries = AtlasFixture.entries
        var engine: SetuEngine?
        let importMs = ms { _ = AtlasRegistry.importEntries() }
        // Best of five builds, measured in CPU time: the whole suite (and the owner's Mac) shares the machine, and a build that is really slow is slow every time.
        func cpuMs(_ block: () -> Void) -> Double { let a = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID); block(); return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - a) / 1e6 }
        var samples: [Double] = []
        for _ in 0..<5 { samples.append(cpuMs { engine = SetuEngine(entries: entries) }); try? await Task.sleep(for: .milliseconds(150)) }          // spread out, so one busy moment of the whole run cannot hit every sample
        let indexMs = samples.min() ?? 0          // CPU time of this thread: other work on the machine cannot slow it
        var emb: AtlasEmbeddings?
        let embedMs = ms { emb = AtlasEmbeddings.build(entries: entries) }
        let e = try #require(engine)
        let withEmb = e.with(embeddings: emb)
        let bank = try AtlasBankTests.load()
        let qs = bank.map(\.q)
        _ = withEmb.retrieve(qs[0])   // warm the sentence model
        var bm: [Double] = [], both: [Double] = []
        // Best of three per query: the whole suite runs in parallel on a shared machine, so one slow sample (a context switch) says more about the load than about the engine. A query that is
        // really slow is slow every time, so the 40 ms guard on the 95th percentile still catches it.
        func best(_ body: () -> Void) -> Double { (0..<3).map { _ in ms(body) }.min() ?? 0 }
        // each query is timed on its own; yielding between them lets the other main-actor tests run instead of waiting behind this one for a minute and a half
        for q in qs { bm.append(best { _ = e.retrieve(q) }); both.append(best { _ = withEmb.retrieve(q) }); await Task.yield() }
        func p(_ a: [Double], _ x: Double) -> Double { a.sorted()[min(a.count - 1, Int(Double(a.count) * x))] }
        let report = String(format: "entries=%d vocab=%d | import %.1f ms | cold index (BM25+vocab) %.1f ms | embeddings for all entries %.1f ms (source: %@) | query BM25-only p50 %.2f p95 %.2f ms | query BM25+embeddings p50 %.2f p95 %.2f ms (%d queries, debug build)",
                            entries.count, e.vocabularySize, importMs, indexMs, embedMs, AtlasEmbeddings.source ?? "none", p(bm, 0.5), p(bm, 0.95), p(both, 0.5), p(both, 0.95), qs.count)
        print("ATLAS TIMINGS: " + report)
        try? FileManager.default.createDirectory(at: AtlasFixture.reportDir, withIntermediateDirectories: true)
        try? report.write(to: AtlasFixture.reportDir.appendingPathComponent("atlas-timings.txt"), atomically: true, encoding: .utf8)
        #expect(indexMs < 200)
        #expect(p(both, 0.95) < 40)
    }
}
