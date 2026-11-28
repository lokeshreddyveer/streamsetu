import Testing
import Foundation
@testable import REDDY

@Suite("Music chrome logic") struct ChromeLogicTests {
    // MARK: settings search

    @Test func everyBlockShownInSettingsHasAnIndexEntry() {
        let anchors = Set(MusicSettingsSearch.index.map(\.anchor))
        for a in MusicSettingsSearch.blockAnchors { #expect(anchors.contains(a), "no index entry for \(a)") }
        for t in MusicSettingsTab.allCases { #expect(MusicSettingsSearch.index.contains { $0.id == "tab." + t.rawValue }) }
    }

    @Test func searchNeedsEveryTermAndRanksTitleFirst() {
        let g = MusicSettingsSearch.search("crossfade", in: MusicSettingsSearch.index)
        #expect(g.first?.tab == .playback)
        #expect(g.first?.entries.first?.title == "Crossfade")
        #expect(MusicSettingsSearch.search("crossfade zzzz", in: MusicSettingsSearch.index).isEmpty)
        #expect(MusicSettingsSearch.search("   ", in: MusicSettingsSearch.index).isEmpty)
    }

    @Test func searchMatchesDescriptionAndKeywords() {
        let byKeyword = MusicSettingsSearch.search("last.fm", in: MusicSettingsSearch.index)
        #expect(byKeyword.contains { $0.tab == .plugins })
        let entry = MusicSettingsEntry(id: "a", tab: .general, title: "Alpha", detail: "beta gamma", section: "Delta", keywords: ["epsilon"], anchor: "a")
        #expect(MusicSettingsSearch.rank(entry, terms: ["alpha"]) == 0)
        #expect(MusicSettingsSearch.rank(entry, terms: ["alp"]) == 1)
        #expect(MusicSettingsSearch.rank(entry, terms: ["lph"]) == 2)
        #expect(MusicSettingsSearch.rank(entry, terms: ["gamma"]) == 3)
        #expect(MusicSettingsSearch.rank(entry, terms: ["epsilon", "delta"]) == 3)
        #expect(MusicSettingsSearch.rank(entry, terms: ["nothing"]) == nil)
    }

    @Test func groupsFollowTheirBestHit() {
        let list = [
            MusicSettingsEntry(id: "1", tab: .privacy, title: "Zoom level", anchor: "x"),
            MusicSettingsEntry(id: "2", tab: .general, title: "A zoom note", anchor: "y"),
            MusicSettingsEntry(id: "3", tab: .playback, title: "Zoom", anchor: "z")
        ]
        let g = MusicSettingsSearch.search("zoom", in: list)
        #expect(g.map(\.tab) == [.playback, .privacy, .general])
    }

    // MARK: friendly errors

    @Test func deadNetworkWordingBecomesOneSentence() {
        #expect(MusicFriendlyErrors.rewrite("error sending request for url (https://x)") == MusicFriendlyErrors.unreachable)
        #expect(MusicFriendlyErrors.rewrite("Loading Home: dns error: failed to lookup address") == "Loading Home: " + MusicFriendlyErrors.unreachable)
        #expect(MusicFriendlyErrors.rewrite("HTTP 404") == "HTTP 404")
        #expect(MusicFriendlyErrors.message(for: URLError(.notConnectedToInternet)) == MusicFriendlyErrors.unreachable)
        #expect(MusicFriendlyErrors.message(for: MusicError.network("connection reset by peer")) == MusicFriendlyErrors.unreachable)
        #expect(MusicFriendlyErrors.message(for: MusicError.notFound) == "Nothing found.")
        #expect(MusicFriendlyErrors.isOffline(URLError(.timedOut)))
        #expect(!MusicFriendlyErrors.isOffline(MusicError.notFound))
    }

    // MARK: retry ladder

    @Test func ladderWaitsTwoFourEightFifteenThenThirty() {
        var l = MusicRetryLadder()
        let t0 = Date(timeIntervalSince1970: 1_000)
        var waits: [TimeInterval] = []
        for i in 0..<10 { if let w = l.next(now: t0.addingTimeInterval(Double(i))) { waits.append(w) } }
        #expect(waits == [2, 4, 8, 15, 30, 30, 30, 30, 30, 30])
        #expect(l.next(now: t0.addingTimeInterval(11)) == nil)
    }

    @Test func aQuietFiveMinutesStartsTheLadderOver() {
        var l = MusicRetryLadder()
        let t0 = Date(timeIntervalSince1970: 1_000)
        _ = l.next(now: t0); _ = l.next(now: t0.addingTimeInterval(2))
        #expect(l.next(now: t0.addingTimeInterval(2 + 301)) == 2)
    }

    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var _online = false, _slept: [TimeInterval] = [], _retried = 0
        var online: Bool { lock.lock(); defer { lock.unlock() }; return _online }
        var slept: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return _slept }
        var retried: Int { lock.lock(); defer { lock.unlock() }; return _retried }
        func sleep(_ s: TimeInterval) { lock.lock(); _slept.append(s); if _slept.count == 3 { _online = true }; lock.unlock() }
        func retry() { lock.lock(); _retried += 1; lock.unlock() }
    }

