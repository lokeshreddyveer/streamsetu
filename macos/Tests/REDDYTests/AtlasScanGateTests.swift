import Foundation
import Testing
@testable import REDDY

/// Gate (a): runs Scripts/check-atlas.sh (the swift-syntax scan lives in its own package). Warn-only for now: it must run and report, not yet fail on unmarked controls.
@Suite(.serialized) struct AtlasScanGateTests {
    /// The Mac folders are finished, so the gate is strict for them: a new control without `.atlas("id")` or a reasoned exemption fails here. (The iPhone and iPad folders stay warn-only in the test below.)
    @Test func macControlsAreAllMarkedOrExempt() throws {
        let (status, text) = try Self.runScan(["--strict", "--only", "macos/"])
        #expect(status == 0, "\(text)")
        #expect(text.contains(", 0 unmarked;"), "\(text)")
    }

    @Test func scanRunsAndReportsBaseline() throws {
        let (status, text) = try Self.runScan([])
        #expect(status == 0, "\(text)")
        #expect(text.contains("atlas-scan:") && text.contains("exemptions:"), "\(text)")
    }

    static func runScan(_ args: [String]) throws -> (Int32, String) {
        let macos = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [macos.appendingPathComponent("Scripts/check-atlas.sh").path] + args
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Every id a marker names (`.atlas("id")`, `.atlasCovers("id")`, `atlas: "id"`, `.atlasScreen("id")`) in the Mac sources is a real Atlas entry, so a typo cannot hide a control.
    @MainActor @Test func everyMarkerNamesARealEntry() throws {
        let macos = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = macos.appendingPathComponent("Sources/REDDY")
        let ids = Set(Atlas.entries.map(\.id))
        var missing: [String] = []
        for f in try FileManager.default.subpathsOfDirectory(atPath: root.path) where f.hasSuffix(".swift") && !f.hasPrefix("Atlas/") {
            let text = try String(contentsOf: root.appendingPathComponent(f), encoding: .utf8)
            for m in text.matches(of: /(?:\.atlas|\.atlasCovers|\.atlasScreen)\("([^"]+)"\)|atlas: "([^"]+)"/) {
                let id = String(m.1 ?? m.2 ?? "")
                if !id.isEmpty, !ids.contains(id) { missing.append("\(id) in \(f)") }
            }
        }
        #expect(missing.isEmpty, "markers naming no Atlas entry: \(Set(missing).sorted())")
    }
}
