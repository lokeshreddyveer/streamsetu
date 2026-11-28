import Testing
import Foundation
@testable import REDDY

/// "Add to Playlist…" sets `MusicChromeState.addToPlaylist` from many places; the shell must present the sheet for it. The sheet had no presenter (every
/// Add to Playlist button did nothing), so this keeps a presenter in the shell and the sheet type alive.
@Suite("Add to playlist is presented") struct AddToPlaylistPresentedTests {
    private static func source(_ rel: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { dir.deleteLastPathComponent() }     // Music, REDDYTests, Tests, macos
        return try String(contentsOf: dir.appendingPathComponent("Sources/REDDY/" + rel), encoding: .utf8)
    }

    @Test func theShellPresentsTheSheetForTheFlagTheButtonsSet() throws {
        let shell = try Self.source("Features/Music/MusicMainView.swift")
        #expect(shell.contains("chrome.addToPlaylist != nil"), "a sheet must open when addToPlaylist is set")
        #expect(shell.contains("MusicAddToPlaylistSheet(hub: hub, tracks: tracks"), "it must show the add-to-playlist sheet")
        #expect(shell.contains("chrome.addToPlaylist = nil"), "closing must clear the flag so the next tap opens again")
    }

    @Test func everyAddToPlaylistTriggerOnlySetsTheFlagTheShellPresents() throws {
        for file in ["Features/Music/Chrome/MusicContextMenus.swift", "Features/Music/MusicListKit.swift", "Features/Music/MusicDetailPages.swift", "Features/Music/Graph/Album/MusicSoundtrackHeaderSection.swift"] {
            let src = try Self.source(file)
            #expect(!src.contains("MusicAddToPlaylistSheet("), "\(file) must not present its own copy of the sheet (one presenter, no stacked sheets)")
        }
    }
}
