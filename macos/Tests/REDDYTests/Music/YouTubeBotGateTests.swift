import Testing
import Foundation
@testable import REDDY

private final class Clock: @unchecked Sendable {
    private let lock = NSLock(); private var t = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
}

@Suite("YouTube's bot check closes the gate, so a blocked connection is not hammered") struct YouTubeBotGateTests {
    private func gate(_ c: Clock) -> YouTubeBotGate { YouTubeBotGate(now: { c.now }) }
    private let bot = ("LOGIN_REQUIRED", "Sign in to confirm you’re not a bot")

    @Test func onlyTheBotCheckCounts() {
        #expect(YouTubeBotGate.isBotCheck(status: bot.0, reason: bot.1))
        #expect(!YouTubeBotGate.isBotCheck(status: "LOGIN_REQUIRED", reason: "Sign in to confirm your age"), "the age check is about one video")
        #expect(!YouTubeBotGate.isBotCheck(status: "UNPLAYABLE", reason: "Sign in to confirm you’re not a bot"))
        #expect(!YouTubeBotGate.isBotCheck(status: "OK", reason: ""))
    }

    @Test func twoDifferentVideosRefusedCloseItButOneVideoDoesNot() {
        let c = Clock(), g = gate(c)
        #expect(!g.observe(status: bot.0, reason: bot.1, videoID: "AAAAAAAAAAA") && !g.isClosed)
        #expect(!g.observe(status: bot.0, reason: bot.1, videoID: "AAAAAAAAAAA") && !g.isClosed, "the same video again is still one video")
        #expect(g.observe(status: bot.0, reason: bot.1, videoID: "BBBBBBBBBBB") && g.isClosed)
        #expect(g.secondsLeft > 800 && g.secondsLeft <= YouTubeBotGate.cooldown)
    }

    @Test func refusalsFarApartDoNotAddUp() {
        let c = Clock(), g = gate(c)
        g.observe(status: bot.0, reason: bot.1, videoID: "AAAAAAAAAAA")
        c.advance(YouTubeBotGate.window + 5)
        #expect(!g.observe(status: bot.0, reason: bot.1, videoID: "BBBBBBBBBBB") && !g.isClosed)
    }

    @Test func itOpensAfterTheCooldownAndAtOnceWhenAudioPlays() {
        let c = Clock(), g = gate(c)
        g.recordRefusal(videoID: "AAAAAAAAAAA"); g.recordRefusal(videoID: "BBBBBBBBBBB")
        #expect(g.isClosed)
        c.advance(YouTubeBotGate.cooldown + 1)
        #expect(!g.isClosed && g.secondsLeft == 0)
        g.recordRefusal(videoID: "CCCCCCCCCCC"); g.recordRefusal(videoID: "DDDDDDDDDDD")
        #expect(g.isClosed)
        g.reset()
        #expect(!g.isClosed, "a song that plays proves the connection is fine")
    }

    @Test func aPlayerAnswerIsReadAsTheYouTubeShapeWithoutAnythingElseInIt() {
        let g = gate(Clock())
        let answer: [String: Any] = ["playabilityStatus": ["status": "LOGIN_REQUIRED", "reason": "Sign in to confirm you’re not a bot"]]
        #expect(!g.observe(answer, videoID: "AAAAAAAAAAA"))
        #expect(g.observe(answer, videoID: "BBBBBBBBBBB"))
        #expect(!g.observe("not a dictionary", videoID: "CCCCCCCCCCC"))
        #expect(YouTubeBotGate.message.contains("Sign in to YouTube Music"), "the message says what helps")
    }

    @Test func audioRequestsAreSpacedInsteadOfSentAsOneBurst() async {
        let pacer = YouTubeRequestPacer(gap: 0.2)
        let began = Date()
        for _ in 0..<4 { await pacer.wait() }
        #expect(Date().timeIntervalSince(began) >= 0.55, "four requests take at least three gaps")
    }

    @Test func theGuestProviderSendsTheSameCurrentIdentityAsTheMainEngine() throws {
        let id = try #require(YTMClientTable.builtIn[.visionOS])
        #expect(id.clientVersion != "0.1", "not the old hard-coded identity")
        #expect(!id.userAgent.isEmpty && id.deviceModel != nil && id.osVersion != nil)
    }
}
