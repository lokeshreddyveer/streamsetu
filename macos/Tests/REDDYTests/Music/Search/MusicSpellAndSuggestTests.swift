import Testing
import Foundation
@testable import REDDY

@Suite("Music spelling and local suggestions") struct MusicSpellAndSuggestTests {
    static func index() -> MusicSpellIndex {
        var s = MusicSpellIndex()
        for t in ["Zinda Hai Tu", "Kabhi Khushi Kabhie Gham", "Tum Hi Ho", "Arijit Singh", "Ilaiyaraaja", "Chitti Chitti Cheema", "Diviki Diviki", "Naatu Naatu", "Sita Ramam"] {
            s.add(text: t, weight: 5)
        }
        s.prepare()
        return s
    }

    @Test func fixesTyposAndOtherSpellings() {
        let s = Self.index()
        #expect(s.corrected(query: "arjit singh", typingLastWord: false).text == "arijit singh")
        #expect(s.corrected(query: "kabhi kushi", typingLastWord: false).text == "kabhi khushi")
        #expect(s.corrected(query: "chiti chiti cheema", typingLastWord: false).text == "chitti chitti cheema")
        #expect(s.corrected(query: "natu natu", typingLastWord: false).text == "naatu naatu")
        #expect(s.corrected(query: "jinda hai tu", typingLastWord: false).text == "zinda hai tu")
        #expect(s.corrected(query: "tum hi ho", typingLastWord: false).changed == false)
    }

    @Test func neverFightsTypingOrInventsCorrections() {
        let s = Self.index()
        #expect(s.corrected(query: "ariji").changed == false)
        #expect(s.corrected(query: "tum h").changed == false)
        #expect(s.corrected(query: "qwertyuiop", typingLastWord: false).changed == false)
    }

    @Test func swapCountsAsOneKeystroke() {
        #expect(MusicSpellIndex.distance("abcd", "abdc", limit: 2) == 1)
        #expect(MusicSpellIndex.distance("kitten", "sitting", limit: 5) == 3)
    }

    @Test func localSuggestionsMatchByStartWordSoundAndSpelling() async {
        let m = MusicLocalSuggestions()
        await m.add(["Zinda Hai Tu", "Arijit Singh", "Arijit Singh Live"], kind: .song, weight: 3)
        await m.add("arijit singh songs", kind: .recent, weight: 1)
        let a = await m.suggest("arij")
        #expect(a.suggestions.first?.kind == .recent)
        #expect(a.suggestions.contains { $0.text == "Arijit Singh" })
        #expect((await m.suggest("arjit")).suggestions.contains { $0.text == "Arijit Singh" })
        #expect((await m.suggest("jinda")).suggestions.contains { $0.text.hasPrefix("Zinda") })
        #expect((await m.suggest("singh")).suggestions.contains { $0.text == "Arijit Singh" })
        #expect(await m.didYouMean("arjit singh") == "arijit singh")
        #expect(await m.didYouMean("arijit singh") == nil)
    }

    @Test func aStoredPhraseIsKeptOnceAndForgottenOnReset() async {
        let m = MusicLocalSuggestions()
        await m.add("Tum Hi Ho", kind: .song); await m.add("tum hi ho", kind: .recent)
        #expect(await m.count == 1)
        await m.reset()
        #expect(await m.count == 0)
    }

    @Test func answersQuicklyOverManyPhrases() async {
        let m = MusicLocalSuggestions()
        await m.add((0..<20_000).map { "Song number \($0) kabhi khushi \($0 % 977) tune" }, kind: .song)
        await m.warm()
        let t0 = ContinuousClock.now
        for _ in 0..<10 { _ = await m.suggest("kabhi kushi tu") }
        #expect((ContinuousClock.now - t0) / 10 < .milliseconds(150))   // generous: test builds are unoptimised
    }

    @Test func personSectionsThatSayTheSameThingBecomeOne() {
        func e(_ n: String, _ year: Int?, count: Int? = nil) -> MusicPersonEntry { var x = MusicPersonEntry(id: .provisional(kind: .album, name: n, year: year), name: n, kind: .album); x.year = year; x.count = count; return x }
        let data = MusicPersonViewData(person: .provisional(kind: .person, name: "X"), view: .composer, sections: [
            MusicPersonSection(.soundtracks, [e("A", 2020), e("B", 2023)]),
            MusicPersonSection(.albums, [e("B", 2023), e("C", 2010)]),
            MusicPersonSection(.singersWorkedWith, [e("S1", nil, count: 3)]),
            MusicPersonSection(.lyricistsWorkedWith, [e("L1", nil, count: 9)])
        ], complete: true, truncated: false)
        let v = data.visible
        #expect(v.filter { $0.id == .albums }.count == 1 && !v.contains { $0.id == .soundtracks })
        #expect(v.first { $0.id == .albums }?.entries.map(\.name) == ["B", "A", "C"])          // newest first, B once
        #expect(v.first { $0.id == .collaborations }?.entries.map(\.name) == ["L1", "S1"])       // most shared work first
    }
}
