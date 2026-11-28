import Testing
import Foundation
@testable import REDDY

@Suite("Film, person and album pages: shared rules") struct PageRewriteTests {
    // MARK: language policy (no language is named in code)

    @Test func theLanguageListsComeFromThePersonAndTheFilmNotFromAList() {
        for code in MusicLanguage.pickable.map(\.rawValue) {
            let media = MusicLanguagePolicy.tmdbMedia(original: code, preferred: ["en-US"])
            #expect(media.split(separator: ",").contains(Substring(code)) || code.count != 2, "the film's own language is asked for: \(code)")
            #expect(media.hasPrefix("null"), "textless pictures first")
        }
        #expect(MusicLanguagePolicy.codes(preferred: ["te-IN", "en-US", "te-IN"]) == ["te", "en"], "each once, in the person's order")
        #expect(MusicLanguagePolicy.tmdbText(preferred: ["ta-IN"]) == "ta-IN")
        #expect(MusicLanguagePolicy.wikidataLabels(preferred: ["hi-IN"]) == "hi,en")
        #expect(MusicLanguagePolicy.wikidataLabels(preferred: ["en-GB"]) == "en")
    }

    // MARK: a better picture replaces a worse one, never the other way

    @Test func aBetterSourceReplacesAWorseOneAndNeverTheReverse() {
        let provider = "https://c.saavncdn.com/123/cover-150x150.jpg"
        let tmdb = "https://image.tmdb.org/t/p/w500/abc.jpg"
        #expect(MusicImageRank.better(stored: provider, new: tmdb, kind: .film) == tmdb)
        #expect(MusicImageRank.better(stored: tmdb, new: provider, kind: .film) == tmdb)
        #expect(MusicImageRank.better(stored: tmdb, new: "https://image.tmdb.org/t/p/w500/other.jpg", kind: .film) == tmdb, "an equal source keeps the stored one")
        #expect(MusicImageRank.better(stored: nil, new: provider, kind: .film) == provider)
        #expect(MusicImageRank.better(stored: provider, new: nil, kind: .film) == provider)
        let caa = "https://coverartarchive.org/release/x/front-500"
        #expect(MusicImageRank.better(stored: provider, new: caa, kind: .album) == caa)
    }

    // MARK: titles

    @Test func theApostropheSlipIsRepairedAndNothingElseIsTouched() {
        #expect(MusicTitleCase.repair("He'S Back") == "He's Back")
        #expect(MusicTitleCase.repair("Don’T Stop") == "Don’t Stop")
        #expect(MusicTitleCase.repair("I'M Here") == "I'm Here")
        #expect(MusicTitleCase.repair("DON'T STOP") == "DON'T STOP", "an all-capitals title stays as written")
        #expect(MusicTitleCase.repair("O'Brien") == "O'Brien", "a name with a capital after the apostrophe keeps it when more letters follow")
        #expect(MusicTitleCase.repair("తెలుగు పాట") == "తెలుగు పాట")
    }

    @Test func aFormatSuffixIsDroppedOnlyWhenTheLabelSaysIt() {
        #expect(MusicTitleCase.recordTitle("Song - EP", subkind: MusicAlbumSubkind.ep.rawValue) == "Song")
        #expect(MusicTitleCase.recordTitle("Song - EP", subkind: MusicAlbumSubkind.soundtrack.rawValue) == "Song - EP")
        #expect(MusicTitleCase.recordTitle("Song - Single", subkind: MusicAlbumSubkind.single.rawValue) == "Song")
    }

    // MARK: the eyebrow says what the record is and how it came out

    @Test func aFilmRecordThatIsAnEPReadsSoundtrackThenEP() {
        let film = MusicSoundtrackFilm(id: MusicEntityID(kind: .film, token: String(repeating: "a", count: MusicEntityID.tokenLength)), title: "F", year: 2020)
        var h = MusicSoundtrackHeaderFacts(title: "T", subkind: MusicAlbumSubkind.ep.rawValue, film: film)
        #expect(h.kindLabel == "Soundtrack · EP")
        h.film = nil
        #expect(h.kindLabel == "EP")
    }

    // MARK: one person, one chip

