import Testing
import Foundation
@testable import REDDY

@Suite("A song's language comes from its source first") struct LanguageEvidenceTests {
    private func track(_ title: String, stated: String? = nil, artist: String = "A") -> MusicTrack {
        var t = MusicTrack(id: "1", providerID: "x", title: title, durationMs: 0, artists: [MusicArtistRef(id: "", name: artist)])
        if let stated { t.hints = MusicProviderHints(language: stated) }
        return t
    }

    @Test func aStatedLanguageIsUsedEvenWhenTheTitleIsInLatinLetters() {
        #expect(MusicLanguageDetector.language(of: track("Some Title", stated: "telugu")) == .telugu)
        #expect(MusicLanguageDetector.language(of: track("Some Title", stated: "Hindi")) == .hindi)
        #expect(MusicLanguageDetector.language(of: track("Some Title", stated: "ko")) == .korean)
    }

    @Test func aStatedLanguageBeatsTheWritingSystemOfTheTitle() {
        #expect(MusicLanguageDetector.language(of: track("తెలుగు పాట", stated: "hindi")) == .hindi)
    }

    @Test func withNothingStatedTheScriptIsOnlyAFallbackAndLatinIsNeverAnIndianLanguage() {
        #expect(MusicLanguageDetector.stated(track("తెలుగు పాట")) == nil)
        #expect(MusicLanguageDetector.language(of: track("తెలుగు పాట")) == .telugu)         // the weak guess, for non-Latin scripts only
        #expect(MusicLanguageDetector.language(of: track("Plain English Title")) == .latin)    // never guessed to be Telugu or Hindi
    }

    @Test func aLanguageTheListDoesNotHaveFallsBackInsteadOfBeingInvented() {
        #expect(MusicLanguage(stated: "klingon") == nil && MusicLanguage(stated: "") == nil)
        #expect(MusicLanguageDetector.language(of: track("Plain English Title", stated: "klingon")) == .latin)
    }

    @Test func aProfileCountsStatedLanguagesSoLatinTitledSongsAreNotLost() {
        let tracks = (0..<6).map { track("Song \($0)", stated: "tamil") } + [track("Another Song")]
        let p = MusicLanguageProfile.build(from: tracks)
        #expect(p.found(minCount: 3).first == .tamil)
        #expect(p.dominant(minShare: 0.3, minCount: 3) == .tamil)
    }

    /// Real chart records say nothing about language: none may be given one just because of the letters in its title.
    @Test func realChartRecordsWithoutALanguageAreNeverGivenOneFromLatinLetters() {
        for f in RandomRegionsHomeTests.fixtures {
            for r in f.regions {
                for rec in r.songs {
                    guard let name = rec.name else { continue }
                    let t = track(name, artist: rec.artist ?? "A")
                    #expect(MusicLanguageDetector.stated(t) == nil, "seed \(f.seed), \(r.code): \(rec.id ?? "?")")
                    if name.unicodeScalars.allSatisfy({ $0.value < 0x250 || !$0.properties.isAlphabetic }) {
                        let l = MusicLanguageDetector.language(of: t)
                        #expect(l == .latin || l == nil, "seed \(f.seed), \(r.code): “\(name)” was called \(String(describing: l))")
                    }
                }
            }
        }
    }
}
