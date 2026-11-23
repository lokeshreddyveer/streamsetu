import Testing
import Foundation
@testable import REDDY

/// Regression: the same title id queued twice (two Home shelves) trapped `Dictionary(uniqueKeysWithValues:)` in `candidates(ids:)`.
@Suite("Duplicate ids never trap") struct QualityDuplicateIDTests {
    private func service() throws -> (MetadataMatchService, [String]) {
        let db = try TestSupport.makeDB(); let src = try TestSupport.makeSource(db)
        let ms = (0..<5).map { TestSupport.movie(src, "m\($0)", "Duplicate Probe Film \($0)", year: 2000 + $0) }
        _ = try CatalogIndexer(db: db).commitMovies(source: src, categories: [], movies: ms)
        let ids = ms.map(\.id)
        let creds = InMemoryCredentialStore(); try creds.save(Credentials(username: "tmdb", password: "0123456789abcdef0123456789abcdef"), ref: MetadataMatchService.keyRef)
        return (MetadataMatchService(db: db, credentials: creds, defaults: InMemoryDefaults(), builtIn: { nil }) { _ in Data() }, ids)
    }

    @Test func duplicateIdsInOneCallGiveOneCandidateEach() throws {
        let (svc, ids) = try service(); let (m0, m1, m2) = (ids[0], ids[1], ids[2])
        let all = svc.candidates(ids: [m0, m1, m2])
        #expect(!all.isEmpty)
        let dup = svc.candidates(ids: [m2, m0, m2, m0, m1, m1, m2])
        #expect(dup.count == all.count && Set(dup.map(\.id)) == Set(all.map(\.id)))
        #expect(dup.map(\.id).first == m2)      // first position wins
        #expect(svc.candidates(ids: []).isEmpty)
    }

    @Test func concurrentCallsWithOverlappingIdsDoNotTrap() async throws {
        let (svc, ids) = try service()
        let counts = await withTaskGroup(of: Int.self) { g in
            for i in 0..<16 { g.addTask { svc.candidates(ids: [ids[i % 3], ids[(i + 1) % 3], ids[i % 3], ids[4]]).count } }
            return await g.reduce(into: [Int]()) { $0.append($1) }
        }
        #expect(counts.allSatisfy { $0 == 3 } && counts.count == 16)
    }

    @Test func sourceRankingToleratesTheSameSourceTwice() {
        let id = UUID()
        let h = SourceHealth(id: id, enabled: true, syncStatus: "ok", lastSync: nil, sortOrder: 0)
        #expect(PreferredSource.ranking([h, h])[id] == 0)
    }

    @Test func guideBannerKeepsTheSentenceAndTheButtonApart() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/REDDY/Features/TVGuide/Components/GuideFreshnessBanner.swift"), encoding: .utf8)
        #expect(!src.contains("children: .combine"), "combining reads 'programmes., Dismiss' as one run")
        for text in GuideMessages.text.values where text.hasSuffix(".") { #expect(!text.hasSuffix("..")) }
    }
}
