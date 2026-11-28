import Foundation
import Testing
@testable import REDDY

@Suite struct PersonHeaderTests {
    @Test func namesInBothScripts() async throws {
        let w = try await PersonWorld.make()
        let snap = try #require(try await w.store.entity(w.raj))
        let aliases = try await w.store.aliases(of: w.raj)
        let h = MusicPersonHeaderData.build(snapshot: snap, aliases: aliases)
        #expect(h.names.display == "Raj Kapoor")
        // The other spelling is in a language that is the person's or the reader's: with Hindi known (the native language Wikidata states), the Hindi spelling is the one shown.
        #expect(MusicPersonNames.resolve(snapshot: snap, aliases: aliases, languages: ["hi"]).otherScript == "राज कपूर")
        #expect(MusicPersonNames.resolve(snapshot: snap, aliases: aliases, languages: ["xx"]).otherScript == nil || MusicPersonNames.readerLanguages.contains("hi"))
        #expect(h.life?.shape == .span(1924, 1988))
        #expect(h.bio?.text == "Indian actor, film director and producer" && h.bio?.source == "Wikidata" && h.bio?.attributionRequired == false)
        #expect(h.initials == "RK")
        #expect(!h.isGroup)
    }

    @Test func noOtherScriptWhenNoAliasHasOne() {
        let s = MusicEntitySnapshot(id: .derive(kind: .person, aliasKey: "x"), subkind: nil, name: "Raj Kapoor", nameLatin: "raj kapur", lang: nil, year: nil, yearEnd: nil, country: nil, durationMs: nil,
                                   imageRef: nil, attrs: [:], provisional: false, state: .live, pinned: false, mergedInto: nil, createdAt: .distantPast, updatedAt: .distantPast)
        #expect(MusicPersonNames.resolve(snapshot: s, aliases: [NameAlias("Raj Kapoor Jr"), NameAlias("Raj Kapoor")]).otherScript == nil)
        // a native-script entity name shows its romanised alias
        var native = s; native.name = "राज कपूर"
        #expect(MusicPersonNames.resolve(snapshot: native, aliases: [NameAlias("Raj Kapoor", isPrimary: true)]).otherScript == "Raj Kapoor")
    }

    @Test func portraitResolution() {
        let commons = MusicPortraitRef.resolve(imageRef: "commons:Raj Kapoor.jpg")
        #expect(commons?.creditSource == "Wikimedia Commons" && commons?.creditURL?.absoluteString.contains("File:Raj_Kapoor.jpg") == true)
        #expect(commons?.url.absoluteString.contains("Special:FilePath") == true)
        let tmdb = MusicPortraitRef.resolve(imageRef: "https://image.tmdb.org/t/p/w185/x.jpg")
        #expect(tmdb?.creditSource == "TMDB")
        let provider = MusicPortraitRef.resolve(imageRef: "https://c.saavncdn.com/artists/a.jpg")
        #expect(provider?.creditSource == nil && provider?.origin == .provider)
        #expect(MusicPortraitRef.resolve(imageRef: nil) == nil)
        #expect(MusicPortraitRef.resolve(imageRef: "http://insecure.example/a.jpg") == nil)
        #expect(MusicPortraitRef.resolve(imageRef: "file:///etc/passwd") == nil)
        let record = MusicPortraitRef.Licence(author: "A. Photographer", licence: "CC BY-SA 4.0", attributionRequired: true)
        #expect(commons?.creditLine(licence: record) == "A. Photographer · CC BY-SA 4.0 · Wikimedia Commons")
        #expect(commons?.creditLine(licence: nil) == "Wikimedia Commons")
    }

    @Test func personWithNoPortraitHasInitialsAndNoCredit() async throws {
        let w = try await PersonWorld.make()
        let snap = try #require(try await w.store.entity(w.nobody))
        let h = MusicPersonHeaderData.build(snapshot: snap, aliases: [])
        #expect(h.portrait == nil && h.initials == "US" && h.bio == nil && h.life == nil && h.disambiguator == nil)
        #expect(MusicPersonText.initials("राज कपूर") == "राक")
    }

