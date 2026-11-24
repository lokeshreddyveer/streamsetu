import Testing
import Foundation
@testable import REDDY

/// The Podcasts screens draw only from the theme: no literal colours, no system text styles, no controls that ignore the theme.
@Suite("Podcasts: theme tokens only") struct PodcastThemeTests {
    static let forbidden = ["Color(red", "Color(white", "Color(hex", "Color(.sRGB", "Color(.display", "NSColor", "UIColor", ".foregroundColor(", "#colorLiteral",
                            ".font(.body", ".font(.caption", ".font(.headline", ".font(.title", ".font(.callout", ".font(.footnote", ".font(.subheadline", ".font(.largeTitle",
                            ".buttonStyle(.bordered", ".pickerStyle(", "Slider(", "Picker(", "Toggle(", "ProgressView(value", ".tint(.", ".accentColor(", "Color.red", "Color.blue", "Color.green", "Color.gray", "Color.orange"]

    static func files() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/REDDY")
        let dir = root.appendingPathComponent("Features/Podcasts")
        return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
    }

    @Test func podcastViewsUseOnlyThemeTokens() throws {
        let files = try Self.files()
        #expect(files.count >= 6)
        var bad: [String] = []
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("//") || t.hasPrefix("///") { continue }
                for word in Self.forbidden where line.contains(word) { bad.append("\(f.lastPathComponent):\(i + 1) \(word)") }
                // .white and .black as colours, not as the start of .whitespaces
                let s = String(line)
                if s.range(of: #"\.(white|black)\b"#, options: .regularExpression) != nil { bad.append("\(f.lastPathComponent):\(i + 1) literal white/black") }
            }
        }
        #expect(bad.isEmpty, "hard-coded colours, fonts or untheme-able controls in the Podcasts files: \(bad)")
    }

    @Test func everyThemeHasUsableTokensForPodcasts() {
        let saved = ThemeStore.current; defer { ThemeStore.current = saved }
        for theme in AppTheme.allCases where theme != .custom {
            ThemeStore.current = theme
            // the cover rank badge and backdrop scrim rely on the theme's own background and text colours being different
            #expect(ColorTokens.background != ColorTokens.textPrimary, "\(theme.rawValue)")
        }
    }
}
