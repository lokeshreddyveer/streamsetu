import Testing
import Foundation
@testable import REDDY

// The Local files folder tree and the folders for playlists. Paths are fake; the only disk used is a temporary directory.

private func files(_ paths: [String]) -> [(path: String, id: String)] { paths.enumerated().map { (path: $0.element, id: "id\($0.offset)") } }
private let root = "/Users/someone/Music"

@Suite("Local folder tree") struct LocalFolderTreeTests {
    @Test func slashesAndEmptyNamesAreIgnored() {
        #expect(LocalFolderTree.components("/a//b/c/") == ["a", "b", "c"])
        #expect(LocalFolderTree.components("a/./b") == ["a", "b"])
        #expect(LocalFolderTree.components("") == [] && LocalFolderTree.components("/") == [])
        #expect(LocalFolderTree.relative(root + "/Album/x.mp3", roots: [root + "/"]) == ["Album", "x.mp3"])
        #expect(LocalFolderTree.relative("/elsewhere/x.mp3", roots: [root]) == nil)
        #expect(LocalFolderTree.relative(root, roots: [root]) == nil)
    }

    @Test func nestedFoldersAndFilesWithCounts() {
        let e = files([root + "/a.mp3", root + "/Rock/b.mp3", root + "/Rock/Live/c.mp3", root + "/Rock/Live/d.mp3", root + "/Jazz/e.mp3"])
        let top = LocalFolderTree.listing(roots: [root], entries: e, at: [])
        #expect(top.folders.map(\.name) == ["Jazz", "Rock"] && top.folders.map(\.trackCount) == [1, 3])
        #expect(top.files.map(\.name) == ["a.mp3"] && top.trackCount == 5 && !top.isEmpty)
        let rock = LocalFolderTree.listing(roots: [root], entries: e, at: ["Rock"])
        #expect(rock.folders.map(\.name) == ["Live"] && rock.files.map(\.name) == ["b.mp3"] && rock.trackCount == 3)
        let live = LocalFolderTree.listing(roots: [root], entries: e, at: ["Rock", "Live"])
        #expect(live.folders.isEmpty && live.files.count == 2)
    }

    @Test func namesSortNaturally() {
        let e = files([root + "/Track 10.mp3", root + "/Track 2.mp3", root + "/track 1.mp3", root + "/Disc 10/a.mp3", root + "/Disc 2/a.mp3"])
        let l = LocalFolderTree.listing(roots: [root], entries: e, at: [])
        #expect(l.files.map(\.name) == ["track 1.mp3", "Track 2.mp3", "Track 10.mp3"])
        #expect(l.folders.map(\.name) == ["Disc 2", "Disc 10"])
    }

    @Test func emptyAndMissingFoldersAreShownAsEmpty() {
        let none = LocalFolderTree.listing(roots: [root], entries: [], at: [])
        #expect(none.isEmpty && none.folders.isEmpty && none.files.isEmpty)
        let withDisk = LocalFolderTree.listing(roots: [root], entries: files([root + "/Rock/a.mp3"]), at: [], diskFolders: ["Rock", "Empty Folder"])
        #expect(withDisk.folders.map(\.name) == ["Empty Folder", "Rock"] && withDisk.folders.map(\.trackCount) == [0, 1])
        let gone = LocalFolderTree.listing(roots: [root], entries: files([root + "/a.mp3"]), at: ["Nope"])
        #expect(gone.isEmpty)
    }

    @Test func unicodeNamesMatchWhicheverWayTheyAreComposed() {
        let nfd = "Cafe\u{301}"            // as a disk may list it
        let nfc = "Caf\u{e9}"              // as it may be typed
        let e = files([root + "/" + nfd + "/song.mp3", root + "/ప్రేమ గీతాలు/పాట.mp3"])
        let l = LocalFolderTree.listing(roots: [root], entries: e, at: [nfc])
        #expect(l.files.map(\.name) == ["song.mp3"])
        let telugu = LocalFolderTree.listing(roots: [root], entries: e, at: ["ప్రేమ గీతాలు"])
        #expect(telugu.files.count == 1)
        let top = LocalFolderTree.listing(roots: [root], entries: e, at: [], diskFolders: [nfc])
        #expect(top.folders.count == 2)
    }

    @Test func aRootSpelledTwoWaysFindsTheFiles() {
        let e = files(["/private/var/m/Rock/a.mp3"])
        #expect(LocalFolderTree.listing(roots: ["/var/m", "/private/var/m"], entries: e, at: []).folders.map(\.name) == ["Rock"])
        #expect(LocalFolderTree.listing(roots: ["/var/m"], entries: e, at: []).trackCount == 0)
    }

    @Test func playingAFolderGoesFilesFirstThenEachSubfolderInOrder() {
        let e = files([root + "/Z/z1.mp3", root + "/A/a2.mp3", root + "/A/a10.mp3", root + "/top.mp3", root + "/A/B/ab.mp3"])
        let ids = LocalFolderTree.trackIDs(roots: [root], entries: e, at: [])
        let names = ids.map { id in e.first { $0.id == id }!.path.replacingOccurrences(of: root + "/", with: "") }
        #expect(names == ["top.mp3", "A/a2.mp3", "A/a10.mp3", "A/B/ab.mp3", "Z/z1.mp3"])
        #expect(LocalFolderTree.trackIDs(roots: [root], entries: e, at: ["A"]).count == 3)
        #expect(LocalFolderTree.trackIDs(roots: [root], entries: [], at: []).isEmpty)
    }

    @Test func breadcrumbsStartAtTheRoot() {
        let c = LocalFolderTree.breadcrumbs(rootName: "Music", path: ["Rock", "Live"])
        #expect(c.map(\.name) == ["Music", "Rock", "Live"] && c.map(\.path) == [[], ["Rock"], ["Rock", "Live"]])
    }

