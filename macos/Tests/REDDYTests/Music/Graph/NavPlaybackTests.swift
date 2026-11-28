import Foundation
import Testing
@testable import REDDY

@Suite("Music graph navigation never touches playback") struct NavPlaybackTests {
    /// The navigation and entity layers are plain values and models that never name the player, so no route change can reach it.
    @Test func theNavigationFilesDoNotReferenceThePlayer() throws {
        let tests = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        let graph = tests.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/REDDY/Services/Music/Graph", isDirectory: true)
        var scanned = 0
        for folder in ["Navigation", "Entity", "Bridge"] {
            let dir = graph.appendingPathComponent(folder, isDirectory: true)
            for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "swift" {
                let text = try String(contentsOf: f, encoding: .utf8)
                scanned += 1
                for banned in ["MusicPlayer", "hub.player", ".player.", "AVPlayer", "MusicHub"] {
                    #expect(!text.contains(banned), "\(f.lastPathComponent) mentions \(banned)")
                }
            }
        }
        #expect(scanned >= 8)
    }

    #if !G4_THROWAWAY
    @MainActor @Test func openingEntityRoutesLeavesThePlayerAlone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nav-playback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "nav.playback.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hub = MusicHub(directory: root, defaults: defaults)
        let p = hub.player
        let before = (p.queue, p.index, p.current, p.isPlaying, p.position)
        let film = MusicEntityID.provisional(kind: .film, providerUID: "p:film")
        hub.open(film); hub.open(MusicEntityID.provisional(kind: .person, providerUID: "p:person"), role: .composer)
        hub.open(collection: .composers); hub.open(album: MusicAlbum(id: "a", providerID: "p", title: "A")); hub.back(); hub.open(film)
        #expect(hub.nav.top?.entityID == film)
        #expect(p.queue == before.0 && p.index == before.1 && p.current == before.2 && p.isPlaying == before.3 && p.position == before.4)
    }

    @MainActor @Test func anAlbumWithNoIdOpensNothingAndAnArtistLinkTappedTwiceOpensOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nav-twice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "nav.twice.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hub = MusicHub(directory: root, defaults: defaults)
        let before = hub.nav.stack.count
        hub.open(album: MusicAlbum(id: "", providerID: "p", title: "No id"))
        #expect(hub.nav.stack.count == before)
        let artist = MusicArtist(id: "twice-1", providerID: "p", name: "Twice")
        hub.openArtist(artist, role: .singer)
        hub.openArtist(artist, role: .singer)
        for _ in 0..<100 where hub.nav.stack.count == before { try await Task.sleep(nanoseconds: 50_000_000) }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(hub.nav.stack.count == before + 1)
    }

    @MainActor @Test func theWatchBridgeSaysNotInLibraryUntilTheAppInstallsOne() {
        let film = MusicFilmWatchRef(tmdbID: 39039, title: "Awaara", year: 1951)
        MusicFilmWatchBridgeHost.shared.install(nil)
        #expect(!MusicFilmWatchBridgeHost.shared.isInLibrary(film))
        #expect(!MusicFilmWatchBridgeHost.shared.openMovie(film))
    }
    #endif
}
