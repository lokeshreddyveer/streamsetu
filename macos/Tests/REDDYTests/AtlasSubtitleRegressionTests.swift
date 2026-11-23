import Testing
import Foundation
@testable import REDDY

/// The owner's screenshots: a clear how-to must be answered, not met with a bare "Did you mean" list.
@MainActor @Suite("Atlas: how-to is answered, chips open by id", .serialized) struct AtlasSubtitleRegressionTests {
    let engine = AtlasFixture.engine
    func ask(_ q: String) -> AtlasAnswer { var c = AtlasConversation(); return engine.answer(q, conversation: &c, platform: .mac) }

    @Test(arguments: ["How do I turn on subtitles?", "turn on subtitles by default", "show subtitles", "how can i enable subtitles", "how do i get subtitles to show", "subtitles on by default how"])
    func aSubtitleHowToIsAnswered(_ q: String) {
        let a = ask(q)
        #expect(!a.text.hasPrefix("Did you mean"), "\(q) -> \(a.text)")
        #expect(a.decision != .weak, "\(q)")
        #expect(a.actions.contains { $0.kind == .openThis } || a.actions.contains { $0.kind == .showMe }, "\(q) has a button")
        let first = engine.entry(a.entryIDs[0])
        #expect(first?.title.lowercased().contains("subtitle") == true, "\(q) -> \(a.entryIDs[0])")
    }

    @Test func chipsCarryTheirEntryAndAnAnswerByIdNeedsNoSearch() {
        let a = ask("How do I turn on subtitles?")
        let picks = a.actions.filter { $0.kind == .pick }
        for p in picks {
            let e = engine.entry(p.entryID)
            #expect(e != nil)
            let r = Compose.compose(intent: .howDoI, entry: e!, platform: .mac, current: nil, value: nil)
            #expect(r.entryIDs == [p.entryID] && !r.text.isEmpty && r.decision == .confident)
        }
    }
}
