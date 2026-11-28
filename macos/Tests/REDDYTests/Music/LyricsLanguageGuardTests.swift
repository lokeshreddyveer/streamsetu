import Foundation
import Testing
@testable import REDDY

@Suite("Lyrics: wrong language")
struct LyricsLanguageGuardTests {
    private func lyrics(_ lines: [String]) -> MusicLyrics {
        MusicLyrics(synced: lines.enumerated().map { MusicLyricLine(timeMs: Int64($0.offset) * 4000, text: $0.element) })
    }
    private let hindi = ["चंदा ई देखा अँखा बाजू मा हमरे रखा", "ई देख करे मनवा तैया धक्का", "अंगियन सोभे नौ लखा दर्पन से नैन मटक्का"]
    private let telugu = ["చందమామ చూడు నా పక్కన", "ఈ చూడు చేస్తావా నన్ను", "అందాల సొగసు కన్నుల్లో మెరిసే"]

    @Test func aTeluguSongRejectsHindiWordsAndKeepsTelugu() {
        #expect(!MusicLyricsLanguageGuard.accepts(lyrics(hindi), expected: .telugu))
        #expect(MusicLyricsLanguageGuard.accepts(lyrics(telugu), expected: .telugu))
    }
    @Test func anyLanguagePairBehavesTheSame() {
        #expect(!MusicLyricsLanguageGuard.accepts(lyrics(telugu), expected: .hindi))
        #expect(MusicLyricsLanguageGuard.accepts(lyrics(hindi), expected: .hindi))
    }
    @Test func romanisedLyricsAndUnknownLanguagesPass() {
        #expect(MusicLyricsLanguageGuard.accepts(lyrics(["chandamama choodu naa pakkana", "ee choodu chestava nannu"]), expected: .telugu))
        #expect(MusicLyricsLanguageGuard.accepts(lyrics(hindi), expected: nil))
    }
    @Test func aMixedSongPasses() {
        #expect(MusicLyricsLanguageGuard.accepts(lyrics(telugu + ["चंदा ई देखा"]), expected: .telugu))
    }
}

@Suite("Lyrics: expected language")
struct LyricsExpectedLanguageTests {
    private func track(_ title: String, album: String?, lang: String? = nil) -> MusicTrack {
        var t = MusicTrack(id: "x", providerID: "ytmusic", title: title, durationMs: 200_000, artists: [MusicArtistRef(id: "", name: "Mohit Chauhan")])
        t.album = album.map { MusicAlbumRef(id: "a", title: $0) }
        if let lang { t.hints = MusicProviderHints(language: lang) }
        return t
    }
    private let none = MusicLyricsLocale(language: nil, indian: false)

    @Test func theAlbumTagSetsTheLanguage() {
        #expect(MusicLyricsLanguageGuard.expected(track: track("Chikiri Chikiri", album: "Peddi (Telugu)"), locale: none) == .telugu)
    }
    @Test func conflictingSignalsEnforceNothing() {
        #expect(MusicLyricsLanguageGuard.expected(track: track("Chikiri", album: "Peddi (Telugu)", lang: "hi"), locale: none) == nil)
    }
    @Test func nothingSaidMeansNothingEnforced() {
        #expect(MusicLyricsLanguageGuard.expected(track: track("Some Song", album: "Some Album"), locale: none) == nil)
    }
    @Test func hindiSongsMayBePrintedInUrduScript() {
        let urdu = MusicLyrics(synced: ["میں تیرا ہیرو ہوں آج رات", "تو میری جان ہے ہمیشہ کے لیے"].enumerated().map { MusicLyricLine(timeMs: Int64($0.offset) * 4000, text: $0.element) })
        #expect(MusicLyricsLanguageGuard.accepts(urdu, expected: .hindi))
    }
}

/// The same rule over every language, many titles and many artists: the check must never depend on one song or one name.
@Suite("Lyrics: language matrix")
struct LyricsLanguageMatrixTests {
    /// Two sung lines per script (Unicode block of each language), long enough to be judged.
    private static let sung: [MusicLanguage: [String]] = [
        .telugu: ["చందమామ చూడు నా పక్కన నిలిచే", "అందాల సొగసు కన్నుల్లో మెరిసే వేళ"],
        .hindi: ["चंदा ई देखा अँखा बाजू मा हमरे रखा", "अंगियन सोभे नौ लखा दर्पन से नैन मटक्का"],
        .tamil: ["நிலவே நீ வா என் அருகில் நில்லு", "கண்ணில் மின்னும் அழகே என் உயிரே"],
        .kannada: ["ಚಂದಿರ ನೀನು ಬಾ ನನ್ನ ಬಳಿ ನಿಲ್ಲು", "ಕಣ್ಣಲ್ಲಿ ಮಿನುಗುವ ಅಂದವೇ ನನ್ನ ಜೀವವೇ"],
        .malayalam: ["ചന്ദ്രനേ നീ വരൂ എന്റെ അരികിൽ നിൽക്കൂ", "കണ്ണിൽ മിന്നുന്ന അഴകേ എന്റെ ജീവനേ"],
        .bengali: ["চাঁদ তুমি এসো আমার পাশে দাঁড়াও", "চোখে ঝলমল করা সৌন্দর্য আমার প্রাণ"],
        .punjabi: ["ਚੰਨ ਤੂੰ ਆ ਮੇਰੇ ਕੋਲ ਖਲੋ ਜਾ", "ਅੱਖਾਂ ਵਿੱਚ ਚਮਕਦੀ ਸੋਹਣੀ ਮੇਰੀ ਜਾਨ"],
        .gujarati: ["ચાંદ તું આવ મારી પાસે ઊભો રહે", "આંખોમાં ચમકતી સુંદરતા મારી જાન"],
        .korean: ["달빛 아래서 너를 기다려 나의 사랑아", "눈부신 그 미소가 내 마음을 흔들어"],
        .japanese: ["ひかりのなかできみをまっている", "ゆめのつづきをいっしょにあるこう"],
        .arabic: ["يا قمر تعال إلى جانبي وقف هنا", "في عينيك جمال يلمع يا حبيبي"]
    ]
    private static let langs = Array(sung.keys).sorted { $0.rawValue < $1.rawValue }

