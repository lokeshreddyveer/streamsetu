import Foundation
@testable import REDDY

/// Shared by the Atlas tests: the imported entries, built once.
@MainActor enum AtlasFixture {
    static let entries: [AtlasEntry] = Atlas.entries
    static let engine = SetuEngine(entries: entries)
    nonisolated static var resourceDir: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources") }

    /// Where reports are written: ATLAS_REPORT_DIR, else the temp folder. Never inside the repository.
    nonisolated static var reportDir: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["ATLAS_REPORT_DIR"] ?? NSTemporaryDirectory(), isDirectory: true)
    }
}
