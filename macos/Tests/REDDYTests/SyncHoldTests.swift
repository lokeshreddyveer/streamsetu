import Testing
import Foundation
@testable import REDDY

@Suite struct SyncHoldTests {
    @Test func playbackStatesThatHoldBackRefresh() {
        for s in [PlaybackState.playing, .buffering, .recovering, .preparing] { #expect(s == .playing || s.isBusy) }
        for s in [PlaybackState.idle, .paused, .ended] { #expect(!(s == .playing || s.isBusy)) }
    }
}
