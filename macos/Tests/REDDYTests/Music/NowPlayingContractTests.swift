import Foundation
import Testing
@testable import REDDY

/// What a person expects of the full player screen, one suite per expectation, checked on the rules under it. Pictures, motion and the output hardware are checked by eye on a build.
private func song(_ n: Int, title: String? = nil, ms: Int64 = 200_000) -> MusicTrack {
    MusicTrack(id: "t\(n)", providerID: "p", title: title ?? "Song \(n)", durationMs: ms, artists: [MusicArtistRef(id: "a", name: "Artist")])
}

@Suite("Now Playing 1: artwork") struct NPArtworkContract {
    @Test func theArtworkFillsThePanelUpToTheLimitAndNeverOverflowsOrCollapsesOnBadInput() {
        #expect(MusicNowPlayingMetrics.artworkSize(panelWidth: 2_000) == MusicNowPlayingMetrics.artworkRange.upperBound)
        let w: CGFloat = 340
        #expect(MusicNowPlayingMetrics.artworkSize(panelWidth: w) <= w - 2 * MusicNowPlayingMetrics.sideMargin)
        #expect(MusicNowPlayingMetrics.artworkSize(panelWidth: 0) == 0 && MusicNowPlayingMetrics.artworkSize(panelWidth: .nan) == 0)
    }
    @Test func aMissingPictureStillHasInitialsInAnyScript() {
        #expect(MusicPersonText.initials("Mohit Chauhan") == "MC" && MusicPersonText.initials("పవన్ కళ్యాణ్").count == 2 && MusicPersonText.initials("   ").isEmpty)
    }
}

@Suite("Now Playing 2: dynamic background") struct NPBackgroundContract {
    @Test func aColourlessCoverGivesNoColourAndASaturatedOneDoes() {
        let grey = [UInt8](repeating: 128, count: 4 * 64)
        #expect(MusicAdaptiveColor.dominant(rgba: grey) == nil)
        var red: [UInt8] = []; for _ in 0..<64 { red += [200, 30, 40, 255] }
        let c = MusicAdaptiveColor.dominant(rgba: red)
        #expect(c != nil && c!.r > c!.g && c!.r > c!.b)
    }
    @Test func theScrimKeepsWhiteTextReadableOverAnyBrightnessOfCover() {
        for lum in stride(from: 0.0, through: 1.0, by: 0.05) {
            let level = MusicContrast.scrimLevel(forBackgroundLuminance: lum)
            let ratio = MusicContrast.ratio(1, lum * (1 - level.rawValue))
            #expect(ratio >= MusicContrast.textMinimum || level == .heavy, "luminance \(lum)")
        }
        #expect(MusicContrast.scrimLevel(forBackgroundLuminance: 0.9, increased: true).rawValue >= MusicContrast.scrimLevel(forBackgroundLuminance: 0.9).rawValue)
    }
    @Test func textOnAnAccentIsDarkOnlyOnLightAccents() {
        #expect(MusicAdaptiveColor.isLight(MusicRGB(0.95, 0.95, 0.3)) && !MusicAdaptiveColor.isLight(MusicRGB(0.1, 0.1, 0.5)))
    }
}

@Suite("Now Playing 3: song information") struct NPSongInfoContract {
    @Test func aNoisyVideoTitleIsShownCleanAndACleanOrLocalTitleIsKeptExactly() {
        let noisy = song(1, title: "Chikiri Chikiri (Official Video) | Peddi | Ram Charan")
        #expect(MusicDisplayTitle.display(for: noisy)?.title != nil)
        #expect(MusicDisplayTitle.display(for: song(2, title: "Plain Title")) == nil)
        var local = noisy; local.providerID = "local"
        #expect(MusicDisplayTitle.display(for: local) == nil)
    }
}

@Suite("Now Playing 4: progress") struct NPProgressContract {
    @Test func elapsedRemainingAndFractionAreSafeForAnyPosition() {
        #expect(MusicTime.clock(75) == "1:15" && MusicTime.clock(3_725) == "1:02:05" && MusicTime.clock(.nan) == "0:00" && MusicTime.clock(-5) == "0:00")
        #expect(MusicTime.remaining(position: 50, duration: 200) == "-2:30" && MusicTime.remaining(position: 250, duration: 200) == "-0:00")
        #expect(MusicTime.fraction(position: 50, duration: 200) == 0.25 && MusicTime.fraction(position: 50, duration: 0) == 0 && MusicTime.fraction(position: 900, duration: 200) == 1)
    }
    @Test func aDragLandsInsideTheSong() {
        #expect(MusicStreamLength.seekTarget(fraction: 0.5, shown: 180) == 90 && MusicStreamLength.seekTarget(fraction: 2, shown: 180) == 180)
    }
}

@Suite("Now Playing 5: transport") struct NPTransportContract {
    @Test func everyControlHasARuleThatKeepsItInTheBarAtAnyWidth() {
        #expect(!MusicBarCollapse.priority.isEmpty && Set(MusicBarCollapse.priority) == Set(MusicBarCollapse.displayOrder))
        #expect(MusicBarCollapse.resolve(available: .nan, present: Set(MusicBarCollapse.priority)).shown.isEmpty)
    }
    @Test func nextIsOfferedExactlyWhenThereIsSomethingNext() {
        var q = MusicQueue(); q.replace(with: [song(1), song(2)], startAt: 0)
        #expect(q.hasNext)
        _ = q.advance(auto: false); #expect(!q.hasNext)
        q.repeatMode = .all; #expect(q.hasNext)
    }
}

