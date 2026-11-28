import Testing
@testable import REDDY

@Suite("An album the graph had never seen fills in by itself") @MainActor struct LateGraphReadTests {
    @Test func theLimitKeepsAPageFromLoopingOnGraphChanges() {
        #expect(MusicSoundtrackPageModel.lateReadLimit >= 1 && MusicSoundtrackPageModel.lateReadLimit <= 6, "a few quiet re-reads, never an endless one")
    }
}
