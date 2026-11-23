import Testing
import Foundation
@testable import REDDY

/// Writes the imported entries to the report folder (ATLAS_REPORT_DIR) so the bank and the review pass can be done against what really exists.
@MainActor @Suite("Atlas: dump", .serialized) struct AtlasDumpTests {
    @Test func dumpEntries() throws {
        struct Row: Encodable { let id: String; let kind: String; let title: String; let aliases: [String]; let summary: String; let detail: String?; let path: [String]; let reviewed: Bool; let safety: String; let guideOnly: Bool; let platforms: Int; let shortcut: String?; let settingKey: String?; let options: [String] }
        let rows = AtlasFixture.entries.map { Row(id: $0.id, kind: $0.kind.rawValue, title: $0.title, aliases: $0.aliases, summary: $0.summary, detail: $0.detail, path: $0.path, reviewed: $0.reviewed, safety: $0.safety.rawValue, guideOnly: $0.guideOnly, platforms: $0.platforms.rawValue, shortcut: $0.shortcut, settingKey: $0.value?.settingKey, options: $0.value?.options ?? []) }
        let data = try JSONEncoder().encode(rows)
        try FileManager.default.createDirectory(at: AtlasFixture.reportDir, withIntermediateDirectories: true)
        try data.write(to: AtlasFixture.reportDir.appendingPathComponent("atlas-entries.json"))
        #expect(rows.count > 500)
    }
}
