import Testing
import Foundation
import MachO
@testable import REDDY

private func rssMB() -> Double {
    var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
    return r == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
}

/// Opt-in: STREAMSETU_BENCH=1 swift test --filter ArtworkQueueBench. A synthetic library the size of the owner's (66,540 films, 18,011 series, about 5% without a poster); no real data is read.
@Suite("Artwork queue benchmark (opt-in)", .serialized, .enabled(if: ProcessInfo.processInfo.environment["STREAMSETU_BENCH"] != nil))
struct ArtworkQueueBenchTests {
    @Test func queueBuildCostOnTheOwnerSizedLibrary() throws {
        let db = try TestSupport.makeDB()
        let src = try TestSupport.makeSource(db)
        let cats = (0..<60).map { CatalogCategory(id: "c\($0)", sourceID: src.id, kind: .movie, providerID: "c\($0)", name: "FOLDER \($0)", sortOrder: $0) }
        let scats = (0..<30).map { CatalogCategory(id: "s\($0)", sourceID: src.id, kind: .series, providerID: "s\($0)", name: "SERIES \($0)", sortOrder: $0) }
        var t0 = Date()
        do {
            let ms: [Movie] = (0..<66_540).map { i in
                var m = TestSupport.movie(src, "m\(i)", "Synthetic Film \(i) (\(1980 + i % 44))", year: 1980 + i % 44)
                m.categoryID = "c\(i % 60)"; m.categoryName = "FOLDER \(i % 60)"; m.overview = "A summary."
                m.posterURL = i % 20 == 0 ? nil : "https://img.example/p\(i).jpg"; m.addedAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(i)); return m }
            _ = try CatalogIndexer(db: db).commitMovies(source: src, categories: cats, movies: ms)
        }
        do {
            let ss: [Series] = (0..<18_011).map { i in
                var s = TestSupport.series(src, "s\(i)", "Synthetic Show \(i)"); s.categoryID = "s\(i % 30)"; s.overview = "A summary."
                s.posterURL = i % 20 == 0 ? nil : "https://img.example/s\(i).jpg"; return s }
            _ = try CatalogIndexer(db: db).commitSeries(source: src, categories: scats, series: ss)
        }
        print("BENCH build library: \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        let creds = InMemoryCredentialStore(); try creds.save(Credentials(username: "tmdb", password: "0123456789abcdef0123456789abcdef"), ref: MetadataMatchService.keyRef)
        let svc = MetadataMatchService(db: db, credentials: creds, defaults: InMemoryDefaults(), builtIn: { nil }) { _ in Data() }
        let before = rssMB()
        t0 = Date(); let count = try svc.pendingCount(); let tCount = Date().timeIntervalSince(t0)
        t0 = Date(); let first = try svc.pending(limit: 60); let tFirst = Date().timeIntervalSince(t0)
        var exclude = Set(first.items.map(\.id)); var worst = 0.0
        for _ in 0..<20 { t0 = Date(); let p = try svc.pending(limit: 60, excluding: exclude); worst = max(worst, Date().timeIntervalSince(t0)); exclude.formUnion(p.items.map(\.id)) }
        t0 = Date(); _ = svc.lookedUpCounts(); let tCounts = Date().timeIntervalSince(t0)
        print("BENCH waiting titles: \(count); count query \(String(format: "%.0f", tCount * 1000)) ms; first 60-title page \(String(format: "%.0f", tFirst * 1000)) ms; worst of next 20 pages \(String(format: "%.0f", worst * 1000)) ms; looked-up counts \(String(format: "%.0f", tCounts * 1000)) ms; memory +\(String(format: "%.1f", rssMB() - before)) MB; queue holds ids and titles of at most 60 rows")
        #expect(count > 4_000 && first.items.count == 60)
    }
}
