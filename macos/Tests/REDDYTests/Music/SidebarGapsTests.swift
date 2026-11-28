import Foundation
import Testing
@testable import REDDY

/// The right-hand panel's gaps: the queue's parts, search and selection, the stop-after row id, the panel width and cover sizes, the lyrics alignment, the credits kept apart
/// from the film's, the recording facts and the sleep timer that leaves the person's volume alone. Pure rules only; no window and no audio.
private func track(_ n: Int, ms: Int64 = 180_000, title: String? = nil, artist: String? = nil) -> MusicTrack {
    MusicTrack(id: "s\(n)", providerID: "p", title: title ?? "Song \(n)", durationMs: ms, artists: [MusicArtistRef(id: "a\(n % 3)", name: artist ?? "Artist \(n % 3)")])
}
private func tracks(_ n: Int) -> [MusicTrack] { (0..<n).map { track($0) } }
private func queue(_ n: Int, start: Int = 0) -> MusicQueue { var q = MusicQueue(); q.replace(with: tracks(n), startAt: start); return q }

@MainActor private final class SleepPlayer: MusicSleepPlayback {
    var isPlaying = true, isBuffering = false
    var volume: Float = 0.8
    var position: TimeInterval = 0, duration: TimeInterval = 200
    var currentUID: String? = "p:s0"
    var paused = 0
    func pause() { paused += 1; isPlaying = false }
}
@MainActor private final class SleepClock { var t = Date(timeIntervalSince1970: 3_000_000); func advance(_ s: TimeInterval) { t = t.addingTimeInterval(s) } }

@Suite("Queue parts, search and selection") struct QueueSectionTests {
    @Test func rowsFallIntoPlayedNowPlayNextUpNextAndAutoplay() {
        var q = queue(6, start: 2)
        q.playNext([track(90)])
        q.append([track(91)], auto: true)
        let rows = q.entries
        let cur = q.index
        let kinds = rows.enumerated().map { MusicQueueSections.section(of: $0.element, at: $0.offset, current: cur) }
        #expect(kinds.first == .played)
        #expect(kinds[2] == .nowPlaying)
        #expect(kinds[3] == .playNext)                 // the song put next by hand
        #expect(kinds.last == .autoplay)
        #expect(kinds.contains(.upNext))
    }

    @Test func aHeaderStartsEachPartOnceAndPartsWithNoRowsHaveNone() {
        var q = queue(5, start: 1)
        q.playNext([track(90)])
        let heads = MusicQueueSections.headers(rows: q.entries, current: q.index)
        #expect(heads[0] == .played && heads[1] == .nowPlaying && heads[2] == .playNext && heads[3] == .upNext)
        #expect(heads.count == 4)                       // no Autoplay part: nothing was added by autoplay
        let atStart = MusicQueueSections.headers(rows: queue(3).entries, current: 0)
        #expect(atStart[0] == .nowPlaying && atStart[1] == .upNext && atStart.count == 2)   // nothing played yet: no Previously played
        #expect(MusicQueueSections.headers(rows: [], current: nil).isEmpty)
    }

    @Test func withNothingPlayingEveryRowIsUpNext() {
        let rows = queue(3).entries
        #expect(rows.indices.allSatisfy { MusicQueueSections.section(of: rows[$0], at: $0, current: nil) == .upNext })
    }

    @Test func searchMatchesEveryWordInTitleArtistOrAlbumIgnoringCaseAndAccents() {
        let rows = [track(1, title: "Café del Mar", artist: "José"), track(2, title: "Awaara Hoon", artist: "Mukesh"), track(3, title: "Other", artist: "Mukesh")].map { MusicQueue.Entry(track: $0) }
        #expect(MusicQueueSections.matchingIndices(rows: rows, query: "cafe") == [0])
        #expect(MusicQueueSections.matchingIndices(rows: rows, query: "MUKESH") == [1, 2])
        #expect(MusicQueueSections.matchingIndices(rows: rows, query: "mukesh hoon") == [1])
        #expect(MusicQueueSections.matchingIndices(rows: rows, query: "   ") == [0, 1, 2])
        #expect(MusicQueueSections.matchingIndices(rows: rows, query: "zzz").isEmpty)
    }