    @Test func groupHeaderShowsActiveYearsAndKind() async throws {
        let w = try await PersonWorld.make()
        let snap = try #require(try await w.store.entity(w.sj))
        let h = MusicPersonHeaderData.build(snapshot: snap, aliases: [])
        #expect(h.isGroup && h.groupKind == "duo" && h.life?.shape == .activeSpan(1949, 1971))
    }

    @Test func bioRequiresASourceAndCreditsLicence() {
        func snap(_ attrs: [String: String]) -> MusicEntitySnapshot {
            MusicEntitySnapshot(id: .derive(kind: .person, aliasKey: "b"), subkind: nil, name: "B", nameLatin: "b", lang: nil, year: nil, yearEnd: nil, country: nil, durationMs: nil, imageRef: nil,
                                attrs: attrs, provisional: false, state: .live, pinned: false, mergedInto: nil, createdAt: .distantPast, updatedAt: .distantPast)
        }
        #expect(MusicPersonBio.resolve(snapshot: snap(["bio": "Text without a source"])) == nil)
        let wiki = MusicPersonBio.resolve(snapshot: snap(["bio": "Text", "bioSource": "wikipedia"]))
        #expect(wiki?.source == "Wikipedia" && wiki?.licence == "CC BY-SA" && wiki?.attributionRequired == true)
        #expect(MusicPersonBio.resolve(snapshot: snap(["bio": "Text", "bioSource": "tmdb"]))?.source == "TMDB")
        let long = MusicPersonBio.resolve(snapshot: snap(["description": String(repeating: "word ", count: 120)]))
        #expect((long?.text.count ?? 0) <= 281 && long?.text.hasSuffix("…") == true)
    }
}

@Suite("Person header: names, bio and portrait for any person") struct PersonWikiRulesTests {
    @Test func theNativeNameIsInTheNativeLanguageNeverTheFirstScriptStored() {
        let aliases = [NameAlias("Паван Кальян", lang: "ru"), NameAlias("パワン・カリヤーン", lang: "ja"), NameAlias("పవన్ కళ్యాణ్", lang: "te"), NameAlias("पवन कल्याण", lang: "hi")]
        var s = MusicEntitySnapshot.stub(name: "Pawan Kalyan", lang: nil)
        s.nameLatin = "pavan kalyan"
        #expect(MusicPersonNames.resolve(snapshot: s, aliases: aliases, languages: ["te"]).otherScript == "పవన్ కళ్యాణ్")
        #expect(MusicPersonNames.resolve(snapshot: s, aliases: aliases, languages: ["hi"]).otherScript == "पवन कल्याण")
        // nothing says which language is the person's or the reader's: no spelling is shown rather than a random one
        #expect(MusicPersonNames.resolve(snapshot: s, aliases: aliases, languages: ["xx"]).otherScript == nil || MusicPersonNames.readerLanguages.contains { ["ru", "ja", "te", "hi"].contains($0) })
        #expect(MusicPersonWikiRules.nativeName(aliases: aliases, displayIsLatin: true, display: "Pawan Kalyan", languages: ["ml", "te"]) == "పవన్ కళ్యాణ్")
    }

    @Test func sitelinksGiveTheArticleTitlePerWikiAndTheReaderGetsTheirOwnLanguageFirst() {
        let titles = MusicPersonWikiRules.titles(sitelinks: "arwiki:باوان|enwiki:Pawan Kalyan|hiwiki:पवन कल्याण|commonswiki:Category:X|simplewiki:Y|tewiki:పవన్ కళ్యాణ్")
        #expect(titles["en"] == "Pawan Kalyan" && titles["te"] == "పవన్ కళ్యాణ్" && titles["commons"] == nil && titles["simple"] == nil)
        #expect(MusicPersonWikiRules.chooseWiki(titles: titles, preferred: ["te", "en"])?.lang == "te")
        #expect(MusicPersonWikiRules.chooseWiki(titles: titles, preferred: ["fr"])?.lang == "en")
        #expect(MusicPersonWikiRules.chooseWiki(titles: ["fr": "X"], preferred: ["de"]) == nil)
    }