@Suite("Now Playing 6: favourites") struct NPFavouritesContract {
    @Test func likeAndSaveAreOfferedOnOnlineSongsAndNeverOnLocalFiles() {
        var online = MusicTrackMenuContext(); online.canToggleLibrary = true; online.canRate = true
        let items = MusicMenuLogic.trackItems(online)
        #expect(items.contains(.like) && items.contains(.saveToLibrary) && items.contains(.dislike))
        var local = online; local.isLocal = true
        let l = MusicMenuLogic.trackItems(local)
        #expect(!l.contains(.like) && !l.contains(.saveToLibrary) && !l.contains(.download) && !l.contains(.share) && l.contains(.saveToPlaylist))
    }
}

@Suite("Now Playing 7: queue") struct NPQueueContract {
    @Test func playNextGoesRightAfterTheCurrentSongAddToQueueGoesLastAndRowsMoveAndGo() {
        var q = MusicQueue(); q.replace(with: (0..<5).map { song($0) }, startAt: 1)
        q.playNext([song(90)]); q.addToQueue([song(91)])
        #expect(q.entries[2].track.id == "t90" && q.entries.last?.track.id == "t91")
        let before = q.count
        let movedUp = q.moveUpcoming(from: q.count - 1, to: 2)
        #expect(movedUp)
        #expect(q.entries[2].track.id == "t91" && q.count == before)
        _ = q.remove(at: 2)
        #expect(q.count == before - 1 && !q.tracks.contains { $0.id == "t91" })
        #expect(q.clearManual() >= 1 && !q.hasManualUpcoming)
    }
}

@Suite("Now Playing 8: lyrics") struct NPLyricsContract {
    @Test func theLineThatIsSungFollowsTheClockAndNothingIsHighlightedBeforeTheFirstLine() {
        let lines = [0, 4_000, 9_000, 15_000].map { MusicLyricLine(timeMs: Int64($0), text: "line \($0)") }
        #expect(MusicLyricsLookup.lineIndex(in: lines, at: -1) == nil)
        #expect(MusicLyricsLookup.lineIndex(in: lines, at: 0) == 0 && MusicLyricsLookup.lineIndex(in: lines, at: 8_999) == 1 && MusicLyricsLookup.lineIndex(in: lines, at: 15_000) == 3 && MusicLyricsLookup.lineIndex(in: lines, at: 999_999) == 3)
        #expect(MusicLyricsLookup.lineIndex(in: [], at: 5) == nil)
    }
}

@Suite("Now Playing 9: audio information") struct NPAudioInfoContract {
    @Test func codecBitrateAndSampleRateAreShownWhenKnownAndLosslessOnlyWhenVerified() {
        let flac = MusicQualityFacts.make(stream: MusicStream(url: "u", codec: "flac", container: "flac", bitrate: nil, sampleRate: 44_100))
        let labels = Set(flac.rows.map(\.label))
        #expect(labels.contains("Codec") && flac.rows.contains { $0.value.contains("44.1") } && flac.isVerifiedLossless && flac.chip != nil)
        let aac = MusicQualityFacts.make(stream: MusicStream(url: "u", codec: "aac", container: "m4a", bitrate: 128))
        #expect(!aac.isVerifiedLossless && aac.rows.contains { $0.value.contains("128") })
        let none = MusicQualityFacts.make(stream: nil)
        #expect(none.rows.isEmpty && !none.isVerifiedLossless)
    }
}

@Suite("Now Playing 10: output devices") struct NPOutputContract {
    @Test func theRouteIsNamedAndAMissingDeviceFallsBackToTheSystemOutput() {
        #expect(MusicOutputRoute.label(resolution: .systemDefault, chosenName: nil) == Localized.string("System output"))
        #expect(MusicOutputRoute.label(resolution: .yieldedMissing("AirPods"), chosenName: "AirPods") == Localized.string("System output"))
    }
}

@Suite("Now Playing 11: context menu") struct NPMenuContract {
    @Test func theSongMenuHasEveryTrackActionInAStableOrderAndEachGoToOnlyWithSomewhereToGo() {
        var c = MusicTrackMenuContext(); c.canRadio = true; c.hasArtistID = true; c.hasAlbumID = true; c.hasSongPage = true; c.canToggleLibrary = true
        let items = MusicMenuLogic.trackItems(c)
        let wanted: [MusicTrackMenuItem] = [.playNext, .addToQueue, .startRadio, .like, .saveToLibrary, .goToArtist, .goToAlbum, .goToSong, .share, .saveToPlaylist, .download, .chooseSource, .neverPlay]
        let order = items.filter(wanted.contains)
        #expect(order == wanted)
        c.hasArtistID = false; c.hasAlbumID = false; c.hasSongPage = false
        let bare = MusicMenuLogic.trackItems(c)
        #expect(!bare.contains(.goToArtist) && !bare.contains(.goToAlbum) && !bare.contains(.goToSong))
    }
}

@Suite("Now Playing 13: compact mode") struct NPCompactContract {
    @Test func theCompactBarIsShorterKeepsPlayAlwaysAndShowsNextOnlyWhenThereIsRoom() {
        #expect(MusicBarMetrics.height(for: .compact) < MusicBarMetrics.height(for: .wide))
        #expect(MusicBarCollapse.compactShowsNext(width: 400) && !MusicBarCollapse.compactShowsNext(width: 280))
    }
    @Test func thePillShrinksWithTheWindow() {
        #expect(MusicPlayerBar.pillWidth(for: .wide) > MusicPlayerBar.pillWidth(for: .expanded) && MusicPlayerBar.pillWidth(for: .expanded) > MusicPlayerBar.pillWidth(for: .medium))
        #expect(MusicPlayerBar.pillBudget(for: .wide) >= MusicPlayerBar.pillBudget(for: .medium))
    }
}
