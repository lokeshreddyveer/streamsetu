import Testing
import Foundation
@testable import REDDY

// Local files index, music links, and plugin update diffs. Pure logic only: no folders are read, no network, no socket.

private func entry(_ title: String, _ artist: String, _ album: String, track: Int? = nil, ms: Int64 = 200_000, path: String? = nil, folder: String = "f1", modified: Double = 1000) -> LocalEntry {
    let p = path ?? "/music/\(artist)/\(album)/\(title).mp3"
    return LocalEntry(id: LocalLibraryIndex.trackID(path: p), folderID: folder, path: p, title: title, artist: artist, album: album, trackNumber: track,
                      durationMs: ms, modified: Date(timeIntervalSince1970: modified), artworkFile: nil, ext: "mp3")
}

@Suite struct LocalIndexTests {
    let index = LocalLibraryIndex(entries: [
        entry("Intro", "Les Étoiles", "Night Drive", track: 1), entry("Highway", "Les Étoiles", "Night Drive", track: 2),
        entry("Morning", "Solo Act", "Dawn", track: 1),
    ])

    @Test func groupsAlbumsAndArtistsFromTags() {
        #expect(index.albums().count == 2)
        #expect(index.artists().count == 2)
        #expect(index.albums().first { $0.title == "Night Drive" }?.entries.map(\.title) == ["Intro", "Highway"])
    }

    @Test func searchIgnoresCaseAndAccents() {
        let hits = index.search("etoiles night")
        #expect(hits.tracks.count == 2)
        #expect(hits.artists.count == 1)
        #expect(index.search("zzz").tracks.isEmpty)
        #expect(index.search("   ").tracks.isEmpty)
    }

    @Test func matchFindsLocalCopyOfAnotherSourcesTrack() {
        #expect(index.match(title: "highway", artist: "Les Etoiles", durationMs: 201_000)?.title == "Highway")
        #expect(index.match(title: "Highway", artist: "Someone Else", durationMs: nil) == nil)
    }

    @Test func idsAreStable() {
        #expect(LocalLibraryIndex.artistID("Solo Act") == LocalLibraryIndex.artistID("solo  act"))
        #expect(LocalLibraryIndex.trackID(path: "/a.mp3") != LocalLibraryIndex.trackID(path: "/b.mp3"))
    }

    @Test func incrementalPlanReadsOnlyChanges() {
        let known: [String: Date] = ["/a": Date(timeIntervalSince1970: 10), "/b": Date(timeIntervalSince1970: 10), "/gone": Date(timeIntervalSince1970: 10)]
        let found: [String: Date] = ["/a": Date(timeIntervalSince1970: 10), "/b": Date(timeIntervalSince1970: 99), "/new": Date(timeIntervalSince1970: 5)]
        let plan = LocalLibraryIndex.plan(known: known, found: found)
        #expect(plan.toRead == ["/b", "/new"])
        #expect(plan.removed == ["/gone"])
    }

    @Test func applyReplacesChangedAndDropsRemoved() {
        var idx = LocalLibraryIndex(entries: [entry("A", "X", "Y", path: "/p/a.mp3"), entry("B", "X", "Y", path: "/p/b.mp3"), entry("Other", "Z", "Q", path: "/o.mp3", folder: "f2")])
        idx.apply(folderID: "f1", read: [entry("A2", "X", "Y", path: "/p/a.mp3")], removed: ["/p/b.mp3"])
        #expect(idx.entries.map(\.title).sorted() == ["A2", "Other"])
        idx.removeFolder("f1")
        #expect(idx.entries.count == 1)
    }

    @Test func tagTextHelpers() {
        #expect(LocalTagText.trackNumber("3/12") == 3)
        #expect(LocalTagText.trackNumber(" 07 ") == 7)
        #expect(LocalTagText.trackNumber("x") == nil)
        #expect(LocalTagText.title(fromFileName: "07 - Song Name.mp3") == "Song Name")
        #expect(LocalTagText.title(fromFileName: "1999.mp3") == "1999")
    }

    @Test func providerTracksCarryFileStreams() {
        let p = LocalFilesProvider(store: LocalLibraryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("local-\(UUID().uuidString)")))
        let t = p.track(index.entries[0])
        #expect(t.providerID == "local")
        #expect(t.directStreams?.first?.url.hasPrefix("file://") == true)
        #expect(t.album?.title == "Night Drive")
    }
}

@Suite struct MusicLinkTests {
    @Test func parsesOwnLinks() {
        let t = MusicDeepLinks.parse(URL(string: "streamsetu://music/album/audius/abc123")!)
        #expect(t == MusicLinkTarget(kind: .album, providerID: "audius", id: "abc123"))
        #expect(MusicDeepLinks.parse(URL(string: "streamsetu:///music/track/jiosaavn/x_9")!)?.kind == .track)
    }

