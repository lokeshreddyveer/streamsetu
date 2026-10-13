import Testing
import Foundation
@testable import REDDY

@Suite struct NetworkRecoveryTests {
    private func react(_ old: NetworkLink, _ new: NetworkLink, _ state: PlaybackState, stream: Bool = true) -> NetworkReaction {
        NetworkRecovery.reaction(from: old, to: new, state: state, hasStream: stream)
    }

    @Test func losingTheConnectionWhilePlayingOrStartingWaitsInsteadOfFailing() {
        for s: PlaybackState in [.playing, .buffering, .resolving, .preparing, .recovering] { #expect(react(.wifi, .none, s) == .markOffline) }
        #expect(react(.wifi, .none, .paused) == .ignore)
        #expect(react(.wifi, .none, .idle) == .ignore)
    }

    @Test func theConnectionComingBackRestartsAStuckStreamButNotAPlayingOne() {
        for s: PlaybackState in [.buffering, .recovering, .resolving, .failed(PlaybackError(.network))] { #expect(react(.none, .wifi, s) == .resume) }
        for s: PlaybackState in [.playing, .paused, .idle, .ended] { #expect(react(.none, .cellular, s) == .ignore) }
    }

    @Test func switchingBetweenWifiAndMobileDataChecksTheStreamSoon() {
        #expect(react(.wifi, .cellular, .playing) == .checkAfterSwitch)
        #expect(react(.cellular, .wifi, .buffering) == .checkAfterSwitch)
    }

    @Test func nothingHappensWithoutAStreamOrChange() {
        #expect(react(.wifi, .none, .playing, stream: false) == .ignore)
        #expect(react(.wifi, .wifi, .playing) == .ignore)
    }

    @Test func aSwitchRestartsOnlyAStreamThatIsStuck() {
        for s: PlaybackState in [.buffering, .recovering, .resolving, .preparing, .failed(PlaybackError(.timeout))] { #expect(NetworkRecovery.shouldRestartAfterSwitch(state: s)) }
        for s: PlaybackState in [.playing, .paused, .idle, .ended, .seeking] { #expect(!NetworkRecovery.shouldRestartAfterSwitch(state: s)) }
    }

    @Test func offlineFailuresWaitAndOnlineOnesRetry() {
        for k: PlaybackError.Kind in [.network, .timeout, .providerUnavailable, .nameLookup] {
            #expect(NetworkRecovery.waitsForConnection(kind: k, online: false))
            #expect(!NetworkRecovery.waitsForConnection(kind: k, online: true))
        }
        for k: PlaybackError.Kind in [.authorization, .notFound, .providerBusy, .unsupportedFormat, .unknown] { #expect(!NetworkRecovery.waitsForConnection(kind: k, online: false)) }
    }
}
