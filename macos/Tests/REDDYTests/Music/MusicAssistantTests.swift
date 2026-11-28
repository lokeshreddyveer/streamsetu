import Testing
import Foundation
@testable import REDDY

@MainActor
@Suite("Setu and Music") struct MusicAssistantTests {
    @Test func everyMusicActionHasASpecAndATitle() {
        let all: [MusicAssistantAction] = [.control("pause"), .play(query: "x", kind: "song", shuffle: true), .radio(query: nil), .open("explore"), .country("in")]
        for a in all {
            let p = AssistantProposal(kind: .music(a), origin: AssistantProposal.Origin(profileID: "p"))
            #expect(!p.title.isEmpty && !p.symbol.isEmpty)
            #expect(AssistantActions.spec(for: .music(a)).id.hasPrefix("music."))
        }
    }

    @Test func titlesReadWell() {
        #expect(MusicAssistantAction.play(query: "Kesariya", kind: "song", shuffle: true).title == "Shuffle “Kesariya” in Music")
        #expect(MusicAssistantAction.country("worldwide").title == "Show worldwide charts in Music")
        #expect(MusicAssistantAction.country("in").title == "Show the charts of IN in Music")
    }

    @Test func everyScreenNameMapsToASection() {
        for s in MusicAssistantAction.screens { #expect(MusicAssistantBridge.section(for: s) != nil, "\(s)") }
        #expect(MusicAssistantBridge.section(for: "nope") == nil)
    }

    @Test func toolsAreListedInTheCoverageTable() throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-mu-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let box = AssistantToolbox(container: c)
        for t in box.specs(compact: false).map(\.name) where t.hasPrefix("music_") { #expect(AssistantCoverage.tools[t] != nil, Comment(rawValue: t)) }
    }
}
