import Testing
import Foundation
@testable import REDDY

@Suite("A missing saved login") struct LoginMissingTests {
    @Test func isItsOwnErrorAndIsNotRetried() {
        let e = PlaybackError.classify(SourceError.credentialsMissing)
        #expect(e.kind == .loginMissing)
        #expect(e.message == "The saved login for this playlist could not be found.")
        #expect(!e.isTransient)
        let action = PlaybackRecoveryService().decide(error: e, attempt: 0, current: .avPlayer, available: [.avPlayer], isLive: true)
        #expect(action == .giveUp)
        #expect(VariantFallback.next(variants: [], tried: [], errorKind: .loginMissing) == nil)
        #expect(AssistantDiagnostics.playback({ var x = PlaybackEvidence(); x.playing = false; x.failure = e; x.failureIsRecent = true; return x }()).cause == .credentials)
    }
}