    @MainActor @Test func offlineRetryOnlyReloadsWhenTheConnectionIsBack() async {
        let p = Probe()
        let r = MusicOfflineRetry(isOnline: { p.online }, sleep: { p.sleep($0) }, now: { Date() })
        r.arm { p.retry() }
        for _ in 0..<500 where p.retried == 0 { try? await Task.sleep(nanoseconds: 2_000_000) }
        #expect(p.slept == [2, 4, 8])
        #expect(p.retried == 1)
        #expect(!r.waiting)
    }

    // MARK: toasts

    @Test func toastTimingsAreTheSameForErrors() {
        #expect(MusicToasts.duration(hasAction: false) == 2.5)
        #expect(MusicToasts.duration(hasAction: true) == 8)
    }

    // MARK: link parser

    @Test func youTubeLinksParse() {
        #expect(MusicLinkParser.parse("https://music.youtube.com/watch?v=abcdefghijk&list=PLx1234567890") == .youTubeTrack(id: "abcdefghijk", startSeconds: nil))
        #expect(MusicLinkParser.parse("youtu.be/abcdefghijk?t=90") == .youTubeTrack(id: "abcdefghijk", startSeconds: 90))
        #expect(MusicLinkParser.parse("https://www.youtube.com/watch?v=abcdefghijk&start=1m30s") == .youTubeTrack(id: "abcdefghijk", startSeconds: 90))
        #expect(MusicLinkParser.parse("music.youtube.com/playlist?list=VLPLx1234567890") == .youTubePlaylist(id: "PLx1234567890"))
        #expect(MusicLinkParser.parse("https://music.youtube.com/channel/UCabc123") == .youTubeArtist(id: "UCabc123"))
        #expect(MusicLinkParser.parse("https://music.youtube.com/browse/MPREb_abc123") == .youTubeAlbum(id: "MPREb_abc123"))
        #expect(MusicLinkParser.parse("https://music.youtube.com/browse/VLPLabc123") == .youTubePlaylist(id: "PLabc123"))
        #expect(MusicLinkParser.parse("https://music.youtube.com/browse/UCabc123") == .youTubeArtist(id: "UCabc123"))
        #expect(MusicLinkParser.parse("https://music.youtube.com/browse/FEmusic_home") == nil)
    }

    @Test func spotifyAndOwnLinksParseAndOthersDoNot() {
        let t = MusicLinkParser.parse("https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC")
        #expect(t == .known(MusicLinkTarget(kind: .track, providerID: "spotify", id: "4uLU6hMCjMI75M1A2tKUQC")))
        #expect(MusicLinkParser.parse("open.spotify.com/album/4uLU6hMCjMI75M1A2tKUQC") != nil)
        #expect(MusicLinkParser.parse("spotify:artist:4uLU6hMCjMI75M1A2tKUQC") != nil)
        #expect(MusicLinkParser.parse("https://example.com/watch?v=abc") == nil)
        #expect(MusicLinkParser.parse("hello world") == nil)
        #expect(MusicLinkParser.parse("") == nil)
    }

