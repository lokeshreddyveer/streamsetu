import Testing
import Foundation
@testable import REDDY

/// Every screen shows the one rating rule (RatingRule / DisplayRating). A new place that parses a stored rating by hand (Double(x.rating), CAST(rating AS REAL)) would let tiles, pages, the hero,
/// Discover and Setu disagree, so this scan fails on it. A file that must read a raw rating (a parser that builds it, the rule itself) goes on the exemptions list with its reason.
@Suite("Rating reads") struct RatingReadScanTests {
    private static var repoRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    /// File name -> why a raw read is allowed there.
    static let exemptions: [String: String] = [
        "DisplayTitles.swift": "defines RatingRule, including the SQL form of the rule",
        "SmartMixScoring.swift": "defines the grammar RatingRule is built on",
    ]

    static let rawPatterns: [String] = [
        #"Double\([^)]*[rR]ating"#,                 // Double(m.rating ?? ""), Double(s.rating)
        #"[rR]ating[^\n]{0,40}\.flatMap\(?\s*Double"#,   // m.rating.flatMap(Double.init)
        #"CAST\([^)]*rating[^)]*AS REAL\)"#,        // SQL ordering or filtering by the raw text
    ]

    private func swiftFiles() -> [URL] {
        var out: [URL] = []
        for sub in ["macos/Sources/REDDY", "ios/StreamSetu"] {
            let root = Self.repoRoot.appendingPathComponent(sub)
            guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            out += en.allObjects.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        }
        return out
    }

    @Test func noRawRatingReadsOutsideTheRule() throws {
        let files = swiftFiles()
        #expect(files.count > 100, "the scan found the source tree")
        let regexes = try Self.rawPatterns.map { try NSRegularExpression(pattern: $0) }
        var offenders: [String] = []
        for f in files where Self.exemptions[f.lastPathComponent] == nil {
            let text = try String(contentsOf: f, encoding: .utf8)
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let s = String(line)
                if s.trimmingCharacters(in: .whitespaces).hasPrefix("//") || s.contains("RatingRule.") { continue }
                let range = NSRange(s.startIndex..., in: s)
                if regexes.contains(where: { $0.firstMatch(in: s, range: range) != nil }) { offenders.append("\(f.lastPathComponent):\(i + 1)") }
            }
        }
        #expect(offenders.isEmpty, "raw rating read; use RatingRule.credible / DisplayRating (or RatingRule.sqlValue): \(offenders)")
    }

    @Test func exemptionsStillExist() {
        let names = Set(swiftFiles().map(\.lastPathComponent))
        for (name, _) in Self.exemptions { #expect(names.contains(name), "\(name) is on the exemptions list but no longer exists") }
    }

    @Test func sqlRuleAgreesWithTheSwiftRuleOnJunk() throws {
        let db = try TestSupport.makeDB()
        let samples = ["0", "0.0", "10", "10.0", "", "abc", "7.5", "9.9", "0.1", "8", "+8"]
        let rows: [(String, Double)] = try db.read { c in
            try samples.map { s in
                let v = try c.query("SELECT \(RatingRule.sqlValue("r")) FROM (SELECT ? AS r)", [s]) { $0.double(0) }.first ?? -1
                return (s, v)
            }
        }
        for (s, v) in rows {
            if let credible = RatingRule.credible(s) { #expect(v == credible, "\(s)") } else if s != "+8" { #expect(v == 0, "\(s) is junk to both") }
        }
    }
}