    @Test func oneComposerFiledThreeWaysIsOneChipButTwoPeopleBornInDifferentYearsAreTwo() {
        func credit(_ t: String, _ name: String, _ detail: String?) -> MusicSoundtrackCredit {
            MusicSoundtrackCredit(person: MusicSoundtrackPerson(id: MusicEntityID(kind: .person, token: String(repeating: t, count: MusicEntityID.tokenLength)), name: name, detail: detail), role: .composer)
        }
        let one = MusicSoundtrackNameGuard.listableByName([credit("A", "A. R. Rahman", nil), credit("B", "A. R. Rahman", "composer / singer"), credit("C", "A R Rahman", "Tamil composer")])
        #expect(one.count == 1)
        let two = MusicSoundtrackNameGuard.listableByName([credit("D", "John Williams", "b. 1932"), credit("E", "John Williams", "b. 1951")])
        #expect(two.count == 2)
    }

    // MARK: the sizes a page asks for

    @Test func pagePicturesAskForTheirOwnSizeNotTheCardSize() {
        let hero = "https://image.tmdb.org/t/p/w500/x.jpg"
        #expect(MusicArtworkURLSizing.rewrite(hero, to: MusicArtworkSlot.filmHero.pixels()) == "https://image.tmdb.org/t/p/w1280/x.jpg")
        #expect(MusicArtworkURLSizing.rewrite(hero, to: MusicArtworkSlot.viewer.pixels()) == "https://image.tmdb.org/t/p/w1280/x.jpg")
        #expect(MusicArtworkSlot.poster.pixels() >= 500 && MusicArtworkSlot.profile.pixels() >= 500)
    }

    // MARK: the poster a film was released with

    @Test func theFilmsOwnLanguagePosterWinsThenThePersonsLanguagesThenTextless() throws {
        let json = #"{"posters":[{"file_path":"/en.jpg","iso_639_1":"en","vote_average":9},{"file_path":"/xx.jpg","iso_639_1":"xx","vote_average":3},{"file_path":"/xx2.jpg","iso_639_1":"xx","vote_average":7},{"file_path":"/none.jpg","iso_639_1":null,"vote_average":8}]}"#
        let data = Data(json.utf8)
        #expect(TMDBGraphSource.bestPoster(from: data, original: "xx", preferred: ["en"]) == "/xx2.jpg", "own language first, the better-voted one of it")
        #expect(TMDBGraphSource.bestPoster(from: data, original: nil, preferred: ["en"]) == "/en.jpg")
        #expect(TMDBGraphSource.bestPoster(from: data, original: "zz", preferred: ["yy"]) == "/none.jpg", "no wanted language: the textless poster")
        #expect(TMDBGraphSource.bestPoster(from: Data("{}".utf8), original: "xx") == nil)
    }

    // MARK: shows are credits, episodes are not films

    @Test func aPersonsShowsAreOneEntryEachAndWalkOnsAreLeftOut() {
        let json = #"{"cast":[{"media_type":"tv","id":1,"name":"Show","original_name":"Show","first_air_date":"2015-03-01","character":"Lead","popularity":5,"poster_path":"/s.jpg","original_language":"xx"},{"media_type":"tv","id":1,"name":"Show","first_air_date":"2015-03-01","character":"Lead"},{"media_type":"tv","id":2,"name":"Talk","first_air_date":"2016-01-01","character":"Self"},{"media_type":"movie","id":3,"title":"Film","release_date":"2014-01-01","character":"X"}]}"#
        let shows = TMDBGraphSource.tvCredits(from: Data(json.utf8), thisYear: 2026)
        #expect(shows.map(\.tmdbID) == [1], "once, as itself, not the talk show, not a film")
        #expect(shows.first?.posterPath == "/s.jpg" && shows.first?.language == "xx")
    }

    // MARK: names in the reader's script

    @Test func aNameIsDrawnInTheScriptOfALanguageThePersonReadsWhenTheGraphHoldsIt() {
        let native = "रहमान"
        let hindi = MusicLanguage.pickable.first { $0.script == MusicLanguageDetector.language(of: native) }
        guard let hindi else { return }
        #expect(MusicNativeNames.displayName("Rahman", aliases: [native], entityLanguage: nil, preferred: [hindi]) == native)
        #expect(MusicNativeNames.displayName("Rahman", aliases: [native], entityLanguage: nil, preferred: []) == "Rahman", "no language known: as stored")
        #expect(MusicNativeNames.displayName("Rahman", aliases: ["Rehman"], entityLanguage: nil, preferred: [hindi]) == "Rahman", "no native alias: as stored")
    }
}
