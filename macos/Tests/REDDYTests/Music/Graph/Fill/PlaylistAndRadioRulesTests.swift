import Foundation
import Testing
@testable import REDDY

@Suite struct PlaylistAndRadioRulesTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func ago(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }

    @Test func onRepeatIsTop20OfThirtyDaysTiesByRecency() {
        var songs: [MusicSmartSong] = []
        for i in 0..<25 { songs.append(MusicSmartSong(uid: "s\(i)", plays: Array(repeating: Self.ago(2), count: 30 - i))) }
        songs.append(MusicSmartSong(uid: "old", plays: Array(repeating: Self.ago(40), count: 99)))        // outside the window
        songs.append(MusicSmartSong(uid: "local", plays: Array(repeating: Self.ago(1), count: 99), isLocal: true))
        let top = MusicSmartPlaylists.onRepeat(songs, now: Self.now)
        #expect(top.count == 20); #expect(top.first == "s0"); #expect(!top.contains("old") && !top.contains("local"))
        let tie = [MusicSmartSong(uid: "a", plays: [Self.ago(5)]), MusicSmartSong(uid: "b", plays: [Self.ago(1)])]
        #expect(MusicSmartPlaylists.onRepeat(tie, now: Self.now) == ["b", "a"])
    }

    @Test func listsAreOfferedFromFiveSongsAndCanBeDismissed() {
        let few = (0..<4).map { MusicSmartSong(uid: "n\($0)") }
        #expect(MusicSmartPlaylists.lists(few, now: Self.now).isEmpty)
        let five = (0..<5).map { MusicSmartSong(uid: "n\($0)", addedAt: Self.ago(Double($0))) }
        let l = MusicSmartPlaylists.lists(five, now: Self.now)
        #expect(Set(l.map(\.kind)) == [.neverPlayed, .recentlyAdded])
        #expect(l.first { $0.kind == .recentlyAdded }?.songs == ["n0", "n1", "n2", "n3", "n4"])
        #expect(MusicSmartPlaylists.lists(five, now: Self.now, dismissed: [.neverPlayed]).map(\.kind) == [.recentlyAdded])
    }

    @Test func recentlyAddedFallsBackToListOrderWhenNoDates() {
        let songs = (0..<40).map { MusicSmartSong(uid: "l" + String($0), order: $0) }
        let r = MusicSmartPlaylists.recentlyAdded(songs, now: Self.now)
        #expect(r.count == 30); #expect(r.first == "l0"); #expect(r.last == "l29")
    }

    @Test func forgottenFavouritesNeedLikeOrManyPlaysAndSilence() {
        let songs = [MusicSmartSong(uid: "liked-old", plays: [Self.ago(200)], liked: true),
                     MusicSmartSong(uid: "often-old", plays: [Self.ago(300), Self.ago(250), Self.ago(200)]),
                     MusicSmartSong(uid: "liked-new", plays: [Self.ago(3)], liked: true),
                     MusicSmartSong(uid: "once-old", plays: [Self.ago(300)]),
                     MusicSmartSong(uid: "never", plays: [], liked: true)]
        #expect(MusicSmartPlaylists.forgottenFavourites(songs, now: Self.now) == ["often-old", "liked-old"])
    }

    @Test func hopDedupesDemotesHeardAndSpacesArtists() {
        let cands = [MusicHopCandidate(id: "a", artist: "x"), MusicHopCandidate(id: "b", artist: "x"), MusicHopCandidate(id: "c", artist: "x"), MusicHopCandidate(id: "d", artist: "y"),
                     MusicHopCandidate(id: "a", artist: "x"), MusicHopCandidate(id: "q"), MusicHopCandidate(id: "blocked", blocked: true)]
        let heard = ["b": Self.ago(3), "d": Self.ago(31)]
        let r = MusicRadioHygiene.nextHop(cands, queued: ["q"], lastHeard: heard, now: Self.now)
        #expect(!r.ids.contains("q") && !r.ids.contains("blocked"))
        #expect(r.ids.filter { $0 == "a" }.count == 1)
        #expect(r.ids.last == "b", "heard within 30 days goes last")
        #expect(r.demoted == 1)
        #expect(r.ids.firstIndex(of: "d")! < r.ids.firstIndex(of: "b")!, "heard 31 days ago is not demoted")
        // no artist x three in a row
        var run = 0, maxRun = 0, last: String?
        for id in r.ids { let a = cands.first { $0.id == id }?.artist; run = (a != nil && a == last) ? run + 1 : 1; last = a; maxRun = max(maxRun, run) }
        #expect(maxRun <= 2)
        let capped = MusicRadioHygiene.nextHop((0..<50).map { MusicHopCandidate(id: "k\($0)") }, queued: [], lastHeard: [:], now: Self.now)
        #expect(capped.ids.count == 20)
    }

    @Test func hopEscalatesWhenEverythingWasHeard() {
        let cands = [MusicHopCandidate(id: "a"), MusicHopCandidate(id: "b")]
        let r = MusicRadioHygiene.nextHop(cands, queued: [], lastHeard: ["a": Self.ago(1), "b": Self.ago(2)], now: Self.now)
        #expect(r.escalated); #expect(r.ids == ["a", "b"])
        #expect(MusicRadioHygiene.nextHop(cands, queued: ["a", "b"], lastHeard: [:], now: Self.now).ids.isEmpty)
    }

    @Test func autoplayRowsRemoveAsAGroupAndComeBack() {
        let q = [MusicRadioHygiene.QueueRow(id: "own1", isAutoplay: false, isPlaying: true), .init(id: "own2", isAutoplay: false), .init(id: "auto1", isAutoplay: true), .init(id: "auto2", isAutoplay: true)]
        let (rest, removed) = MusicRadioHygiene.removeAutoplayGroup(q)
        #expect(rest.map(\.id) == ["own1", "own2"]); #expect(removed.map(\.id) == ["auto1", "auto2"])
        let back = MusicRadioHygiene.restore(removed.enumerated().map { (index: 2 + $0.offset, row: $0.element) }, into: rest)
        #expect(back == q)
    }

    static let items: [MusicPlaylistItem] = [
        .init(uid: "1", title: "Track 10", artist: "b", album: "Z", plays: 1), .init(uid: "2", title: "track 2", artist: "a", album: nil, plays: 9),
        .init(uid: "3", title: "Track 1", artist: "a", album: "A", plays: 9), .init(uid: "4", title: "Another", artist: "c", album: "Z", plays: 0)]

    @Test func sortRules() {
        func ids(_ k: MusicPlaylistSortKey, desc: Bool = false) -> [String] { MusicPlaylistRules.sorted(Self.items, by: k, descending: desc).map(\.uid) }
        #expect(ids(.default) == ["1", "2", "3", "4"])
        #expect(ids(.title) == ["4", "3", "2", "1"], "natural numbers, case-insensitive")
        #expect(ids(.artist) == ["3", "2", "1", "4"], "artist ties break on title")
        #expect(ids(.album) == ["3", "1", "4", "2"], "grouped by album, in-album order kept, no album last")
        #expect(ids(.mostPlayed) == ["2", "3", "1", "4"], "ties keep playlist order")
        #expect(ids(.title, desc: true) == ["1", "2", "3", "4"])
        #expect(ids(.oldest) == ["1", "2", "3", "4"]); #expect(ids(.newest) == ["4", "3", "2", "1"])
        #expect(MusicPlaylistRules.sorted(Self.items, by: .oldest, sourceListsNewestFirst: true).map(\.uid) == ["4", "3", "2", "1"])
    }

    @Test func reorderRulesAndDrop() {
        #expect(MusicPlaylistRules.reorderAllowed(owned: true, sort: .default, flipped: false, filterActive: false, selecting: false))
        for bad in [(false, MusicPlaylistSortKey.default, false, false, false), (true, .title, false, false, false), (true, .default, true, false, false), (true, .default, false, true, false), (true, .default, false, false, true)] {
            #expect(!MusicPlaylistRules.reorderAllowed(owned: bad.0, sort: bad.1, flipped: bad.2, filterActive: bad.3, selecting: bad.4))
        }
        #expect(MusicPlaylistRules.dropIndex(row: 3, pointerY: 10, rowMidY: 20) == 3)
        #expect(MusicPlaylistRules.dropIndex(row: 3, pointerY: 30, rowMidY: 20) == 4)
        #expect(MusicPlaylistRules.move(["a", "b", "c", "d"], from: 0, toGap: 3) == ["b", "c", "a", "d"])
        #expect(MusicPlaylistRules.move(["a", "b", "c", "d"], from: 3, toGap: 1) == ["a", "d", "b", "c"])
        let r = MusicPlaylistRules.adding(["b", "x", "x"], to: ["a", "b"])
        #expect(r.list == ["a", "b", "x"]); #expect(r.added == 1); #expect(r.duplicates == 2)
    }

    @Test func everyDestructiveEditCanBeUndone() {
        var log = MusicPlaylistEditLog()
        let start = ["a", "b", "c", "d", "e"]
        var list = log.remove(["b", "d"], from: start)
        #expect(list == ["a", "c", "e"])
        list = log.reorder(["e", "c", "a"], from: list)
        list = log.clear(list); #expect(list.isEmpty)
        list = log.add(["z", "a"], to: ["a"]); #expect(list == ["a", "z"])
        list = log.undo(list); #expect(list == ["a"])          // add undone (only the new one leaves)
        list = log.undo(["x"]); #expect(list == ["e", "c", "a"]) // clear undone
        list = log.undo(list); #expect(list == ["a", "c", "e"])  // reorder undone
        list = log.undo(list); #expect(list == start)           // removal undone at the original positions
        #expect(!log.canUndo)
        for i in 0..<30 { _ = log.clear(["x\(i)"]) }
        #expect(log.stack.count == MusicPlaylistEditLog.capacity)
    }

    @Test func lookAheadIsBounded() {
        #expect(MusicHomeLookAhead.pagesToWalk(rankedKeys: ["a", "b"], loaded: ["a", "b"], pagesWalked: 0) == 0)
        #expect(MusicHomeLookAhead.pagesToWalk(rankedKeys: ["a", "b"], loaded: ["a"], pagesWalked: 0) == 6)
        #expect(MusicHomeLookAhead.pagesToWalk(rankedKeys: ["a", "b"], loaded: ["a"], pagesWalked: 4) == 2)
        #expect(MusicHomeLookAhead.pagesToWalk(rankedKeys: ["a", "b"], loaded: [], pagesWalked: 6) == 0)
    }

    @Test func aLocalPlaylistOfTheAlbumsSongsIsATileThatOpensIt() async throws {
        let f = try await FillFixture.make()
        let album = try await f.g.upsert(MusicEntityDraft(kind: .release, name: "Awaara (local only)", year: 1951)).id
        let uuid = UUID()
        let other = MusicAlbumConnections.LocalPlaylist(id: UUID().uuidString, name: "Elsewhere", songUIDs: ["z"])
        let mine = MusicAlbumConnections.LocalPlaylist(id: uuid.uuidString, name: "Mine", songUIDs: ["x"])
        let r = await MusicAlbumConnections.build(album: album, store: f.g, songUIDs: ["x": f.song2], localPlaylists: [mine, other])
        let tiles = r.shelves.first { $0.id == "album.appearsOn" }?.tiles ?? []
        #expect(tiles.filter { $0.localPlaylistID != nil }.map(\.localPlaylistID) == [uuid.uuidString])
        #expect(tiles.first { $0.localPlaylistID == uuid.uuidString }?.title == "Mine")
    }

    @Test func albumPageHasEditionsMoreByAndAppearsOn() async throws {
        let f = try await FillFixture.make()
        // an edition of the soundtrack, a compilation holding song2 (already: plainAlbum), a Telugu dub of the same film, and a playlist link exists in the fixture
        let group = try await f.g.upsert(MusicEntityDraft(kind: .album, name: "Awaara", subkind: "album")).id
        let deluxe = try await f.g.upsert(MusicEntityDraft(kind: .release, name: "Awaara (Deluxe)", year: 2012)).id
        let rel1 = try await f.g.upsert(MusicEntityDraft(kind: .release, name: "Awaara (1951 release)", year: 1951)).id
        for r in [rel1, deluxe] { _ = try await f.g.addEdge(MusicEdge(subject: r, predicate: .editionOf, object: group), provenance: FillFixture.src) }
        _ = try await f.g.addEdge(MusicEdge(subject: rel1, predicate: .soundtrackOf, object: f.film), provenance: FillFixture.src)
        _ = try await f.g.addEdge(MusicEdge(subject: rel1, predicate: .musicDirectedBy, object: f.sj, role: .musicDirector), provenance: FillFixture.src)
        _ = try await f.g.addEdge(MusicEdge(subject: f.song2, predicate: .trackOn, object: rel1), provenance: FillFixture.src)
        let dub = try await f.g.upsert(MusicEntityDraft(kind: .album, name: "Awaara (Telugu)", subkind: "soundtrack", lang: "te")).id
        _ = try await f.g.addEdge(MusicEdge(subject: dub, predicate: .soundtrackOf, object: f.film), provenance: FillFixture.src)
        let other = try await f.g.upsert(MusicEntityDraft(kind: .album, name: "Shree 420 OST", year: 1955)).id
        _ = try await f.g.addEdge(MusicEdge(subject: other, predicate: .musicDirectedBy, object: f.sj, role: .musicDirector), provenance: FillFixture.src)
        let r = await MusicAlbumConnections.build(album: rel1, store: f.g, localPlaylists: [.init(id: "L", name: "Mine", songUIDs: ["x"])])
        let ed = r.shelves.first { $0.id == "album.editions" }
        let edIDs = Set((ed?.tiles ?? []).map(\.entity))
        #expect(edIDs.isSuperset(of: [deluxe, dub]))
        #expect(ed?.tiles.contains { $0.entity == rel1 } == false)
        #expect(!edIDs.contains(group), "the album the release is an edition of is the album itself, not another edition")
        let more = r.shelves.first { $0.id == "album.moreByArtist" }
        let moreTitle = more?.title ?? ""
        #expect(["More by Shankar-Jaikishan", "More by the artist"].contains(moreTitle), "named after one person only when every album on the shelf is theirs (the rule is tested in AlbumPageGaps tests)")
        #expect(more?.tiles.contains { $0.entity == other } == true)
        let appears = r.shelves.first { $0.id == "album.appearsOn" }
        let ids = Set((appears?.tiles ?? []).map(\.entity))
        #expect(ids.contains(f.plainAlbum)); #expect(ids.contains(f.playlist))
    }
}
