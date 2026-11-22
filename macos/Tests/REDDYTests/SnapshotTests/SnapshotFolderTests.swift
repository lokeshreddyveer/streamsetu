import Testing
import SwiftUI
import AppKit
@testable import REDDY

/// Folder rows and the new Home on several themes (opt-in, same harness as SnapshotTests).
extension SnapshotTests {
    static let themes: [AppTheme] = [.cinematic, .nord, .solarized, .crimson, .piano]

    @Test func folderScreensAndHomeAcrossThemes() async throws {
        let size = CGSize(width: 1280, height: 800)
        for theme in Self.themes {
            let tag = theme.rawValue.replacingOccurrences(of: " ", with: "-").lowercased()
            let h = try scene(); h.container.settings.theme = theme
            try await capture(shell(h), size: size, settle: 3.5, name: "b-home-\(tag)")
            let m = try scene(tab: .movies, .shortcut(.allMovies)); m.container.settings.theme = theme
            try await capture(shell(m), size: size, settle: 3.5, name: "b-movies-folders-\(tag)")
            let s = try scene(tab: .series, .shortcut(.library)); s.container.settings.theme = theme
            try await capture(shell(s), size: size, settle: 3.5, name: "b-series-folders-\(tag)")
            let l = try scene(tab: .liveTV, .shortcut(.allChannels)); l.container.settings.theme = theme
            try await capture(shell(l), size: size, settle: 3, name: "b-live-folders-\(tag)")
        }
    }
}
