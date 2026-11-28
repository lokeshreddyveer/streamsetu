import Foundation
import Testing
import AVFoundation
@testable import REDDY

/// Proves the header fix through AVFoundation itself: a recorded YouTube Music audio file (fragmented MP4) is measured twice, as served and with its first
/// bytes passed through `MusicMP4Header.neutraliseDurations` (what the proxy relay and the ranged download do). Nothing is played: only the length is read.
/// Needs the recordings the length work kept in the temporary folder (`lenlive`); without them the test records "skipped".
@Suite("Length fix through the real file reader") struct LengthRealFileTests {
    private static func recordings() -> [URL] {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lenlive", isDirectory: true)
        let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.pathExtension == "m4a" && !$0.lastPathComponent.contains(".fixed") && !$0.lastPathComponent.hasPrefix("x_") && $0.lastPathComponent != "patched.m4a" }.sorted { $0.path < $1.path }
    }

    @Test func aServedHeaderMeasuresTheRealLengthNotDouble() async throws {
        var checked = 0
        for url in Self.recordings().prefix(8) {
            let data = try Data(contentsOf: url)
            var head = Data(data.prefix(65_536))
            guard MusicMP4Header.neutraliseDurations(in: &head, fileOffset: 0) else { continue }   // not one of the affected files
            let fixed = FileManager.default.temporaryDirectory.appendingPathComponent("len-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: fixed) }
            try (head + data.dropFirst(head.count)).write(to: fixed)
            let before = try await AVURLAsset(url: url).load(.duration).seconds
            let after = try await AVURLAsset(url: fixed).load(.duration).seconds
            #expect(after > 30 && after < 900, "\(url.lastPathComponent): \(after) s")
            #expect(before > after * 1.8 && before < after * 2.2, "\(url.lastPathComponent): served \(before) s, fixed \(after) s")
            checked += 1
        }
        if checked == 0 { Issue.record("skipped: no recorded fragmented MP4 under the temporary folder (lenlive)") }
    }
}
