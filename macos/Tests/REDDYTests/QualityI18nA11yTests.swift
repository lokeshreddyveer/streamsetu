import Testing
import Foundation
@testable import REDDY

/// Source scans and string-table parity. Reads a few small files; no UI.
@Suite("Localization and accessibility quality") struct QualityI18nA11yTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private func table(_ code: String) throws -> [String: String] {
        try #require(NSDictionary(contentsOf: Self.root.appendingPathComponent("Resources/Localization/\(code).lproj/Localizable.strings")) as? [String: String])
    }
    private func specifiers(_ s: String) -> [String] {
        let re = try! NSRegularExpression(pattern: "%(\\d+\\$)?(@|d|lld|ld|f|\\.\\df|%)")
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }.filter { $0 != "%%" }
    }

    @Test func hindiAndTeluguKeepTheEnglishFormatSpecifiers() throws {
        let hi = try table("hi"), te = try table("te")
        for (k, v) in hi { #expect(specifiers(k).sorted() == specifiers(v).sorted(), "hi: \(k)") }
        for (k, v) in te { #expect(specifiers(k).sorted() == specifiers(v).sorted(), "te: \(k)") }
    }

    @Test func hindiAndTeluguValuesAreActuallyInTheirScripts() throws {
        func share(_ t: [String: String], _ r: ClosedRange<UInt32>) -> Double {
            let vals = t.filter { $0.key.count > 12 && !$0.key.contains("TMDB") }.values
            let hit = vals.filter { $0.unicodeScalars.contains { r.contains($0.value) } }.count
            return Double(hit) / Double(max(1, vals.count))
        }
        #expect(share(try table("hi"), 0x0900...0x097F) > 0.8)
        #expect(share(try table("te"), 0x0C00...0x0C7F) > 0.8)
    }

    /// An icon-only button reads as "button" to VoiceOver unless it carries a label. One-line `Button ... Image(systemName:)` with no text, label, help or accessibility call.
    @Test func iconOnlyButtonsOnOneLineCarryALabel() throws {
        let dir = Self.root.appendingPathComponent("Sources/REDDY")
        var offenders: [String] = []
        let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)!
        for case let u as URL in en where u.pathExtension == "swift" {
            guard let text = try? String(contentsOf: u, encoding: .utf8), text.contains("Image(systemName:") else { continue }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (i, line) in lines.enumerated() where line.contains("Button") && line.contains("Image(systemName:") {
                let l = lines[i..<min(i + 12, lines.count)].joined(separator: " ")      // the modifiers may sit on the next lines
                if l.contains("Text(") || l.contains("Label(") || l.contains("accessibilityLabel") || l.contains(".help(") || l.contains("accessibilityHidden") || l.contains("\\(") && l.contains("Localized") { continue }
                offenders.append("\(u.lastPathComponent):\(i + 1)")
            }
        }
        #expect(offenders.isEmpty, "icon-only buttons without a label: \(offenders.prefix(20))")
    }
}
