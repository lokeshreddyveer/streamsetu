import Foundation
import Testing
@testable import REDDY

@MainActor private final class SleepFake: MusicSleepPlayback {
    var isPlaying = true
    var isBuffering = false
    var volume: Float = 0.8
    var position: TimeInterval = 10
    var duration: TimeInterval = 200
    var currentUID: String? = "p:1"
    var paused = 0
    var armed = false
    func pause() { paused += 1; isPlaying = false }
    func armStopAfterCurrentSong() -> Bool { armed = true; return true }
    func disarmStopAfterCurrentSong() { armed = false }
}

@MainActor @Suite("Round 10 fixes") struct Round10FixesTests {
    private func film(_ title: String, _ year: Int?) -> MusicSoundtrackFilm {
        MusicSoundtrackFilm(id: .provisional(kind: .film, providerUID: "t:\(title)"), title: title, year: year)
    }
    private func album(_ title: String, _ year: Int?) -> MusicSoundtrackProviderAlbum {
        MusicSoundtrackProviderAlbum(id: .provisional(kind: .release, providerUID: "p:\(title)"), title: title, year: year, imageRef: nil, artistLine: "")
    }

    @Test func aSoundtrackMarkerIsAWholeWordNotTheLettersInsideAnotherWord() {
        #expect(!MusicSoundtrackMatch.accepts(film: film("Love", 2015), album: album("Lost in Love", 2016)), "\"ost\" is inside \"lost\"")
        #expect(!MusicSoundtrackMatch.accepts(film: film("Love", 2015), album: album("Most Love", 2015)))
        #expect(MusicSoundtrackMatch.accepts(film: film("Love", 2015), album: album("Love (Original Motion Picture Soundtrack)", 2015)))
        #expect(MusicSoundtrackMatch.accepts(film: film("Love", 2015), album: album("Love OST", 2015)))
    }

    @Test func aVowelSignChangesATeluguOrHindiTitleKey() {
        #expect(MusicAlbumEditionComparison.fold("కి") != MusicAlbumEditionComparison.fold("క"))
        #expect(MusicAlbumEditionComparison.fold("की") != MusicAlbumEditionComparison.fold("क"))
        #expect(MusicAlbumEditionComparison.fold("Café") == MusicAlbumEditionComparison.fold("cafe"), "Latin accents still fold")
    }

    @Test func writingIsOneRoleUnderTwoNames() {
        #expect(MusicFilmGraphReading.sameCreditRole(.writer, .screenwriter))
        #expect(MusicFilmGraphReading.sameCreditRole(.director, .director))
        #expect(!MusicFilmGraphReading.sameCreditRole(.writer, .director))
    }

    @Test func releasesAreAskedOfADifferentEightFollowsOnAnotherVisit() {
        let artists = (0..<20).map { MusicArtist(id: "a\($0)", providerID: "p", name: "A\($0)") }
        let first = MusicHomeFeedModel.releaseSeeds(artists, seed: 0)
        let other = MusicHomeFeedModel.releaseSeeds(artists, seed: 9)
        #expect(first.count == 8 && other.count == 8)
        #expect(first.map(\.id) != other.map(\.id))
        #expect(MusicHomeFeedModel.releaseSeeds(Array(artists.prefix(5)), seed: 3).count == 5, "a person with few follows is asked about all of them")
    }

    @Test func aTimerForTheEndOfASongLeavesTheSongTheListenerStartedAfterwards() {
        let p = SleepFake()
        let timer = MusicSleepTimer(player: p, autoTick: false)
        timer.start(.endOfTrack)
        p.currentUID = "p:2"          // the listener skipped to another song
        timer.tick()
        #expect(p.paused == 0, "the new song keeps playing")
        #expect(!p.armed, "the stop mark belonged to the old song and is dropped")
        #expect(timer.preset == nil)
    }

    @Test func aTimerForTheEndOfASongWaitsWhenTheLengthIsNotKnown() {
        let p = SleepFake(); p.duration = 0
        let timer = MusicSleepTimer(player: p, autoTick: false)
        timer.start(.endOfTrack)
        timer.tick()
        #expect(p.paused == 0 && timer.preset != nil, "an unknown length is not the end of the song")
    }

    @Test func aMinutesTimerSetWhilePausedIsNotCancelledBeforePlay() {
        let p = SleepFake(); p.isPlaying = false
        let timer = MusicSleepTimer(player: p, autoTick: false)
        timer.start(.minutes(15))
        timer.tick(); timer.tick(); timer.tick()
        #expect(timer.preset != nil)
        p.isPlaying = true; timer.tick()
        p.isPlaying = false; timer.tick(); timer.tick()
        #expect(timer.preset == nil, "paused again after playing: the person stopped it")
    }
}