    @Test func aBulkRemoveNeverTouchesThePlayingRowPlayedRowsOrRowsThatLeft() {
        let q = queue(5, start: 1)
        var picked = Set(q.entries.map(\.id))
        picked.insert(UUID())
        let removable = MusicQueueSections.removableIDs(selected: picked, rows: q.entries, current: q.index)
        #expect(removable == Set(q.entries[2...].map(\.id)))        // only the three rows after the playing one
        #expect(MusicQueueSections.removableIDs(selected: [], rows: q.entries, current: 1).isEmpty)
        #expect(MusicQueueSections.removableIDs(selected: picked, rows: q.entries, current: nil).count == 5)
    }

    @Test func theJumpButtonShowsOnlyWhenThePlayingRowIsOutOfSight() {
        #expect(!MusicQueueSections.currentIsOffscreen(current: 12, firstVisible: 10, visibleCount: 6))
        #expect(MusicQueueSections.currentIsOffscreen(current: 3, firstVisible: 10, visibleCount: 6))
        #expect(MusicQueueSections.currentIsOffscreen(current: 30, firstVisible: 10, visibleCount: 6))
        #expect(!MusicQueueSections.currentIsOffscreen(current: nil, firstVisible: 0, visibleCount: 6))
    }

    @Test func theSummaryWordsComeFromTheTablesAndKeepTheirEnglishShape() {
        let rows = queue(4).entries
        #expect(MusicQueueLogic.remainingSummary(rows: rows, current: 0) == "3 songs left - 9 min")
        #expect(MusicQueueLogic.remainingSummary(rows: rows, current: 2) == "1 song left - 3 min")
        #expect(MusicQueueLogic.durationWords(minutes: 83) == "1 hr 23 min" && MusicQueueLogic.durationWords(minutes: 120) == "2 hr" && MusicQueueLogic.durationWords(minutes: 45) == "45 min")
    }
}

@Suite("Queue edits for the panel") struct QueueEditsForPanelTests {
    @Test func clearingTheUpcomingRowsKeepsThePlayedOnesAndThePlayingOne() {
        var q = queue(6, start: 2)
        q.playNext([track(90)])
        let before = Array(q.entries.prefix(3)).map(\.id)
        #expect(q.removeUpcoming() == 4)                // the song put next and the three after it
        #expect(q.entries.map(\.id) == before && q.index == 2)
        #expect(q.removeUpcoming() == 0)                // nothing left to clear
    }

    @Test func clearingTheUpcomingRowsAlsoLeavesTheShuffleSnapshotConsistent() {
        var q = queue(8, start: 0)
        q.setShuffle(true)
        _ = q.removeUpcoming()
        q.setShuffle(false)                             // going back to the original order must not bring the cleared rows back
        #expect(q.count == 1)
    }

    @Test func movingToPlayNextPutsTheRowRightAfterThePlayingOneAndMarksItAsPutNextByHand() {
        var q = queue(6, start: 1)
        let id = q.entries[5].id
        let r1 = q.moveToPlayNext(from: 5)
        #expect(r1)
        #expect(q.entries[2].id == id && q.entries[2].queued && !q.entries[2].auto)
        #expect(q.index == 1)
        let r2 = q.moveToPlayNext(from: 0)
        #expect(!r2)             // a played row cannot be moved
        let r3 = q.moveToPlayNext(from: 1)
        #expect(!r3)             // nor the playing one
    }

    @Test func theSameRecordingTwiceInTheQueueHasTwoDifferentRowIds() {
        var q = MusicQueue()
        let t = track(1)
        q.replace(with: [t, track(2), t], startAt: 0)
        #expect(q.entries[0].id != q.entries[2].id && q.entries[0].track.uid == q.entries[2].track.uid)
    }
}

@Suite("Panel width, cover size and tab keys") struct PanelGeometryTests {
    @Test func aSavedWidthInsideTheRangeIsKeptAndAnythingElseIsIgnored() {
        #expect(MusicPanelWidth.decode(360) == 360 && MusicPanelWidth.decode(280) == 280 && MusicPanelWidth.decode(500) == 500)
        #expect(MusicPanelWidth.decode(120) == nil && MusicPanelWidth.decode(900) == nil && MusicPanelWidth.decode(.nan) == nil && MusicPanelWidth.decode(nil) == nil)
    }