    @Test func rejectsBadShapes() {
        for s in ["streamsetu://music/song/audius/a", "streamsetu://music/album/AUDIUS/a", "streamsetu://music/album/audius/a%2F..%2Fb",
                  "streamsetu://music/album/audius", "streamsetu://music/album/audius/a/extra", "streamsetu://play?channel=x", "https://evil.example/music/album/audius/a",
                  "streamsetu://music/album/au dius/a"] {
            #expect(URL(string: s).flatMap { MusicDeepLinks.parse($0) } == nil, "\(s)")
        }
    }

    @Test func mapsSpotifyLinks() {
        let t = MusicDeepLinks.parse(URL(string: "https://open.spotify.com/intl-de/track/4uLU6hMCjMI75M1A2tKUQC?si=abc")!)
        #expect(t == MusicLinkTarget(kind: .track, providerID: "spotify", id: "4uLU6hMCjMI75M1A2tKUQC"))
        #expect(MusicDeepLinks.parse(text: "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M")?.kind == .playlist)
        #expect(MusicDeepLinks.parse(URL(string: "https://open.spotify.com.evil.com/track/4uLU6hMCjMI75M1A2tKUQC")!) == nil)
        #expect(MusicDeepLinks.parse(URL(string: "https://open.spotify.com/user/abc")!) == nil)
    }

    @Test func buildsLinksThatRoundTrip() {
        let target = MusicLinkTarget(kind: .artist, providerID: "youtube-music", id: "UC-abc_123")
        let url = MusicDeepLinks.link(target)
        #expect(url?.absoluteString == "streamsetu://music/artist/youtube-music/UC-abc_123")
        #expect(url.flatMap { MusicDeepLinks.parse($0) } == target)
        #expect(MusicDeepLinks.link(MusicLinkTarget(kind: .track, providerID: "x", id: "a/b")) == nil)
    }
}

@Suite struct PluginUpdateTests {
    private func manifest(_ v: String, hosts: [String] = [], storage: Bool = false, caps: [MusicPluginCapability] = [.metadata]) -> MusicPluginManifest {
        MusicPluginManifest(id: "demo", name: "Demo", version: v, capabilities: caps, permissions: MusicPluginPermissions(networkHosts: hosts, storage: storage))
    }

    @Test func versionOrder() {
        #expect(MusicVersion.isNewer("1.10.0", than: "1.9.2"))
        #expect(!MusicVersion.isNewer("1.0", than: "1.0.0"))
        #expect(!MusicVersion.isNewer("0.9", than: "1.0"))
    }

    @Test func diffHighlightsNewAccess() {
        let d = MusicManifestDiff.compute(old: manifest("1.0.0", hosts: ["a.com"]), new: manifest("1.1.0", hosts: ["a.com", "b.com"], storage: true, caps: [.metadata, .audio]))
        #expect(d.addedHosts == ["b.com"])
        #expect(d.addedPermissions == ["Private storage"])
        #expect(d.addedCapabilities == ["audio"])
        #expect(d.widensAccess)
        let same = MusicManifestDiff.compute(old: manifest("1.0.0", hosts: ["a.com"]), new: manifest("1.0.1", hosts: []))
        #expect(!same.widensAccess)
        #expect(same.removedHosts == ["a.com"])
    }

    @Test func feedNeedsNewerVersionAndHttps() {
        let ok = Data(#"{"version":"2.0.0","package":"https://x.example/p.sbplugin"}"#.utf8)
        #expect(MusicPluginUpdates.offerURL(from: ok, installedVersion: "1.0.0")?.host == "x.example")
        #expect(MusicPluginUpdates.offerURL(from: ok, installedVersion: "2.0.0") == nil)
        let http = Data(#"{"version":"2.0.0","package":"http://x.example/p.sbplugin"}"#.utf8)
        #expect(MusicPluginUpdates.offerURL(from: http, installedVersion: "1.0.0") == nil)
    }

    @Test func weeklyCheckIsOffByDefaultAndSpacedByAWeek() {
        let now = Date()
        #expect(!MusicPluginUpdates.isDue(last: nil, now: now, enabled: false))
        #expect(MusicPluginUpdates.isDue(last: nil, now: now, enabled: true))
        #expect(!MusicPluginUpdates.isDue(last: now.addingTimeInterval(-3600), now: now, enabled: true))
        #expect(MusicPluginUpdates.isDue(last: now.addingTimeInterval(-8 * 86_400), now: now, enabled: true))
    }
}
