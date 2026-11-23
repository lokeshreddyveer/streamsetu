import Testing
import Foundation
@testable import REDDY

/// The offline alias index, checked against the fixtures the other platforms read too (artwork/fixtures/alias-index-mini.tsv, alias-cases.json).
@Suite("Alias index") struct AliasIndexTests {
    private func fx(_ n: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("artwork/fixtures/" + n)
    }
    private func index() throws -> AliasIndex { try #require(AliasIndex(data: Data(contentsOf: fx("alias-index-mini.tsv")))) }

    @Test func keysFollowTheSharedRules() throws {
        let j = try JSONSerialization.jsonObject(with: Data(contentsOf: fx("alias-cases.json"))) as! [String: Any]
        for p in j["keys"] as! [[String]] { #expect(AliasKey.make(p[0]) == p[1], Comment(rawValue: p[0])) }
    }

    @Test func lookupsFollowTheSharedCases() throws {
        let idx = try index()
        let j = try JSONSerialization.jsonObject(with: Data(contentsOf: fx("alias-cases.json"))) as! [String: Any]
        for c in j["cases"] as! [[String: Any]] {
            let name = c["name"] as! String, series = c["series"] as! Bool
            let got = idx.resolve(name, isSeries: series)
            let tag = Comment(rawValue: "\(name) series=\(series)")
            if let e = c["expect"] as? [String: Any] {
                #expect(got?.0.tmdbID == e["id"] as? Int && got?.1.rawValue == e["tier"] as? String, tag)
            } else { #expect(got == nil, tag) }
        }
    }

    @Test func aGzipFileLoadsLikeThePlainOne() throws {
        let plain = try Data(contentsOf: fx("alias-index-mini.tsv"))
        let gz = try Data(contentsOf: fx("alias-index-mini.tsv.gz"))
        let a = try #require(AliasIndex(data: plain)), b = try #require(AliasIndex(data: gz))
        #expect(a.count == b.count && a.count == 20)
        #expect(b.exact("The Dark Knight", isSeries: false)?.tmdbID == 155)
    }

    @Test func editWithinOne() {
        func w(_ a: String, _ b: String) -> Bool { AliasIndex.withinOneEdit(Array(a.utf8), Array(b.utf8)) }
        #expect(w("abc", "abc") && w("abc", "abd") && w("abc", "ab") && w("abc", "abxc") && w("a", "") && !w("abc", "axd") && !w("abc", "a") && !w("abc", "abcde"))
    }
}

/// Opt in with STREAMSETU_ALIASES=<file>: prints size, load time, phonetic build time, memory and lookup latency of a real index.
@Suite("Alias index measurements (opt in)") struct AliasIndexMeasureTests {
    @Test func measure() throws {
        guard let path = ProcessInfo.processInfo.environment["STREAMSETU_ALIASES"] else { return }
        func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var t = now()
        let idx = try #require(AliasIndex(data: data))
        let load = now() - t
        t = now(); _ = idx.phonetic("Bahubali The Beginning", isSeries: false); let build = now() - t
        var ex: [Double] = [], ph: [Double] = []
        for q in ["Baahubali The Beginning", "Dark", "The Matrix", "Kasauti Zindagi Kay", "Zindagi Na Milegi Dobara", "Parasite"] { t = now(); _ = idx.exact(q, isSeries: false); ex.append(now() - t); t = now(); _ = idx.phonetic(q + "x", isSeries: false); ph.append(now() - t) }
        print("ALIASMEASURE file=\(data.count)B lines=\(idx.count) resident=\(idx.residentBytes)B phonetic=\(idx.phoneticBytes)B load=\(Int(load))ms phoneticBuild=\(Int(build))ms exactMaxMs=\(ex.max()!) phoneticMaxMs=\(ph.max()!)")
    }
}