    @Test func theWidthStaysBetween280And500AndLeavesThePageItsRoom() {
        #expect(MusicPanelWidth.clamped(100, total: 1600) == 280)
        #expect(MusicPanelWidth.clamped(900, total: 1600) == 500)
        // A 900 pt window: the rail and 420 pt for the page leave 412 for the panel.
        #expect(MusicPanelWidth.clamped(500, total: 900) == 900 - MusicLayoutGrid.navCompactWidth - MusicPanelWidth.pageMinimum)
        #expect(MusicPanelWidth.clamped(400, total: 600) == 280)    // never under the minimum, even when the window is tiny
    }

    @Test func draggingTheLeftEdgeLeftMakesThePanelWiderAndRightNarrower() {
        #expect(MusicPanelWidth.afterDrag(start: 360, translation: -60, total: 1600) == 420)
        #expect(MusicPanelWidth.afterDrag(start: 360, translation: 60, total: 1600) == 300)
        #expect(MusicPanelWidth.afterDrag(start: 360, translation: 500, total: 1600) == 280)
        #expect(MusicPanelWidth.afterDrag(start: 360, translation: -500, total: 1600) == 500)
    }

    @Test func theShellUsesTheChosenWidthAndTheAutomaticOneOtherwise() {
        let auto = MusicShellGeometry.resolve(totalWidth: 1500, sidebarExpanded: false, panelOpen: true)
        let chosen = MusicShellGeometry.resolve(totalWidth: 1500, sidebarExpanded: false, panelOpen: true, userPanelWidth: 450)
        #expect(chosen.panelWidth == 450 && auto.panelWidth != 450)
        #expect(chosen.contentWidth == 1500 - chosen.navWidth - 450)
        #expect(MusicShellGeometry.resolve(totalWidth: 1500, sidebarExpanded: false, panelOpen: true, userPanelWidth: nil) == auto)
    }

    @Test func theCoverFollowsTheLayoutMode() {
        let wide: CGFloat = 340
        let tall = MusicNowPlayingSizing.coverSize(widthSize: wide, panelHeight: 900, mode: .balanced)
        let short = MusicNowPlayingSizing.coverSize(widthSize: wide, panelHeight: 520, mode: .balanced)
        #expect(tall == wide)                                       // plenty of height: the width decides
        #expect(short < tall && short >= MusicNowPlayingSizing.smallestCover)
        #expect(MusicNowPlayingSizing.coverSize(widthSize: wide, panelHeight: 900, mode: .compact) == 240)
        #expect(MusicNowPlayingSizing.coverSize(widthSize: wide, panelHeight: 400, mode: .immersive) == wide)
        #expect(MusicNowPlayingSizing.coverSize(widthSize: 100, panelHeight: 400, mode: .compact) == 100)   // never bigger than the panel allows
        #expect(MusicNowPlayingSizing.coverSize(widthSize: 0, panelHeight: 400, mode: .balanced) == 0)
        #expect(MusicNowPlayingMode.decode(nil) == .balanced && MusicNowPlayingMode.decode("nonsense") == .balanced && MusicNowPlayingMode.decode("compact") == .compact)
    }

