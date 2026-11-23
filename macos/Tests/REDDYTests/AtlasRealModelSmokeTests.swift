import Testing
import Foundation
@testable import REDDY

/// Runs only where Apple Intelligence is ready (the on-device model reports available). Asks the real model 30 bank questions the engine was unsure about and records picks, latency and
/// whether the model beat the engine's own top answer. Skipped, with the reason in the report, anywhere else.
@MainActor @Suite("Atlas: real on-device model", .serialized) struct AtlasRealModelSmokeTests {
    nonisolated static var ready: Bool { AppleAtlasLanguageModel.isAvailable }

    @Test(.enabled(if: AtlasRealModelSmokeTests.ready, "needs Apple Intelligence to be available on this machine"))
    func thirtyBankQuestions() async throws {
        let bank = try AtlasBankTests.load().filter { !$0.tags.contains("heldout") }
        let eng = AtlasFixture.engine, have = Set(eng.entries.map(\.id))
        let model = AppleAtlasLanguageModel()
        var asked = 0, better = 0, worse = 0, same = 0, failed = 0, times: [Double] = []
        for q in bank where asked < 30 {
            let plat: AtlasPlatforms = q.platform == "ios" ? [.iPhone, .iPad] : .mac
            let r = eng.retrieve(q.q, platform: plat, limit: 8)
            guard r.decision != .confident, r.ratio < SetuEngine.leadRatio, r.hits.count >= 3 else { continue }
            let cands = Array(r.hits.map(\.entry).map { AtlasCandidate(id: $0.id, title: $0.title, path: $0.path.joined(separator: " > "), summary: $0.summary) })
            asked += 1
            let t0 = Date()
            do {
                let d = try await model.interpret(q.q, candidates: cands)
                times.append(Date().timeIntervalSince(t0))
                let good = AtlasBankTests.accepted(Set(q.expected.compactMap { have.contains($0) ? $0 : (AtlasBankTests.exact[$0] ?? AtlasBankTests.near[$0]) }), in: eng.entries)
                let validated = AtlasModelValidator.validate(d, candidates: r.hits.prefix(5).map(\.entry), accepts: { _, _ in false })
                guard let p = validated.entryID else { same += 1; continue }
                let was = good.contains(r.hits[0].entry.id), now = good.contains(p)
                if p == r.hits[0].entry.id { same += 1 } else if now && !was { better += 1 } else if was && !now { worse += 1 } else { same += 1 }
            } catch { failed += 1 }
        }
        let avg = times.isEmpty ? 0 : times.reduce(0, +) / Double(times.count)
        let line = String(format: "Real on-device model: %d questions, better %d, worse %d, same or no pick %d, failed %d; latency avg %.2fs max %.2fs", asked, better, worse, same, failed, avg, times.max() ?? 0)
        print(line)
        try? FileManager.default.createDirectory(at: AtlasFixture.reportDir, withIntermediateDirectories: true)
        try? line.write(to: AtlasFixture.reportDir.appendingPathComponent("atlas-real-model-report.txt"), atomically: true, encoding: .utf8)
        #expect(asked > 0)
    }

    @Test func theSkipIsExplainedWhenTheModelIsNotReady() {
        let a = AppleAtlasLanguageModel.availability
        print("Real model availability on this machine: \(a)")
        #expect(a.usable == Self.ready)
    }
}