    @Test func aBigLibraryIsListedQuickly() {
        let e = files((0..<20_000).map { root + "/Artist \($0 % 200)/Album \($0 % 7)/\($0).mp3" })
        let l = LocalFolderTree.listing(roots: [root], entries: e, at: [])
        #expect(l.folders.count == 200 && l.trackCount == 20_000)
    }
}

@Suite("Playlist folders") struct PlaylistFolderTests {
    private func ids(_ n: Int) -> [UUID] { (0..<n).map { _ in UUID() } }

    @Test func createRenameAndDeleteKeepThePlaylists() {
        let p = ids(3)
        var f = MusicPlaylistFolderRules.creating("  Workout  ", in: [])
        #expect(f.map(\.name) == ["Workout"])
        f = MusicPlaylistFolderRules.creating("workout", in: f)
        f = MusicPlaylistFolderRules.creating("   ", in: f)
        #expect(f.count == 1)
        f = MusicPlaylistFolderRules.creating("Road trip", in: f)
        f = MusicPlaylistFolderRules.moving(p[0], to: f[0].id, in: f)
        f = MusicPlaylistFolderRules.moving(p[1], to: f[0].id, in: f)
        f = MusicPlaylistFolderRules.renaming(f[0].id, to: "Gym", in: f)
        #expect(f[0].name == "Gym")
        f = MusicPlaylistFolderRules.renaming(f[0].id, to: "road TRIP", in: f)
        #expect(f[0].name == "Gym")
        let deletedID = f[0].id
        f = MusicPlaylistFolderRules.deleting(deletedID, from: f)
        #expect(f.count == 1 && f[0].name == "Road trip")
        let all = p.map { LocalPlaylist(id: $0, name: "P") }
        #expect(MusicPlaylistFolderRules.playlists(all, in: nil, folders: f).count == 3)
        #expect(MusicPlaylistFolderRules.playlists(all, in: deletedID, folders: f).isEmpty)
    }

    @Test func aPlaylistIsInOneFolderAtMost() {
        let p = ids(1)[0]
        var f = MusicPlaylistFolderRules.creating("A", in: [])
        f = MusicPlaylistFolderRules.creating("B", in: f)
        f = MusicPlaylistFolderRules.moving(p, to: f[0].id, in: f)
        f = MusicPlaylistFolderRules.moving(p, to: f[1].id, in: f)
        #expect(f[0].playlistIDs.isEmpty && f[1].playlistIDs == [p])
        #expect(MusicPlaylistFolderRules.folder(of: p, in: f)?.name == "B")
        f = MusicPlaylistFolderRules.moving(p, to: nil, in: f)
        #expect(MusicPlaylistFolderRules.folder(of: p, in: f) == nil)
    }

    @Test func pruningForgetsDeletedPlaylistsAndDuplicates() {
        let p = ids(3)
        let a = MusicPlaylistFolder(name: "A", playlistIDs: [p[0], p[1], p[0]]), b = MusicPlaylistFolder(name: "B", playlistIDs: [p[1], p[2]])
        let out = MusicPlaylistFolderRules.pruned([a, b], existing: [p[0], p[1]])
        #expect(out[0].playlistIDs == [p[0], p[1]] && out[1].playlistIDs.isEmpty)
    }

    @Test func memberOrderFollowsTheLibraryOrder() {
        let p = ids(4)
        let all = p.map { LocalPlaylist(id: $0, name: "P") }
        let f = [MusicPlaylistFolder(name: "A", playlistIDs: [p[3], p[1]])]
        #expect(MusicPlaylistFolderRules.playlists(all, in: f[0].id, folders: f).map(\.id) == [p[1], p[3]])
    }

    @Test func oldFilesWithoutFoldersOrFieldsStillLoad() throws {
        let legacy = Data(#"{"id":"\#(UUID().uuidString)","name":"Old","tracks":[],"created":"2024-01-01T00:00:00Z"}"#.utf8)
        let dec = MusicJSONCoding.makeDecoder()
        let playlist = try dec.decode(LocalPlaylist.self, from: legacy)
        #expect(playlist.name == "Old")
        let partial = try JSONDecoder().decode([MusicPlaylistFolder].self, from: Data(#"[{"name":"Only a name"}]"#.utf8))
        #expect(partial.count == 1 && partial[0].playlistIDs.isEmpty)
    }

    @MainActor @Test func theBookStartsEmptyAndSurvivesARestart() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("folders-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = MusicPlaylistFolderBook(directory: dir, debounce: .milliseconds(5))
        #expect(first.folders.isEmpty)
        let p = UUID()
        first.create("Study")
        first.move(p, to: first.folders[0].id)
        first.flush()
        let second = MusicPlaylistFolderBook(directory: dir, debounce: .milliseconds(5))
        #expect(second.folders.count == 1 && second.folders[0].name == "Study" && second.folders[0].playlistIDs == [p])
        second.prune(existing: [])
        #expect(second.folders[0].playlistIDs.isEmpty)
        let r = second.revision
        second.create("study")
        #expect(second.revision == r)
    }

    @MainActor @Test func theLibraryExposesFoldersWithoutChangingItsOtherFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lib-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let lib = MusicLibrary(directory: dir, debounce: .milliseconds(5))
        let made = lib.createPlaylist(name: "Mix")
        lib.playlistFolders.create("Parties")
        lib.playlistFolders.move(made.id, to: lib.playlistFolders.folders[0].id)
        lib.playlistFolders.delete(lib.playlistFolders.folders[0].id)
        #expect(lib.playlists.map(\.id) == [made.id] && lib.playlistFolders.folders.isEmpty)
    }
}
