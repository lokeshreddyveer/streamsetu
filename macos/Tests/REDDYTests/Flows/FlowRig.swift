import Testing
import Foundation
@testable import REDDY

/// A real Music hub on a temporary folder, with every audio source switched off, so a flow test drives the real player, queue and library without any
/// network: a song that is started fails to resolve quietly in the background, and the test only looks at what the person would see at once.
@MainActor
final class FlowRig {
    let hub: MusicHub
    private let root: URL
    private let suite: String

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("flow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "flow.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        hub = MusicHub(directory: root, defaults: defaults)
        for p in hub.registry.all { hub.registry.setEnabled(false, id: p.id, reason: .setup) }
        hub.library.settings.consentDone = true
    }

    func cleanup() {
        hub.player.stop()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    var player: MusicPlayer { hub.player }

    /// `n` songs of `minutes` minutes each, ids `prefix0`, `prefix1`, ...
    static func songs(_ n: Int, minutes: Int = 4, prefix: String = "f", provider: String = "flow") -> [MusicTrack] {
        (0..<n).map { i in
            MusicTrack(id: "\(prefix)\(i)", providerID: provider, title: "Flow song \(i)", durationMs: Int64(minutes) * 60_000,
                       artists: [MusicArtistRef(id: "artist\(i % 3)", name: "Flow artist \(i % 3)")])
        }
    }

    /// The id of the queue row the bar is showing.
    var shownRowID: UUID? { player.index.flatMap { player.rows.indices.contains($0) ? player.rows[$0].id : nil } }
}