    @Test func eachTabHasOneKeyAndEveryKeyOpensItsTab() {
        let tabs = MusicContextPanelTab.stripTabs
        #expect(tabs.allSatisfy { MusicPanelTabKeys.key(for: $0) != nil })
        #expect(Set(MusicPanelTabKeys.all.map(\.key)).count == tabs.count)
        for e in MusicPanelTabKeys.all { #expect(MusicPanelTabKeys.tab(forKey: e.key) == e.tab) }
        #expect(MusicPanelTabKeys.tab(forKey: "9") == nil && MusicPanelTabKeys.key(for: .info) == nil)
    }

    @Test func theNewKeysAreSavedWithTheDeviceSettings() {
        for k in [MusicShellKeys.panelWidth, MusicShellKeys.showTotalTime, MusicShellKeys.nowPlayingMode, MusicLyricsPrefs.alignmentKey] {
            #expect(MusicDefaultsKeys.deviceSettings.contains(k), "\(k)")
        }
    }
}

@Suite("Lyrics alignment and the source caption") struct LyricsAlignmentTests {
    @Test func automaticFollowsTheDuetSideAndTheOthersAreFixed() {
        #expect(MusicLyricsAlignment.automatic.isFar(duetFar: true) && !MusicLyricsAlignment.automatic.isFar(duetFar: false))
        #expect(!MusicLyricsAlignment.start.isFar(duetFar: true) && MusicLyricsAlignment.end.isFar(duetFar: false))
        #expect(!MusicLyricsAlignment.center.isFar(duetFar: true) && MusicLyricsAlignment.center.isCentered && !MusicLyricsAlignment.end.isCentered)
    }

    @Test func theChoiceCyclesThroughAllFourAndBackToAutomatic() {
        var a = MusicLyricsAlignment.automatic
        var seen: [MusicLyricsAlignment] = []
        for _ in 0..<4 { seen.append(a); a = a.next }
        #expect(Set(seen.map(\.rawValue)).count == 4 && a == .automatic)
    }

    @Test func theInactiveLinesStayReadable() {
        #expect(MusicLyricsMotion.alpha(distance: 5, wide: false) >= 0.5 && MusicLyricsMotion.alpha(distance: 4, wide: true) >= 0.55)
        #expect(MusicLyricsMotion.unsungAlpha >= 0.6)
        let steps = (0...4).map { MusicLyricsPreviewLogic.opacity(level: $0, half: 4, increaseContrast: false) }
        #expect(steps[0] == 1 && steps.dropFirst().allSatisfy { $0 >= 0.3 })
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0 >= $1 })   // still fading with distance, only gently
    }

    @Test func theVisibleLyricsCaptionNeverNamesAServiceOrAnAuthor() {
        var l = MusicLyrics(plain: "words", sourceName: "LRCLIB")
        #expect(MusicLyricsAttribution.caption(l) == "Lyrics")
        l.authors = ["carla"]
        #expect(MusicLyricsAttribution.caption(l) == "Lyrics" && !MusicLyricsAttribution.caption(l).contains("carla"))
        #expect(MusicLyricsAttribution.caption(nil) == "Find lyrics")
    }
}

@Suite("Credits kept apart and the recording's facts") struct CreditsSeparationTests {
    private func credit(_ p: MusicEntityID, _ name: String, _ role: MusicRole, level: CreditLevel, inherited: Bool) -> MusicSongCreditItem {
        .credit(MusicCreditEntry(person: p, name: name, role: role, level: level, inherited: inherited, sources: [], order: 0, hint: nil))
    }

    @Test func aFilmOrAlbumCreditIsNeverShownAmongTheSongsOwn() {
        let singer = MusicEntityID.derive(kind: .person, aliasKey: "singer"), md = MusicEntityID.derive(kind: .person, aliasKey: "md"), prod = MusicEntityID.derive(kind: .person, aliasKey: "prod")
        let layout = MusicCreditsLayout.make(items: [credit(singer, "Singer", .singer, level: .song, inherited: false),
                                                     credit(md, "Director", .musicDirector, level: .album, inherited: true),
                                                     credit(prod, "Producer", .producer, level: .film, inherited: true)], phase: .loaded)
        #expect(layout.groups.map(\.group) == [.singers])
        #expect(layout.fromAlbum.map(\.group) == [.musicDirectors] && layout.fromFilm.map(\.group) == [.producers])
        #expect(layout.hasPeople && !layout.showsEmptyLine)
    }

    @Test func aSongWithOnlyFilmCreditsHasNoOwnGroupsAndNoFalseEmptyLine() {
        let p = MusicEntityID.derive(kind: .person, aliasKey: "p")
        let layout = MusicCreditsLayout.make(items: [credit(p, "Someone", .musicDirector, level: .film, inherited: true)], phase: .loaded)
        #expect(layout.groups.isEmpty && layout.fromFilm.count == 1 && !layout.showsEmptyLine)
        #expect(MusicCreditsLayout.make(items: [], phase: .loaded).showsEmptyLine)
    }

