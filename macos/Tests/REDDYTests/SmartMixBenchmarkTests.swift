import Testing
import Foundation
@testable import REDDY

/// Micro-benchmark of the engine. Gated: SMARTMIX_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter SmartMixBenchmark
/// Numbers are printed as "SMBENCH ..." lines. Debug builds are not representative.
@Suite(.serialized) struct SmartMixBenchmarkTests {
    private static let on = ProcessInfo.processInfo.environment["SMARTMIX_BENCH"] != nil

    private static func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

    private static func stats(_ xs: [Double]) -> String {
        let s = xs.sorted()
        return String(format: "p50 %.1f ms  p95 %.1f ms  max %.1f ms (n=%d)", s[s.count / 2], s[min(s.count - 1, s.count * 95 / 100)], s.last!, s.count)
    }

    private func pipeline(_ cands: [SMCandidate], _ ctx: SMContext, shelves: [String]) -> (prepare: Double, shelves: Double, perShelf: [String: Double], ids: Int) {
        let clock = ContinuousClock()
        var prepared: SmartMixEngine.Prepared!
        let tp = clock.measure { prepared = SmartMixEngine.prepare(cands, preferredLang: ctx.preferredLang) }
        var per: [String: Double] = [:], total = 0, tsum = 0.0
        for s in shelves {
            var r: SMShelfResult!
            let t = clock.measure { r = SmartMixEngine.build(shelfId: s, prepared: prepared, ctx: ctx) }
            per[s] = Self.ms(t); tsum += Self.ms(t); total += r.ids.count
        }
        return (Self.ms(tp), tsum, per, total)
    }

    @Test(.enabled(if: SmartMixBenchmarkTests.on), arguments: [(66_540, 632), (200_000, 1500)])
    func wholePipeline(_ n: Int, _ folders: Int) async throws {
        let cands = SMFixtures.generate(name: "bench", seed: 5, n: n, folders: folders)
        let aff = SMAffinity(topLangs: ["Telugu", "Hindi", "English"], topFolders: ["f1", "f2"], topGenres: ["action", "drama"], topDecades: [2010, 2020])
        let shelves = SMShelf.all
        let ctx = SMContext(profile: "bench", dayKey: "2026-11-21", preferredLang: "Telugu", affinity: aff)
        // Everything runs on a detached task, never on the main thread.
        let out: [String] = await Task.detached(priority: .userInitiated) { [self] in
            precondition(!(pthread_main_np() != 0))
            var lines: [String] = []
            // COLD: first run in this process for this data set (fresh allocations, nothing reused).
            let cold = pipeline(cands, ctx, shelves: shelves)
            lines.append(String(format: "SMBENCH n=%d COLD  prepare %.1f ms + 6 shelves %.1f ms = %.1f ms", n, cold.prepare, cold.shelves, cold.prepare + cold.shelves))
            // WARM: repeated runs.
            var totals: [Double] = [], prepares: [Double] = [], shelfOnly: [Double] = []
            var per: [String: [Double]] = [:]
            for _ in 0..<10 {
                let r = pipeline(cands, ctx, shelves: shelves)
                totals.append(r.prepare + r.shelves); prepares.append(r.prepare); shelfOnly.append(r.shelves)
                for (k, v) in r.perShelf { per[k, default: []].append(v) }
            }
            lines.append("SMBENCH n=\(n) WARM full pipeline  " + Self.stats(totals))
            lines.append("SMBENCH n=\(n) WARM prepare (restrict+group+representative) " + Self.stats(prepares))
            lines.append("SMBENCH n=\(n) WARM 6 shelves on prepared pool " + Self.stats(shelfOnly))
            for k in shelves { lines.append("SMBENCH n=\(n) WARM shelf \(k) " + Self.stats(per[k]!)) }
            // What the real adapter feeds: the 2000 best rows per shelf pre-selected by the database, not the whole library.
            let slice = Array(cands.prefix(2000))
            var t2: [Double] = []
            for _ in 0..<20 { let r = pipeline(slice, ctx, shelves: shelves); t2.append(r.prepare + r.shelves) }
            lines.append("SMBENCH n=\(n) WARM 2000-row pool, 6 shelves " + Self.stats(t2))
            // One shelf with a folder row of ~200.
            var tf: [Double] = []
            let prepared = SmartMixEngine.prepare(cands, preferredLang: "Telugu")
            let clock = ContinuousClock()
            for i in 0..<50 { tf.append(Self.ms(clock.measure { _ = SmartMixEngine.build(shelfId: SMShelf.folder("f\(i % 30)"), prepared: prepared, ctx: ctx) })) }
            lines.append("SMBENCH n=\(n) WARM folder row (prepared) " + Self.stats(tf))
            return lines
        }.value
        for l in out { print(l) }
        #expect(!out.isEmpty)
    }
}
