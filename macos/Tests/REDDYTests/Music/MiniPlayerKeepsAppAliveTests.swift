#if os(macOS)
import Testing
import Foundation
@testable import REDDY

/// Choosing the mini player hides the main window; the app used to quit because closing the last window quits it. The delegate must not end the app while the
/// mini player is open or handing over.
@Suite("Mini player keeps the app alive") struct MiniPlayerKeepsAppAliveTests {
    private static func source(_ rel: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { dir.deleteLastPathComponent() }
        return try String(contentsOf: dir.appendingPathComponent("Sources/REDDY/" + rel), encoding: .utf8)
    }

    @Test func theDelegateDoesNotQuitWhileTheMiniPlayerIsOpen() throws {
        let d = try Self.source("Application/AppDelegate.swift")
        #expect(d.contains("keepsAppAlive"), "the last-window rule must ask the mini player controller")
        #expect(!d.contains("applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }"))
    }

    @MainActor @Test func theControllerKeepsTheAppAliveOnlyWhileOpenOrHandingOver() throws {
        let m = try Self.source("Features/Music/MusicMiniPlayer.swift")
        #expect(m.contains("var keepsAppAlive: Bool { isOpen || transitioning }"))
        for fn in ["func open(hub: MusicHub)", "func close(showMain: Bool = true)", "func showMainWindow()"] {
            let body = try #require(m.components(separatedBy: fn).dropFirst().first?.prefix(260))
            #expect(body.contains("transitioning = true"), "\(fn) must mark the hand-over")
        }
        #expect(!MusicMiniPlayerController.shared.keepsAppAlive, "nothing is open in a test process")
    }
}
#endif
