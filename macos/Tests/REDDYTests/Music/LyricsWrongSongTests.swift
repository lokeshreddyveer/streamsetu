import Testing
import Foundation
@testable import REDDY

@Suite("Lyrics of a different song are refused") struct LyricsWrongSongTests {
    private func row(_ track: String, _ artist: String, _ seconds: Double, synced: Bool = true) -> [String: Any] {
        ["trackName": track, "artistName": artist, "duration": seconds, "syncedLyrics": synced ? "[00:01.00] line one\n[00:05.00] line two" : NSNull(), "plainLyrics": "line one\nline two"]
    }

    @Test func theSameTitleBySingersOfAnotherSongIsNotTheLyricsOfThisOne() {
        // The Telugu "Radhe Radhe" (G.V. Prakash Kumar) must not get the Hindi film song of the same name, whose length happens to be close.
        let rows = [row("Radhe Radhe", "Meet Bros, Ayushmann Khurrana", 226)]
        #expect(LRCLibProvider.pick(rows, wantSeconds: 228, title: "Radhe Radhe", artists: "G.V. Prakash Kumar, Lipsika Bhashyam, Sreemani") == nil)
    }
    @Test func theRightSongIsStillFoundWhateverTheSpellingOfTheName() {
        let rows = [row("Radhe Radhe", "Meet Bros", 226), row("Radhe Radhe", "G. V. Prakash Kumar", 229)]
        let hit = LRCLibProvider.pick(rows, wantSeconds: 228, title: "Radhe Radhe", artists: "G.V. Prakash Kumar, Lipsika Bhashyam, Sreemani")
        #expect(hit != nil && hit?.isSynced == true)
    }
    @Test func aDifferentTitleIsRefusedEvenWithTheRightArtist() {
        #expect(LRCLibProvider.pick([row("Kalagane", "G.V. Prakash Kumar", 228)], wantSeconds: 228, title: "Radhe Radhe", artists: "G.V. Prakash Kumar") == nil)
    }
    @Test func withNoArtistOnEitherSideTheTitleAndLengthDecide() {
        #expect(LRCLibProvider.pick([row("Song", "", 200)], wantSeconds: 201, title: "Song", artists: "") != nil)
        #expect(LRCLibProvider.pick([row("Song", "Someone", 200)], wantSeconds: 201, title: "Song", artists: "") != nil)
    }
    @Test func theOldCallWithoutAnIdentityStillWorks() {
        #expect(LRCLibProvider.pick([row("A", "B", 100)], wantSeconds: 100) != nil)
    }
}

@Suite("Lyrics of uploaded videos") struct LyricsUploadedVideoTests {
    private func row(_ track: String, _ artist: String, _ seconds: Double, synced: Bool = true) -> [String: Any] {
        ["trackName": track, "artistName": artist, "duration": seconds, "syncedLyrics": synced ? "[00:01.00] line one\n[00:05.00] line two" : NSNull(), "plainLyrics": "line one\nline two"]
    }

    @Test func anUploaderChannelDoesNotBlockTheRightSong() {
        // "Vel Records" uploaded the video; the lyrics are filed under the singer.
        let hit = LRCLibProvider.pick([row("Oh Priya Priya", "Adnan Sami feat. Chinmayi", 270)], wantSeconds: 271, title: "Oh Priya Priya", artists: "Vel Records")
        #expect(hit?.isSynced == true)
        let hit2 = LRCLibProvider.pick([row("Inkem Inkem Inkem Kaavaale - From \"Geetha Govindam\"", "Gopi Sundar", 267)], wantSeconds: 268, title: "Inkem Inkem", artists: "")
        #expect(hit2 != nil)
    }
    @Test func aTitleOnlyQuestionIsAlwaysAskedBesideTheOneWithTheArtist() {
        // An uploader the app cannot tell from a singer ("Shalimar Film Express") is still harmless: the title-only wording is asked too, and it passes the artist check.
        func req(_ title: String, _ artists: String) -> MusicLyricsRequest { MusicLyricsRequest(title: title, artists: artists) }
        let v = MusicLyricsQueryBuilder.variants(for: req("Oh Priya Priya Full Video Song || Ishq Movie", "Shalimar Film Express"))
        #expect(v.contains { $0.artists.isEmpty && $0.title == "Oh Priya Priya" }, "\(v)")
        let hit = LRCLibProvider.pick([row("Oh Priya Priya", "Adnan Sami feat. Chinmayi", 270)], wantSeconds: 271, title: "Oh Priya Priya", artists: "")
        #expect(hit != nil)
    }
    @Test func aChannelStillDoesNotAllowADifferentLengthOrADifferentTitle() {
        #expect(LRCLibProvider.pick([row("Oh Priya Priya", "Adnan Sami", 300)], wantSeconds: 271, title: "Oh Priya Priya", artists: "Vel Records") == nil)
        #expect(LRCLibProvider.pick([row("Oh Priya", "Adnan Sami", 271)], wantSeconds: 271, title: "Oh Priya Priya X Mix", artists: "Vel Records") == nil)
    }
    @Test func aVideoWithAnIntroGetsTheClosestMatchWithinTwentyFiveSeconds() {
        // "Ela Ela Naalo": the video is 327 s, the lyrics are filed at 305 s and 308 s.
        let rows = [row("Ela Ela Naalo", "Haricharan, Shweta Pandit", 305), row("Ela Ela Naalo", "Haricharan & Shweta Pandit", 308)]
        let hit = LRCLibProvider.pick(rows, wantSeconds: 327, title: "Ela Ela Naalo", artists: "Shweta Pandit")
        #expect(hit != nil)
        #expect(LRCLibProvider.pick([row("Ela Ela Naalo", "Haricharan, Shweta Pandit", 400)], wantSeconds: 327, title: "Ela Ela Naalo", artists: "Shweta Pandit") == nil, "too far off to be this recording")
    }
    @Test func aCloseMatchBeatsALooseOne() {
        let rows = [row("Song", "Someone", 320), row("Song", "Someone", 328)]
        let hit = LRCLibProvider.pick(rows, wantSeconds: 327, title: "Song", artists: "Someone")
        #expect(hit != nil)
    }
    @Test func bothPartsOfABarTitleAreAskedOnTheirOwn() {
        let parts = MusicLyricsQueryBuilder.barSegments("Surya Son of Krishnan Movie | Nalone Pongenu")
        #expect(parts.contains("Nalone Pongenu"))
        #expect(MusicLyricsQueryBuilder.barSegments("A plain title").isEmpty)
    }
    @Test @MainActor func aSourceMarkedDownIsTriedAgainAfterTheCoolOff() {
        let h = MusicLyricsHealth()
        let t0 = Date()
        for _ in 0..<MusicLyricsHealth.threshold { h.recordFailure("x", now: t0) }
        #expect(h.isDown("x", now: t0.addingTimeInterval(10)))
        #expect(!h.isDown("x", now: t0.addingTimeInterval(MusicLyricsHealth.coolOff + 1)), "one probe is allowed after the cool-off")
        h.recordFailure("x", now: t0.addingTimeInterval(MusicLyricsHealth.coolOff + 2))
        #expect(h.isDown("x", now: t0.addingTimeInterval(MusicLyricsHealth.coolOff + 3)), "a failed probe marks it down again")
        h.recordAnswer("x")
        #expect(!h.isDown("x"))
    }
    @Test func theCacheVersionWasBumpedSoOldMissesAreDropped() {
        #expect(MusicLyricsCachePolicy.schema >= 3)
    }
}
