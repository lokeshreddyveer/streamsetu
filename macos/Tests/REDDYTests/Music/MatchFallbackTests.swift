import Testing
@testable import REDDY

@Suite("Songs the song catalogue does not hold: official videos") struct MatchFallbackTests {
    private func score(_ wanted: String, ms: Int64, _ candidate: String, channel: String, candMs: Int64?) -> Float {
        MusicTextMatch.score(trackTitle: wanted, artists: ["Some Singer"], durationMs: ms, candidateTitle: candidate, candidateArtist: channel, candidateDurationMs: candMs)
    }

    @Test func aTitleThatStartsWithTheWantedOneCountsEvenWhenTheSpacingDiffers() {
        #expect(MusicTextMatch.startsWithTitle(MusicTextMatch.coreTokens("SteppaMaar"), "Steppa Maar Lyrical Video | Double Ismart | Ram"))
        #expect(MusicTextMatch.startsWithTitle(MusicTextMatch.coreTokens("Steppa Maar"), "SteppaMaar (Telugu) Video Song"))
        #expect(!MusicTextMatch.startsWithTitle(MusicTextMatch.coreTokens("Rain"), "Rain Rain Go Away"), "short titles never qualify")
        #expect(!MusicTextMatch.startsWithTitle(MusicTextMatch.coreTokens("Kabir Singh"), "Arjun Reddy and Kabir Singh Mashup"), "only the start of a part counts")
    }

    @Test func theRightLengthPassesAndAPromoOrACoverDoesNot() {
        let full = score("SteppaMaar", ms: 232_000, "Steppa Maar Lyrical Video | Double Ismart | Ram Pothineni", channel: "Some Singer", candMs: 234_000)
        let promo = score("SteppaMaar", ms: 232_000, "Steppa Maar Lyrical Video | Double Ismart | Ram Pothineni", channel: "Some Singer", candMs: 31_000)
        let cover = score("SteppaMaar", ms: 232_000, "Steppamaar dance cover song | Double ISMART", channel: "ADC covers", candMs: 233_000)
        #expect(full >= MusicStreamResolver.minimumScore, "\(full)")
        #expect(promo < MusicStreamResolver.minimumScore, "a 31 second promo is not the song: \(promo)")
        #expect(cover < MusicStreamResolver.minimumScore, "a cover is another recording: \(cover)")
    }

    @Test func anotherSongBySameSingerOfSimilarLengthIsNotATitleMatch() {
        #expect(!MusicTextMatch.titleFits("SteppaMaar", "Dum Dumaare"))
        #expect(MusicTextMatch.titleFits("SteppaMaar", "Steppa Maar Lyrical Video | Double Ismart"))
        #expect(MusicTextMatch.titleFits("Kabir Singh (title song)", "Kabir Singh"))
    }

    @Test func aDifferentSongOfTheSameSingerStaysOut() {
        let other = score("SteppaMaar", ms: 232_000, "Dum Dumaare", channel: "Some Singer", candMs: 229_000)
        #expect(other < MusicStreamResolver.minimumScore, "\(other)")
    }
}
