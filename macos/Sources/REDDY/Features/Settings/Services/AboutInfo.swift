import Foundation

struct AboutInfo: Sendable {
    var version = AppConfiguration.version
    var build = AppConfiguration.build
    var macOS = ProcessInfo.processInfo.operatingSystemVersionString
    var minimumMacOS = "macOS 14 or later"
    var architecture = DiagnosticsService.architecture
    var schemaVersion = 0
    var mpvVersion: String?
    var ffmpegVersion: String?
    var bundledLibraries: [String] = []

    static func bundledLibraryNames() -> [String] {
        guard let dir = Bundle.main.privateFrameworksURL,
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return items.map(\.lastPathComponent).filter { $0.hasSuffix(".dylib") }.sorted()
    }

    static let notices = """
    REDDY is a player. It contains no channels, films or series; it plays the playlists you add.

    Playback engines
    • Apple AVFoundation — part of macOS.
    • libmpv with FFmpeg and its codec libraries — included in this build when "MPV" is listed as available. This build of libmpv is licensed under the GNU General Public License, version 2 or later; FFmpeg is licensed under the LGPL/GPL depending on how it was built. Source code and license texts for these libraries are published by their projects (mpv.io, ffmpeg.org).

    Data and privacy
    • Your library, favorites and history are stored only on this Mac.
    • Logins are stored in your Keychain.
    • REDDY sends no analytics or telemetry.

    Update notice
    • StreamSetu checks the public release page for new versions and asks before installing one. Only the version number is requested; nothing about you is sent.
    """
}