    @Test func theOpeningIsWholeSentencesNotCutAtInitialsAndNeverMidWord() {
        let t = "Allah Rakha Rahman, known as A. R. Rahman, is an Indian composer and singer. He is known for Roja and Slumdog Millionaire. He has won two Academy Awards and many other prizes in a long career."
        let short = MusicPersonWikiRules.shortExtract(t)
        #expect(short == "Allah Rakha Rahman, known as A. R. Rahman, is an Indian composer and singer. He is known for Roja and Slumdog Millionaire.")
        #expect(MusicPersonWikiRules.shortExtract(t, maxSentences: 1) == "Allah Rakha Rahman, known as A. R. Rahman, is an Indian composer and singer.")
        #expect(MusicPersonWikiRules.shortExtract("   ") == nil)
        #expect((MusicPersonWikiRules.shortExtract(String(repeating: "word ", count: 200), maxChars: 50) ?? "").count <= 52)
    }

    @Test func aSentenceEndingInAShortWordIsStillTheEndOfTheSentence() {
        let t = "He was born in the UK. He moved to the US. He then sang in Telugu cinema."
        #expect(MusicPersonWikiRules.shortExtract(t, maxSentences: 1) == "He was born in the UK.")
    }

    @Test func aLongFirstSentenceIsCutAtAWholeWord() {
        let t = String(repeating: "alphabet ", count: 100)
        let cut = MusicPersonWikiRules.shortExtract(t, maxChars: 30) ?? ""
        #expect(cut == "alphabet alphabet alphabet…")
    }

    @Test func aPosterOrALogoIsNeverThePortraitAndTheFirstRealPhotoIs() {
        #expect(!MusicPersonWikiRules.isPortraitFile("Hari Hara Veera Mallu poster.jpg") && !MusicPersonWikiRules.isPortraitFile("Band logo.png") && !MusicPersonWikiRules.isPortraitFile("X.svg"))
        #expect(MusicPersonWikiRules.choosePortrait(["Film poster.jpg", "Shri Konidela Pawan Kalyan.jpg", "Other.jpg"]) == "Shri Konidela Pawan Kalyan.jpg")
        #expect(MusicPersonWikiRules.choosePortrait(["Soundtrack cover.jpg"]) == nil)
    }

    @Test func aDisambiguationPageOrAnotherItemIsNotThePersonsSummary() {
        let d = MusicPersonWikiRules.parseSummary(Data(#"{"type":"disambiguation","description":"Topics referred to by the same term","extract":"X may refer to:","wikibase_item":"Q1"}"#.utf8))!
        #expect(!MusicPersonWikiRules.summaryBelongs(d, to: "Q1"))
        let ok = MusicPersonWikiRules.parseSummary(Data(#"{"type":"standard","description":"Indian politician and actor (born 1971)","extract":"Konidela Pawan Kalyan is an Indian politician.","wikibase_item":"Q6067643"}"#.utf8))!
        #expect(MusicPersonWikiRules.summaryBelongs(ok, to: "Q6067643") && !MusicPersonWikiRules.summaryBelongs(ok, to: "Q42"))
    }

    @Test func claimsGiveThePortraitsAndTheNativeLanguage() {
        let json = #"{"entities":{"Q6067643":{"claims":{"P18":[{"mainsnak":{"datavalue":{"value":"A.jpg"}}},{"mainsnak":{"datavalue":{"value":"B.jpg"}},"rank":"deprecated"}],"P103":[{"mainsnak":{"datavalue":{"value":{"id":"Q8097"}}}}]}}}}"#
        let c = MusicPersonWikiRules.parseClaims(Data(json.utf8), qid: "Q6067643")
        #expect(c?.portraits == ["A.jpg"] && c?.nativeQID == "Q8097" && MusicWikidataLanguages.code(forQID: "Q8097") == "te")
    }
}
