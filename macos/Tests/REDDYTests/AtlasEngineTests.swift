import Testing
import Foundation
@testable import REDDY

@MainActor @Suite("Atlas: import and engine") struct AtlasEngineTests {
    @Test func importCoversTheExistingKnowledge() {
        let e = AtlasFixture.entries
        #expect(e.filter { $0.kind == .setting }.count >= AppSettingsCatalog.all.count, "every catalogue row is still an entry")
        #expect(e.filter { $0.id.hasPrefix("guide.") }.count == AppGuide.articles.count)
        #expect(e.filter { $0.id.hasPrefix("screen.tab.") }.count == AppTab.allCases.count)
        #expect(Set(e.map(\.id)).count == e.count, "ids must be unique")
    }

    @Test func guideOnlySettingsNeverGetAChangeButton() {
        for id in ["setting.appLock", "setting.proxy", "setting.parental"] {
            let e = AtlasFixture.entry(id)
            #expect(e != nil)
            #expect(e?.guideOnly == true)
            #expect(e?.mayPropose == false)
            var c = AtlasConversation()
            let a = AtlasFixture.engine.answer("turn \(e?.title ?? "") off", conversation: &c)
            #expect(!a.actions.contains { $0.kind == .changeIt }, "\(id) offered a change button")
        }
        // Every non-changeable entry is also unable to propose.
        for e in AtlasFixture.entries where e.safety == .read || e.safety == .never { #expect(!e.mayPropose) }
    }

    @Test func aChangeableSettingOffersChangeIt() {
        var c = AtlasConversation()
        let a = AtlasFixture.engine.answer("turn on reduce animation", conversation: &c)
        #expect(a.entryIDs.first == "setting.reduceMotion")
        #expect(a.actions.contains { $0.kind == .changeIt })
    }

    @Test func normalisation() {
        #expect(Normalise.clean("What’s the  Shortcut?!") == "what is the shortcut")
        #expect(Normalise.clean("Don't café") == "do not cafe")
        #expect(Normalise.stem("subtitles") == Normalise.stem("subtitle"))
        #expect(Normalise.stem("buffering") == Normalise.stem("buffer"))
    }

    @Test func spellingNeverChangesAKnownWordAndFixesTypos() {
        let s = SpellCorrector(vocabulary: ["hardware": 5, "decoding": 4, "subtitle": 9, "tv": 2])
        #expect(s.correct("hardware") == "hardware")
        #expect(s.correct("harware") == "hardware")
        #expect(s.correct("subtitel") == "subtitle")
        #expect(s.correct("tvx") == "tvx")            // short words are left alone
        #expect(s.correct("zzzzzz") == "zzzzzz")
    }

    @Test func synonymTableHasNoCycles() { #expect(!Synonyms.hasCycle()) }

    @Test func typosStillFindTheSetting() {
        let r = AtlasFixture.engine.retrieve("harware decoding setting")
        #expect(r.hits.first?.entry.id == "setting.hardwareDecoding")
    }

    @Test func intents() {
        #expect(IntentDetector.detect("where is hardware decoding").intent == .whereIs)
        #expect(IntentDetector.detect("how do i turn off subtitles").intent == .howDoI)
        #expect(IntentDetector.detect("what does deinterlacing do").intent == .whatDoes)
        #expect(IntentDetector.detect("why is the guide empty").intent == .whyBroken)
        #expect(IntentDetector.detect("shortcut for search").intent == .shortcutFor)
        #expect(IntentDetector.detect("what's new").intent == .whatsNew)
        #expect(IntentDetector.detect("turn subtitles off").intent == .setValue)
        #expect(IntentDetector.detect("what can i do here").intent == .whatCanIDoHere)
    }

    @Test func followUpsUseTheLastAnswer() {
        var c = AtlasConversation()
        let e = AtlasFixture.engine
        let first = e.answer("where is hardware decoding", conversation: &c)
        #expect(first.entryIDs.first == "setting.hardwareDecoding")
        let choices = e.answer("what are the choices", conversation: &c)
        #expect(choices.text.contains("Choices") || choices.text.contains("choices"))
        #expect(choices.entryIDs == ["setting.hardwareDecoding"])
        let show = e.answer("show me", conversation: &c)
        #expect(show.actions.first?.kind == .showMe)
        let how = e.answer("how do i change it", conversation: &c)
        #expect(how.entryIDs == ["setting.hardwareDecoding"])
        let phone = e.answer("and on iphone", conversation: &c)
        #expect(phone.entryIDs == ["setting.hardwareDecoding"])
    }

    @Test func aPronounWithNoHistoryAsksWhichSetting() {
        var c = AtlasConversation()
        #expect(AtlasFixture.engine.answer("how do i change it", conversation: &c).text == "Which setting do you mean?")
        #expect(AtlasFixture.engine.answer("what does it do", conversation: &c).text == "Which setting do you mean?")
    }

    @Test func conversationForgetsAfterTenIdleMinutes() {
        var c = AtlasConversation()
        let t0 = Date()
        _ = AtlasFixture.engine.answer("where is hardware decoding", conversation: &c, now: t0)
        #expect(!c.isEmpty)
        let a = AtlasFixture.engine.answer("show me", conversation: &c, now: t0.addingTimeInterval(601))
        #expect(a.text == "Which setting do you mean?")
    }

    @Test func nonsenseGetsTheHonestFallback() {
        var c = AtlasConversation()
        let a = AtlasFixture.engine.answer("qwzx plorf", conversation: &c)
        #expect(a.decision == .weak)
        #expect(a.text.contains("not sure"))
    }

    @Test func entriesSurviveAJSONRoundTrip() throws {
        let data = try JSONEncoder().encode(AtlasFixture.entries)
        let back = try JSONDecoder().decode([AtlasEntry].self, from: data)
        #expect(back == AtlasFixture.entries)
    }

    @Test func platformFilterHidesDmgOnlyInTheStoreBuild() {
        var e = AtlasFixture.entries.first { $0.id == "setting.reduceMotion" }!
        e.platforms = [.mac, .dmgOnly]
        let eng = SetuEngine(entries: [e])
        #expect(eng.retrieve("reduce animation", appStore: false).hits.count == 1)
        #expect(eng.retrieve("reduce animation", appStore: true).hits.isEmpty)
        #expect(eng.retrieve("reduce animation", platform: .iPhone).hits.isEmpty)
    }
}

extension AtlasFixture { static func entry(_ id: String) -> AtlasEntry? { entries.first { $0.id == id } } }