    @Test func theSongsOwnCreditWinsOverTheSamePersonFromTheFilm() {
        let p = MusicEntityID.derive(kind: .person, aliasKey: "same")
        let layout = MusicCreditsLayout.make(items: [credit(p, "Same", .composer, level: .film, inherited: true), credit(p, "Same", .composer, level: .song, inherited: false)], phase: .loaded)
        #expect(layout.groups.map(\.group) == [.composers] && layout.fromFilm.isEmpty)
    }

    @Test func theRecordingListsOnlyWhatIsKnown() {
        var t = track(1, ms: 215_000)
        #expect(MusicRecordingInfo.rows(for: t).map(\.id) == ["length"])
        #expect(MusicRecordingInfo.rows(for: t).first?.value == "3:35")
        t.isrc = "INA010000001"; t.explicit = true; t.trackNumber = 4
        t.album = MusicAlbumRef(id: "al", title: "Album", releaseDate: "1951-01-01")
        let ids = MusicRecordingInfo.rows(for: t).map(\.id)
        #expect(ids == ["length", "track", "released", "content", "isrc"])
        var none = track(2, ms: 0)
        none.isrc = "  "
        #expect(MusicRecordingInfo.rows(for: none).isEmpty)
    }

    @Test func theStreamFactsListedAreTheTechnicalOnesAndNeverTheRouteOrDelivery() {
        let facts = MusicQualityFacts.make(stream: nil, effectsActive: true, route: "Speakers")
        #expect(MusicRecordingInfo.rows(for: track(1), technical: facts.rows).allSatisfy { !$0.id.hasPrefix("tech.") })
        let tech = [MusicQualityFacts.Row(id: "codec", label: "Codec", value: "FLAC"), MusicQualityFacts.Row(id: "route", label: "Output", value: "Speakers"),
                    MusicQualityFacts.Row(id: "delivery", label: "Delivery", value: "HLS"), MusicQualityFacts.Row(id: "sampleRate", label: "Sample rate", value: "44.1 kHz")]
        let ids = MusicRecordingInfo.rows(for: track(1), technical: tech).map(\.id)
        #expect(ids == ["length", "tech.codec", "tech.sampleRate"])
    }
}

@Suite("Sleep timer and volume") @MainActor struct SleepVolumeTests {
    @Test func aVolumeChangeMadeDuringTheCountdownIsKeptWhenTheTimerEnds() {
        let clock = SleepClock(), p = SleepPlayer()
        let t = MusicSleepTimer(player: p, now: { clock.t }, autoTick: false)
        t.start(.minutes(30))
        clock.advance(600); p.volume = 0.5; t.tick()
        clock.advance(30 * 60 - 600 + 1); t.tick()
        #expect(p.paused == 1 && p.volume == 0.5 && !t.isRunning)
    }

    @Test func aVolumeChangeMadeDuringTheFadeStopsTheFadeAndIsKept() {
        let clock = SleepClock(), p = SleepPlayer()
        let t = MusicSleepTimer(player: p, now: { clock.t }, autoTick: false)
        t.start(.minutes(30))
        clock.advance(30 * 60 - 5); t.tick()
        #expect(p.volume < 0.8)                         // the fade began
        p.volume = 0.9                                  // the person turns it up
        clock.advance(1); t.tick()
        #expect(p.volume == 0.9)                        // the fade does not pull it down again
        clock.advance(10); t.tick()
        #expect(p.paused == 1 && p.volume == 0.9)
    }

    @Test func anUntouchedFadeStillGivesTheVolumeBack() {
        let clock = SleepClock(), p = SleepPlayer()
        let t = MusicSleepTimer(player: p, now: { clock.t }, autoTick: false)
        t.start(.minutes(15))
        clock.advance(15 * 60 - 4); t.tick()
        clock.advance(5); t.tick()
        #expect(p.paused == 1 && p.volume == 0.8)
    }

    @Test func thePresetTitlesAreBuiltThroughTheTables() {
        #expect(MusicSleepPreset.minutes(45).title == "45 minutes" && MusicSleepPreset.endOfTrack.title == "End of this track")
    }
}
