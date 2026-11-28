import Testing
import Foundation
@testable import REDDY

@Suite("Sidebar gaps round 3") @MainActor struct SidebarGaps3Tests {
    @Test func findRequestIsTakenOncePerRaise() {
        let r = MusicLyricsFindRequest()
        let before = r.token
        let none = r.take()
        r.raise()
        #expect(r.token == before + 1)
        let first = r.take()
        let second = r.take()
        #expect(!none)
        #expect(first)
        #expect(!second)
    }

    @Test func playingFromNeverNamesAProvider() {
        let line = MusicPlayingFrom.line(source: "Provider", providerNames: ["provider"])
        #expect(line == nil)
        let own = MusicPlayingFrom.line(source: "My Mix", providerNames: ["provider"])
        #expect(own == "My Mix")
    }
}
