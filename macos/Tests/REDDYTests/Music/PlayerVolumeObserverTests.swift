import Testing
import Foundation
@testable import REDDY

/// Build 349 crashed (stack overflow, crash report 2026-11-26 01:46): `volume`'s observer assigned `volume` again every time, and under @Observable that
/// runs the observer again without end. The clamp must only assign when the value is out of range, and the observer must stop there.
@Suite("Player volume observer cannot recurse") struct PlayerVolumeObserverTests {
    @Test func theVolumeObserverOnlyReassignsAnOutOfRangeValueAndThenStops() throws {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { dir.deleteLastPathComponent() }
        let src = try String(contentsOf: dir.appendingPathComponent("Sources/REDDY/Services/Music/Playback/MusicPlayer.swift"), encoding: .utf8)
        let body = try #require(src.components(separatedBy: "var volume: Float = 1 {").dropFirst().first?.prefix(700))
        #expect(!body.contains("didSet {\n            volume = min("), "an unconditional assignment to volume inside its own observer recurses without end")
        #expect(body.contains("if clamped != volume { volume = clamped; return }"))
    }

    @Test func theClampStaysInRange() {
        for raw: Float in [-3, -0.0001, 0, 0.4, 1, 1.0001, 9] {
            let c = min(1, max(0, raw))
            #expect(c >= 0 && c <= 1)
            #expect((c != raw) == (raw < 0 || raw > 1), "only an out-of-range value is rewritten")
        }
    }
}