    private func lyrics(_ l: MusicLanguage) -> MusicLyrics {
        MusicLyrics(synced: (Self.sung[l] ?? []).enumerated().map { MusicLyricLine(timeMs: Int64($0.offset) * 4000, text: $0.element) })
    }
    private func track(_ title: String, album: String? = nil, artist: String = "Some Artist", stated: String? = nil) -> MusicTrack {
        var t = MusicTrack(id: "x", providerID: "ytmusic", title: title, durationMs: 200_000, artists: [MusicArtistRef(id: "", name: artist)])
        t.album = album.map { MusicAlbumRef(id: "a", title: $0) }
        if let stated { t.hints = MusicProviderHints(language: stated) }
        return t
    }

    @Test func everyLanguageKeepsItsOwnWordsAndRefusesEveryOtherScript() {
        for want in Self.langs {
            for got in Self.langs {
                let ok = MusicLyricsLanguageGuard.accepts(lyrics(got), expected: want)
                // Hindi and Arabic script lyrics are interchangeable (Hindi and Urdu songs are printed in either); every other pair is strict.
                let sameFamily = got == want || (Set([got, want]) == [.hindi, .arabic])
                #expect(ok == sameFamily, "expected \(want) got \(got)")
            }
        }
    }

    @Test func aLanguageNamedInTheAlbumOrTitleIsEnforcedWhateverTheTitleOrArtist() {
        let tags: [(String, MusicLanguage)] = [("Telugu", .telugu), ("Hindi", .hindi), ("Tamil", .tamil), ("Kannada", .kannada), ("Malayalam", .malayalam)]
        let titles = ["Chikiri Chikiri", "Love Story", "A", "Song of the Night (From \"Film\")", "ఛిలకలూరి"]
        let artists = ["Mohit Chauhan", "A. R. Rahman", "మోహిత్ చౌహాన్", "Taylor Swift", "BTS"]
        for (word, lang) in tags {
            for title in titles where MusicLanguageDetector.language(of: title).map({ $0 == .latin }) ?? true {
                for artist in artists {
                    let t = track(title, album: "Film (\(word))", artist: artist)
                    #expect(MusicLyricsLanguageGuard.expected(track: t, locale: MusicLyricsLocale(language: nil, indian: false)) == lang, "\(title) / \(artist) / \(word)")
                }
            }
        }
    }

    @Test func aTitleInAScriptSetsTheLanguageAndTheArtistNeverDoes() {
        #expect(MusicLyricsLanguageGuard.expected(track: track("చందమామ", artist: "Taylor Swift"), locale: MusicLyricsLocale(language: nil, indian: false)) == .telugu)
        #expect(MusicLyricsLanguageGuard.expected(track: track("Moonlight", artist: "మోహిత్ చౌహాన్"), locale: MusicLyricsLocale(language: nil, indian: false)) == nil)
    }

    @Test func aSourceStatingOneLanguageAgainstATagOfAnotherEnforcesNothing() {
        let t = track("Song", album: "Film (Telugu)", stated: "hi")
        #expect(MusicLyricsLanguageGuard.expected(track: t, locale: MusicLyricsLocale(language: nil, indian: false)) == nil)
        for got in Self.langs { #expect(MusicLyricsLanguageGuard.accepts(lyrics(got), expected: nil)) }
    }

    @Test func englishAndOtherLatinSongsAreNeverRefused() {
        let english = MusicLyrics(synced: ["I was walking down the street tonight", "Under the moonlight with you"].enumerated().map { MusicLyricLine(timeMs: Int64($0.offset) * 4000, text: $0.element) })
        for want in Self.langs { #expect(MusicLyricsLanguageGuard.accepts(english, expected: want)) }     // romanised or translated text carries no script to judge
        #expect(MusicLyricsLanguageGuard.expected(track: track("Moonlight", album: "Night Songs"), locale: MusicLyricsLocale(language: nil, indian: false)) == nil)
    }

    @Test func plainTextAndInstrumentalsAndShortSnippetsFollowTheSameRules() {
        let plainHindi = MusicLyrics(plain: (Self.sung[.hindi] ?? []).joined(separator: "\n"))
        #expect(!MusicLyricsLanguageGuard.accepts(plainHindi, expected: .telugu))
        #expect(MusicLyricsLanguageGuard.accepts(plainHindi, expected: .hindi))
        #expect(MusicLyricsLanguageGuard.accepts(MusicLyrics(instrumental: true), expected: .telugu))
        #expect(MusicLyricsLanguageGuard.accepts(MusicLyrics(plain: "आह"), expected: .telugu))        // too little to judge
    }

    @Test func aMixedSongPassesWhenItsOwnScriptIsAQuarterOrMore() {
        let mixed = MusicLyrics(synced: ((Self.sung[.telugu] ?? []) + (Self.sung[.hindi] ?? []).prefix(1)).enumerated().map { MusicLyricLine(timeMs: Int64($0.offset) * 4000, text: $0.element) })
        #expect(MusicLyricsLanguageGuard.accepts(mixed, expected: .telugu))
    }
}
