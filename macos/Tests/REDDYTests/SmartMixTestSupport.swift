import Foundation
import CryptoKit
@testable import REDDY

/// Loads the shared cross-language fixtures (smartmix/fixtures) and ports the documented synthetic generator.
enum SMFixtures {
    static var directory: URL {
        if let p = ProcessInfo.processInfo.environment["SMARTMIX_FIXTURES"] { return URL(fileURLWithPath: p, isDirectory: true) }
        // macos/Tests/REDDYTests/<this file> -> repository root
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { u.deleteLastPathComponent() }
        return u.appendingPathComponent("smartmix/fixtures", isDirectory: true)
    }

    static func json(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent(name + ".json"))
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    static var allCaseNames: [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.filter { $0 != "prng" && $0 != "features" }.sorted()
    }

    static func candidate(_ d: [String: Any]) -> SMCandidate {
        var c = SMCandidate(id: d["id"] as! String)
        if let k = d["kind"] as? String { c.kind = SMKind(rawValue: k)! }
        if let v = d["key"] as? String { c.key = v }
        c.year = d["year"] as? Int
        c.added = d["added"] as? Int
        c.rating = d["rating"] as? String
        if let v = d["q"] as? Int { c.q = v }
        if let v = d["cam"] as? Bool { c.cam = v }
        c.lang = d["lang"] as? String
        c.folder = d["folder"] as? String
        c.franchise = d["franchise"] as? String
        c.genre = d["genre"] as? String
        if let v = d["poster"] as? Bool { c.poster = v }
        if let v = d["backdrop"] as? Bool { c.backdrop = v }
        if let v = d["watched"] as? Bool { c.watched = v }
        if let v = d["completed"] as? Bool { c.completed = v }
        c.lastWatched = d["lastWatched"] as? Int
        if let v = d["p7"] as? Int { c.p7 = v }
        if let v = d["p30"] as? Int { c.p30 = v }
        if let v = d["restricted"] as? Bool { c.restricted = v }
        if let v = d["dismissed"] as? Bool { c.dismissed = v }
        if let v = d["src"] as? Int { c.src = v }
        return c
    }

    static func patch(_ c: inout SMCandidate, _ p: [String: Any]) {
        var d: [String: Any] = ["id": c.id]
        for (k, v) in p { d[k] = v }
        let patched = candidate(d)
        // Apply only the keys present in the patch.
        if p["restricted"] != nil { c.restricted = patched.restricted }
        if p["dismissed"] != nil { c.dismissed = patched.dismissed }
        if p["poster"] != nil { c.poster = patched.poster }
        if p["backdrop"] != nil { c.backdrop = patched.backdrop }
        if p["key"] != nil { c.key = patched.key }
        if p["watched"] != nil { c.watched = patched.watched }
    }

    static func affinity(_ d: [String: Any]?) -> SMAffinity {
        guard let d else { return SMAffinity() }
        return SMAffinity(topLangs: d["topLangs"] as? [String] ?? [], topFolders: d["topFolders"] as? [String] ?? [],
                          topGenres: d["topGenres"] as? [String] ?? [], topDecades: d["topDecades"] as? [Int] ?? [])
    }

    static func sha256Hex(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// SHA-256 over "<shelf>:" + ids joined by "\n" + "\n" for each shelf, in order.
    static func digest(_ results: [SMShelfResult]) -> String {
        var s = ""
        for r in results { s += r.shelfId + ":" + r.ids.joined(separator: "\n") + "\n" }
        return sha256Hex(s)
    }

    // MARK: synthetic generator (normative: smartmix/tools/smartmix_ref.py generate())
    static func generate(name: String, seed: Int, n: Int, folders: Int) -> [SMCandidate] {
        var g = SplitMix64(seed: SmartMixPRNG.fnv1a64("smartmix-gen1|\(name)|\(seed)".utf8))
        func u(_ k: Int) -> Int { Int(g.uniform(UInt64(k))) }
        let langs = ["Telugu", "Hindi", "English", "Tamil", "Malayalam", "Kannada"]
        let genres = ["action", "drama", "comedy", "thriller", "family", "horror", "romance", "scifi"]
        var out: [SMCandidate] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let series = u(100) < 27
            var c = SMCandidate(id: (series ? "s" : "m") + String(i))
            c.kind = series ? .series : .movie
            c.key = "t" + String(u(max(1, n * 4 / 5)))
            let y1 = u(36), y2 = u(36); c.year = 2026 - min(y1, y2)
            c.added = u(100) < 5 ? nil : u(700)
            switch u(20) {
            case 0: c.rating = ""
            case 1: c.rating = "0"
            case 2: c.rating = "10"
            case 3: c.rating = "10.0"
            default: let t = 30 + u(60); c.rating = "\(t / 10).\(t % 10)"
            }
            let r = u(100)
            if r < 8 { c.q = 0; c.cam = true } else if r < 15 { c.q = 1 } else if r < 45 { c.q = 2 } else if r < 75 { c.q = 3 } else if r < 92 { c.q = 4 } else { c.q = 5 }
            let a = u(6), b = u(6)
            c.lang = u(100) < 3 ? nil : langs[min(a, b)]
            let fa = u(folders), fb = u(folders); c.folder = "f" + String((fa * fb) / folders)
            c.franchise = u(100) < 20 ? "fr" + String(u(n / 50 + 1)) : nil
            let gi = u(8); c.genre = u(100) < 5 ? nil : genres[gi]
            c.poster = u(100) >= 12
            c.backdrop = u(100) < 55
            c.watched = u(100) < 6
            c.completed = c.watched ? u(100) < 70 : false
            let lw = u(120); c.lastWatched = c.watched ? lw : nil
            c.p7 = u(100) < 4 ? 1 + u(5) : 0
            c.p30 = c.p7 + (u(100) < 8 ? u(8) : 0)
            c.restricted = u(1000) < 8
            c.dismissed = u(1000) < 3
            c.src = u(2)
            out.append(c)
        }
        return out
    }

    static func generated(_ d: [String: Any]) -> [SMCandidate] {
        let g = d["generator"] as! [String: Any]
        return generate(name: g["name"] as! String, seed: g["seed"] as! Int, n: g["n"] as! Int, folders: g["folders"] as! Int)
    }

    static func library(_ d: [String: Any]) -> [SMCandidate] {
        if d["generator"] != nil { return generated(d) }
        return (d["library"] as! [[String: Any]]).map(candidate)
    }

    static func entries(_ arr: [[String: Any]]) -> [SMTrendingEntry] {
        arr.map { SMTrendingEntry(rank: $0["rank"] as! Int, type: $0["type"] as! String, title: $0["title"] as! String, original: $0["orig"] as? String, year: $0["year"] as? Int) }
    }
}

/// Collects a fixed list of values as the bit source (for the rejection branch of `uniform`).
struct StubBits: SmartMixBitSource {
    var values: [UInt64]
    var calls = 0
    mutating func next() -> UInt64 { defer { calls += 1 }; return values[calls] }
}

struct FixedKeys: SMTMDBKeyProvider { var apiKey: String? }