    @Test func startOffsetsAndLaunchArguments() {
        #expect(MusicLinkParser.startOffset("90") == 90)
        #expect(MusicLinkParser.startOffset("1h2m3s") == 3723)
        #expect(MusicLinkParser.startOffset("0") == nil)
        #expect(MusicLinkParser.startOffset("abc") == nil)
        let args = ["-psn_0_1", "open", "https://music.youtube.com/watch?v=abcdefghijk", "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC"]
        if case .known(let k)? = MusicLinkParser.firstLink(inArguments: args) { #expect(k.providerID == "spotify") } else { Issue.record("a Spotify link wins") }
        #expect(MusicLinkParser.firstLink(inArguments: ["-x", "open"]) == nil)
    }

    // MARK: context menus

    @Test func trackMenuFollowsItsConditions() {
        var c = MusicTrackMenuContext(hasArtistID: true, hasArtistName: true, hasAlbumID: true, canRadio: true)
        let full = MusicMenuLogic.trackItems(c)
        #expect(full.prefix(2) == [.playNext, .addToQueue])
        #expect(full.contains(.goToArtist) && full.contains(.goToAlbum) && full.contains(.share) && full.contains(.blockArtist))
        #expect(!full.contains(.editScrobble))
        c.scrobblerConnected = true; c.scrobblingOn = true
        #expect(MusicMenuLogic.trackItems(c).contains(.editScrobble))
        c.hostRemoveLabel = "Remove from queue"
        #expect(MusicMenuLogic.trackItems(c).contains(.hostRemove("Remove from queue")))
    }

    @Test func localFilesAndLinksOnlyVariantsHideTheRightItems() {
        let local = MusicMenuLogic.trackItems(MusicTrackMenuContext(isLocal: true, hasArtistID: true, hasAlbumID: true))
        for gone in [MusicTrackMenuItem.startRadio, .like, .dislike, .saveToLibrary, .blockArtist, .goToAlbum, .share] { #expect(!local.contains(gone)) }
        #expect(local.contains(.playNext) && local.contains(.goToArtist) && local.contains(.saveToPlaylist))
        let links = MusicMenuLogic.trackItems(MusicTrackMenuContext(linksOnly: true, hostRemoveLabel: "x"))
        #expect(!links.contains(.playNext) && !links.contains(.addToQueue) && links.contains(.effects))
        #expect(!links.contains { if case .hostRemove = $0 { true } else { false } })
    }

    @Test func playNextMovesInsteadOfDuplicating() {
        let q = ["a", "b", "c", "d"]
        #expect(MusicMenuLogic.playNextPlan(queue: q, index: 0, uid: "z") == .insert)
        #expect(MusicMenuLogic.playNextPlan(queue: q, index: 0, uid: "c") == .moveFrom(2))
        #expect(MusicMenuLogic.playNextPlan(queue: q, index: 0, uid: "b") == .alreadyNext)
        #expect(MusicMenuLogic.playNextPlan(queue: q, index: 2, uid: "a") == .insert)
        #expect(MusicMenuLogic.playNextPlan(queue: [], index: nil, uid: "a") == .insert)
    }

    @Test func queueRowIsFoundAgainAfterPositionsShift() {
        #expect(MusicMenuLogic.resolveRow(queue: ["a", "x", "b", "x"], uid: "x", near: 3) == 3)
        #expect(MusicMenuLogic.resolveRow(queue: ["a", "x", "b"], uid: "x", near: 5) == 1)
        #expect(MusicMenuLogic.resolveRow(queue: ["a"], uid: "x", near: 0) == nil)
        #expect(MusicMenuLogic.canRemoveFromPlayingPlaylist(queueFromPlaylist: true, rowIsPlaylistRow: true, playlistHolds: true))
        #expect(!MusicMenuLogic.canRemoveFromPlayingPlaylist(queueFromPlaylist: true, rowIsPlaylistRow: false, playlistHolds: true))
    }

    @Test func cardMenusByKind() {
        let album = MusicMenuLogic.cardItems(.init(kind: .album))
        #expect(album.first == .playAndShuffle && album.contains(.saveToLibrary) && !album.contains(.pin))
        #expect(MusicMenuLogic.cardItems(.init(kind: .playlist)).contains(.pin))
        #expect(MusicMenuLogic.cardItems(.init(kind: .playlist, isPinned: true)).contains(.unpin))
        let artist = MusicMenuLogic.cardItems(.init(kind: .artist))
        #expect(!artist.contains(.playNext) && artist.contains(.blockArtist))
        let local = MusicMenuLogic.cardItems(.init(kind: .album, isLocal: true))
        #expect(!local.contains(.share) && !local.contains(.startRadio))
        #expect(MusicMenuLogic.cardItems(.init(kind: .album, libraryState: .savedOnService)).contains(.inLibrary))
        #expect(MusicMenuLogic.canPin(count: 2) && !MusicMenuLogic.canPin(count: 3))
    }

    @Test func addToPlaylistCountsDuplicates() {
        func t(_ id: String) -> MusicTrack { MusicTrack(id: id, providerID: "p", title: id, durationMs: 1000, artists: []) }
        let p1 = LocalPlaylist(id: UUID(), name: "One", tracks: [t("a")], created: Date())
        let p2 = LocalPlaylist(id: UUID(), name: "Two", tracks: [], created: Date())
        let plan = MusicMenuLogic.addPlan(tracks: [t("a"), t("b")], chosen: [p1, p2])
        #expect(plan.duplicatesByPlaylist[p1.id] == 1 && plan.duplicatesByPlaylist[p2.id] == 0)
        #expect(plan.skipAdds == 3 && plan.needsDuplicateStep)
        #expect(!MusicMenuLogic.addPlan(tracks: [t("b")], chosen: [p1]).needsDuplicateStep)
        #expect(MusicMenuLogic.addToast(added: 0, duplicates: 1, playlists: ["One"], songCount: 1).contains("One"))
    }

    @Test func selectionBarRemoveNeedsTwoPresses() {
        var bar = MusicMenuLogic.SelectionBar(selectedCount: 2)
        #expect(!bar.pressRemove() && bar.armedRemove)
        bar.selectionChanged(to: 3)
        #expect(!bar.armedRemove)
        _ = bar.pressRemove()
        let confirmed = bar.pressRemove()
        #expect(confirmed)
    }

    // MARK: back and forward

    @Test func depthFollowsTheSpecRules() {
        var d = MusicNavDepth()
        #expect(!d.canGoBack && !d.canGoForward)
        d.navigated(); d.navigated()
        #expect(d.depth == 2 && d.canGoBack && !d.canGoForward)
        d.step(-1)
        #expect(d.depth == 1 && d.canGoForward)
        d.navigated()
        #expect(d.depth == 2 && d.deepest == 2 && !d.canGoForward)
        d.step(-5); #expect(d.depth == 0)
        d.reset(); #expect(d.deepest == 0)
    }

    // MARK: share, comments, drag, haptics

    @Test func shareStartTimeRules() {
        #expect(MusicShareStart.evaluate(text: "1:23", enabled: true, durationSeconds: 200) == .at(83))
        #expect(MusicShareStart.evaluate(text: "1:23", enabled: false, durationSeconds: 200) == .off)
        #expect(MusicShareStart.evaluate(text: "abc", enabled: true, durationSeconds: 200) == .unparsable)
        #expect(MusicShareStart.evaluate(text: "5:00", enabled: true, durationSeconds: 200) == .tooLong(limitSeconds: 200))
        #expect(MusicShareStart.parse("1:75") == nil && MusicShareStart.parse("1:02:03") == 3723)
        let u = MusicShareStart.link(URL(string: "streamsetu://music/track/p/x")!, start: .at(83))
        #expect(u.absoluteString.hasSuffix("?t=83"))
        #expect(MusicShareStart.clock(3723) == "1:02:03" && MusicShareStart.clock(83) == "1:23")
    }

    @Test func commentsRules() {
        func thread(_ id: String) -> YTMCommentThread { YTMCommentThread(comment: YTMComment(id: id, text: "t", published: "", author: YTMCommentAuthor(name: "n"))) }
        let merged = MusicCommentsLogic.appended([thread("a"), thread("b")], [thread("b"), thread("c")])
        #expect(merged.map(\.id) == ["a", "b", "c"])
        #expect(!MusicCommentsLogic.followsPlaying(hasDraft: true, sending: false) && MusicCommentsLogic.followsPlaying(hasDraft: false, sending: false))
        #expect(MusicCommentsLogic.needsClamp(String(repeating: "x", count: 281)) && !MusicCommentsLogic.needsClamp("short"))
        var c = YTMComment(id: "1", text: "", published: "", author: YTMCommentAuthor(name: "n"))
        c.likeCountLiked = "6"; c.likeCountNotLiked = "5"; c.likeAction = "L"; c.unlikeAction = "U"
        #expect(MusicCommentsLogic.likeCount(c) == "5" && MusicCommentsLogic.likeToken(c) == "L")
        c.vote = .liked
        #expect(MusicCommentsLogic.likeCount(c) == "6" && MusicCommentsLogic.likeToken(c) == "U")
        #expect(MusicCommentsLogic.voteAfterLike(.disliked) == .liked)
    }

    @Test func dragScrollRampsLinearlyAndCapsCatchUp() {
        #expect(MusicDragAndDrop.scrollSpeed(pointerY: 500, height: 1000) == 0)
        #expect(MusicDragAndDrop.scrollSpeed(pointerY: 0, height: 1000) == -1800)
        #expect(MusicDragAndDrop.scrollSpeed(pointerY: 48, height: 1000) == -900)
        #expect(MusicDragAndDrop.scrollSpeed(pointerY: 1100, height: 1000) == 1800)
        #expect(MusicDragAndDrop.step(speed: 1000, elapsed: 5) == 100)
        #expect(MusicDragAndDrop.insertionIndex(overRow: 4, pointerY: 5, rowHeight: 40) == 4)
        #expect(MusicDragAndDrop.insertionIndex(overRow: 4, pointerY: 30, rowHeight: 40) == 5)
        #expect(!MusicDragAndDrop.canReorder(filtered: true, sortedAwayFromDefault: false, descending: false, selecting: false, saving: false, morePagesToLoad: false, targetBeyondLoaded: false))
        #expect(MusicDragAndDrop.shortcutDrop(existing: ["a"], newID: "a") == .duplicate)
        #expect(MusicDragAndDrop.shortcutDrop(existing: Array(repeating: "x", count: 12), newID: "n") == .addEvicting(oldestIndex: 0))
    }

    @Test func everyHapticIsShorterThanSixtyFiveMilliseconds() {
        for h in MusicHaptic.allCases { #expect(h.totalMs < 65, "\(h)") }
    }
}
