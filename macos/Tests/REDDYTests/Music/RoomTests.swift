import Testing
import Foundation
import CryptoKit
@testable import REDDY

@Suite("Listen Together") struct RoomTests {
    private func track(_ id: String = "t1", title: String = "Song", duration: Int64 = 200_000) -> MusicRoomTrack {
        MusicRoomTrack(providerID: "audius", id: id, title: title, artists: ["Artist"], album: "Album", durationMs: duration,
                       isrc: "USRC17607839", externalURL: "https://example.com/t/1")
    }

    // MARK: protocol

    @Test func messagesRoundTrip() throws {
        let anchor = MusicRoomAnchor(id: 3, track: track(), position: 12.5, hostTime: 1000, rate: 1, isPlaying: true)
        var m = MusicRoomMessage.anchor(anchor)
        var back = try MusicRoomMessage.decode(try m.encoded())
        #expect(back.kind == .anchor && back.anchor == anchor)
        m = .welcome(roomName: "Den", roster: [MusicRoomParticipant(id: "h", name: "Host", isHost: true)], queue: [track()])
        back = try MusicRoomMessage.decode(try m.encoded())
        #expect(back.roster?.count == 1 && back.tracks?.count == 1 && back.name == "Den")
        back = try MusicRoomMessage.decode(try MusicRoomMessage.pong(t0: 1, t1: 2, t2: 3).encoded())
        #expect(back.t2 == 3)
    }

    @Test func malformedMessagesAreRejected() throws {
        #expect(throws: MusicRoomError.self) { try MusicRoomMessage.decode(Data("not json".utf8)) }
        var m = MusicRoomMessage(kind: .anchor)       // an anchor without an anchor
        #expect(throws: MusicRoomError.self) { try MusicRoomMessage.decode(try m.encoded()) }
        m = MusicRoomMessage(kind: .ping)             // a ping without a time
        #expect(throws: MusicRoomError.self) { try MusicRoomMessage.decode(try m.encoded()) }
        var wrongVersion = MusicRoomMessage.leave
        wrongVersion.v = 99
        #expect(throws: MusicRoomError.unsupportedVersion) { try MusicRoomMessage.decode(try JSONEncoder().encode(wrongVersion)) }
        #expect(throws: MusicRoomError.frameTooLarge) { try MusicRoomMessage.decode(Data(count: MusicRoomLimits.maxFrame + 1)) }
        var badTrack = track(); badTrack.externalURL = "http://example.com/x"
        #expect(throws: MusicRoomError.self) { try MusicRoomMessage.decode(try MusicRoomMessage.suggest(id: "s", badTrack).encoded()) }
    }

    @Test func queueWindowIsCappedAndFitsOneFrame() throws {
        let many = (0..<80).map { track("id\($0)", title: String(repeating: "x", count: 200)) }
        let m = MusicRoomMessage.fittingQueue(many)
        let data = try m.encoded()
        #expect(data.count <= MusicRoomLimits.maxFrame)
        #expect((m.tracks?.count ?? 0) <= MusicRoomLimits.maxQueue)
        var tooMany = MusicRoomMessage.queue((0..<51).map { track("q\($0)") })
        tooMany.tracks = (0..<51).map { track("q\($0)") }
        #expect(throws: MusicRoomError.self) { try MusicRoomMessage.decode(try JSONEncoder().encode(tooMany)) }
    }

    // MARK: sanitiser

    @Test func textLosesControlCharactersAndIsCapped() {
        #expect(MusicRoomSanitizer.text("Hel\u{0007}lo\n") == "Hello")
        #expect(MusicRoomSanitizer.text("a\u{202E}b") == "ab")
        #expect(MusicRoomSanitizer.text(String(repeating: "y", count: 1000)).count == MusicRoomLimits.maxText)
    }

    @Test func urlsMustBeCleanHttps() {
        #expect(MusicRoomSanitizer.httpsURL("https://example.com/a") == "https://example.com/a")
        #expect(MusicRoomSanitizer.httpsURL("http://example.com/a") == nil)
        #expect(MusicRoomSanitizer.httpsURL("file:///etc/passwd") == nil)
        #expect(MusicRoomSanitizer.httpsURL("https://user:pw@example.com/") == nil)
        #expect(MusicRoomSanitizer.httpsURL("https://example.com/a?token=abc") == nil)
        #expect(MusicRoomSanitizer.httpsURL("https://example.com/a#frag") == "https://example.com/a")
        #expect(MusicRoomSanitizer.httpsURL("https://example.com/" + String(repeating: "a", count: 600)) == nil)
    }

    @Test func trackDescriptorsAreCleanedOrRejected() {
        var t = track(title: "Ti\u{0001}tle")
        #expect(t.sanitized()?.title == "Title")
        t = track(); t.isrc = "us-rc1-7607839"
        #expect(t.sanitized()?.isrc == "USRC17607839")
        t = track(); t.isrc = "nope"
        #expect(t.sanitized() == nil)
        t = track(); t.durationMs = -5
        #expect(t.sanitized() == nil)
        t = track(); t.durationMs = MusicRoomLimits.maxDurationMs + 1
        #expect(t.sanitized() == nil)
        t = track(); t.providerID = "bad id!"
        #expect(t.sanitized() == nil)
        t = track(); t.id = ""
        #expect(t.sanitized() == nil)
        t = track(); t.title = " \u{0000} "
        #expect(t.sanitized() == nil)
        t = track(); t.artists = (0..<20).map { "a\($0)" }
        #expect(t.sanitized()?.artists.count == MusicRoomLimits.maxArtists)
    }

    @Test func descriptorNeverCarriesAStream() {
        let own = MusicTrack(id: "1", providerID: "audius", title: "S", durationMs: 1000, artists: [MusicArtistRef(id: "a", name: "A")],
                             externalURL: "http://insecure.example/x",
                             directStreams: [MusicStream(url: "https://cdn.example/s.mp3", codec: "mp3", container: "mp3")])
        let d = MusicRoomTrack(own)
        #expect(d.externalURL == nil)
        #expect(d.asTrack().directStreams == nil)
    }

    // MARK: handshake and sealing

    @Test func bothSidesDeriveTheSameKeysOnlyWithTheSameCode() throws {
        let g = MusicRemoteHandshake.newKeyPair(), h = MusicRemoteHandshake.newKeyPair()
        let gn = MusicRemoteHandshake.randomNonce(), hn = MusicRemoteHandshake.randomNonce()
        func keys(_ priv: Curve25519.KeyAgreement.PrivateKey, _ peer: Data, _ code: String) throws -> MusicRoomHandshake.Keys {
            try MusicRoomHandshake.derive(privateKey: priv, peerPublic: peer, code: code, guestNonce: gn, hostNonce: hn,
                                          guestPublic: g.publicKey.rawRepresentation, hostPublic: h.publicKey.rawRepresentation)
        }
        let guestKeys = try keys(g, h.publicKey.rawRepresentation, "123456")
        let hostKeys = try keys(h, g.publicKey.rawRepresentation, "123456")
        var sealer = MusicRemoteSealer(key: guestKeys.guestToHost)
        var opener = MusicRemoteSealer(key: hostKeys.guestToHost)
        let sealed = try sealer.seal(Data("hello".utf8))
        #expect(try opener.open(sealed) == Data("hello".utf8))
        let wrong = try keys(h, g.publicKey.rawRepresentation, "654321")
        var badOpener = MusicRemoteSealer(key: wrong.guestToHost)
        #expect(throws: MusicRemoteError.authenticationFailed) { try badOpener.open(sealed) }
    }

    @Test func codesAreSixDigits() {
        #expect(MusicRoomHandshake.normalizedCode("123 456") == "123456")
        #expect(MusicRoomHandshake.normalizedCode("12345") == nil)
        #expect(MusicRoomHandshake.normalizedCode("1234567") == nil)
    }

    // MARK: join code lockout (the same rules as pairing)

    @Test func codeExpiresAfterTwoMinutes() {
        var g = MusicPairingGuard()
        let t0 = Date(timeIntervalSince1970: 1000)
        let v1 = g.issue(now: t0, code: "111111")
        #expect(v1 == "111111")
        #expect(g.activeCode(now: t0.addingTimeInterval(119)) == "111111")
        #expect(g.activeCode(now: t0.addingTimeInterval(121)) == nil)
    }

    @Test func fiveWrongTriesLockTheRoomForTenMinutes() {
        var g = MusicPairingGuard()
        let t0 = Date(timeIntervalSince1970: 1000)
        g.issue(now: t0, code: "111111")
        for _ in 0..<4 { g.recordFailure(now: t0) }
        #expect(!g.isLocked(now: t0) && g.activeCode(now: t0) == "111111")
        g.recordFailure(now: t0)
        #expect(g.isLocked(now: t0) && g.activeCode(now: t0) == nil)
        let v2 = g.issue(now: t0.addingTimeInterval(599))
        #expect(v2 == nil)
        let v3 = g.issue(now: t0.addingTimeInterval(601), code: "222222")
        #expect(v3 == "222222")
    }

    // MARK: clock

    @Test func clockSampleMathRecoversOffsetAndRoundTrip() throws {
        // The host's clock is 100 s ahead; the network takes 20 ms each way; the host works for 5 ms.
        let t0 = 10.0, t1 = t0 + 0.020 + 100, t2 = t1 + 0.005, t3 = t0 + 0.020 + 0.005 + 0.020
        let s = try #require(MusicRoomClockMath.sample(t0: t0, t1: t1, t2: t2, t3: t3))
        #expect(abs(s.offset - 100) < 0.0001)
        #expect(abs(s.rtt - 0.040) < 0.0001)
    }

    @Test func clockSampleRejectsImpossibleTimes() {
        #expect(MusicRoomClockMath.sample(t0: .nan, t1: 1, t2: 1, t3: 1) == nil)
        #expect(MusicRoomClockMath.sample(t0: 10, t1: 5, t2: 5, t3: 9) == nil)
        #expect(MusicRoomClockMath.sample(t0: 0, t1: 0, t2: 0, t3: 60) == nil)
    }

    @Test func estimatorKeepsTheLowestRoundTrip() {
        var e = MusicRoomClockEstimator()
        e.beginMeasurement()
        for (off, rtt) in [(5.0, 0.2), (5.3, 0.05), (4.8, 0.3), (5.1, 0.01), (6.0, 0.5)] { e.add(MusicRoomClockSample(offset: off, rtt: rtt)) }
        #expect(e.isRoundComplete)
        let v4 = e.finishMeasurement()
        #expect(v4)
        #expect(e.offset == 5.1)
        #expect(e.hostTime(forLocal: 10) == 15.1)
        // A measurement that gets no answers keeps the old offset.
        e.beginMeasurement()
        let v5 = e.finishMeasurement()
        #expect(!v5)
        #expect(e.offset == 5.1)
    }

    @Test func clockIsRemeasuredEverySixtySecondsOnlyWhilePlaying() {
        #expect(!MusicRoomClockEstimator.shouldRemeasure(lastMeasuredAt: 0, now: 59, isPlaying: true))
        #expect(MusicRoomClockEstimator.shouldRemeasure(lastMeasuredAt: 0, now: 60, isPlaying: true))
        #expect(!MusicRoomClockEstimator.shouldRemeasure(lastMeasuredAt: 0, now: 600, isPlaying: false))
    }

    // MARK: drift bands

    @Test func driftUnderEightyMillisecondsIsIgnored() {
        #expect(MusicRoomSync.decide(drift: 0.079, currentRate: 1) == .none)
        #expect(MusicRoomSync.decide(drift: -0.079, currentRate: 1) == .none)
        #expect(MusicRoomSync.decide(drift: 0, currentRate: 1) == .none)
    }

    @Test func driftBetweenEightyMillisecondsAndTwoSecondsNudgesTheRate() {
        #expect(MusicRoomSync.decide(drift: 0.081, currentRate: 1) == .setRate(0.97))   // ahead: slow down
        #expect(MusicRoomSync.decide(drift: -0.5, currentRate: 1) == .setRate(1.03))    // behind: speed up
        #expect(MusicRoomSync.decide(drift: 2.0, currentRate: 1) == .setRate(0.97))
        #expect(MusicRoomSync.decide(drift: -0.5, currentRate: 1.03) == .none)          // already nudging the right way
    }

    @Test func driftOverTwoSecondsSeeks() {
        #expect(MusicRoomSync.decide(drift: 2.01, currentRate: 1, expected: 42) == .seek(42))
        #expect(MusicRoomSync.decide(drift: -30, currentRate: 0.97, expected: 42) == .seek(42))
    }

    @Test func nudgeEndsOnceTheGapIsClosed() {
        #expect(MusicRoomSync.decide(drift: 0.02, currentRate: 0.97) == .setRate(1))
        #expect(MusicRoomSync.decide(drift: .nan, currentRate: 1) == .none)
    }

    @Test func recheckDelayIsCappedAtTenSeconds() {
        #expect(MusicRoomSync.recheckDelay(forDrift: 1.9) == 10)
        #expect(MusicRoomSync.recheckDelay(forDrift: 0.09) < 5)
        #expect(MusicRoomSync.recheckDelay(forDrift: 0.09) >= 0.5)
    }

    // MARK: anchors

    @Test func anchorExtrapolatesWhilePlayingAndStandsStillWhenPaused() {
        var a = MusicRoomAnchor(id: 1, track: track(duration: 100_000), position: 10, hostTime: 500, rate: 1, isPlaying: true)
        #expect(a.expectedPosition(atHostTime: 503.5) == 13.5)
        #expect(a.expectedPosition(atHostTime: 499) == 10)       // never before the anchor
        #expect(a.expectedPosition(atHostTime: 9999) == 100)     // never past the end
        a.rate = 2
        #expect(a.expectedPosition(atHostTime: 502) == 14)
        a.isPlaying = false
        #expect(a.expectedPosition(atHostTime: 900) == 10)
    }

    @Test func anchorFromTheNetworkIsClamped() throws {
        let wild = MusicRoomAnchor(id: 1, track: nil, position: 1e12, hostTime: 5, rate: 1000, isPlaying: true)
        let c = try #require(wild.sanitized())
        #expect(c.position == 86_400 && c.rate == 2)
        #expect(MusicRoomAnchor(id: -1, track: nil, position: 0, hostTime: 0, rate: 1, isPlaying: false).sanitized() == nil)
        #expect(MusicRoomAnchor(id: 1, track: nil, position: .nan, hostTime: 0, rate: 1, isPlaying: false).sanitized() == nil)
    }

    @Test func trackerSendsOnlyWhenSomethingChanged() throws {
        var t = MusicRoomAnchorTracker()
        let v6 = t.observe(track: track(), position: 0, isPlaying: true, hostNow: 100)
        let first = try #require(v6)
        #expect(first.isPlaying)
        // Normal progress is not news.
        let v7 = t.observe(track: track(), position: 0.5, isPlaying: true, hostNow: 100.5)
        #expect(v7 == nil)
        let v8 = t.observe(track: track(), position: 9.9, isPlaying: true, hostNow: 110)
        #expect(v8 == nil)
        // Pause, seek, track change and a forced heartbeat each send.
        let v9 = t.observe(track: track(), position: 10, isPlaying: false, hostNow: 110)
        #expect(v9?.isPlaying == false)
        let v10 = t.observe(track: track(), position: 60, isPlaying: false, hostNow: 111)
        #expect(v10 != nil)
        let v11 = t.observe(track: track("t2"), position: 0, isPlaying: false, hostNow: 112)
        #expect(v11 != nil)
        let v12 = t.observe(track: track("t2"), position: 0, isPlaying: false, hostNow: 113)
        #expect(v12 == nil)
        let v13 = t.observe(track: track("t2"), position: 0, isPlaying: false, hostNow: 120, force: true)
        let beat = try #require(v13)
        #expect(beat.id > first.id)
    }

    @Test func trackerTreatsNoTrackAsPaused() throws {
        var t = MusicRoomAnchorTracker()
        let v14 = t.observe(track: nil, position: 0, isPlaying: true, hostNow: 1)
        let a = try #require(v14)
        #expect(!a.isPlaying)
        let v15 = t.observe(track: nil, position: 0, isPlaying: true, hostNow: 2)
        #expect(v15 == nil)
    }

    // MARK: approval flow and kicks

    @Test func guestsWaitForApprovalAndSeatsAreLimited() {
        var r = MusicRoomRoster()
        let v16 = r.requestJoin(id: "g1", name: "One")
        #expect(v16 == .queued)
        #expect(r.members.isEmpty && r.pending.count == 1)      // not in until approved
        let v17 = r.approve(id: "g1")
        #expect(v17?.name == "One")
        #expect(r.members.count == 1 && r.pending.isEmpty)
        let v18 = r.requestJoin(id: "g1", name: "One")
        #expect(v18 == .alreadyMember)
        let v19 = r.approve(id: "nobody")
        #expect(v19 == nil)
        let v20 = r.requestJoin(id: "g2", name: "Two")
        #expect(v20 == .queued)
        let v21 = r.deny(id: "g2")
        #expect(v21 && r.pending.isEmpty)
        let v22 = r.deny(id: "g2")
        #expect(!v22)
    }

    @Test func theNinthGuestIsTurnedAway() {
        var r = MusicRoomRoster()
        for i in 0..<MusicRoomLimits.maxGuests {
            let v23 = r.requestJoin(id: "g\(i)", name: "G\(i)")
            #expect(v23 == .queued)
            let v24 = r.approve(id: "g\(i)")
            #expect(v24 != nil)
        }
        #expect(r.isFull)
        let v25 = r.requestJoin(id: "late", name: "Late")
        #expect(v25 == .full)
        r.remove(id: "g3")
        let v26 = r.requestJoin(id: "late", name: "Late")
        #expect(v26 == .queued)
        let v27 = r.approve(id: "late")
        #expect(v27 != nil)
    }

    @Test func suggestionsNeedAMemberAndAreLimited() {
        var r = MusicRoomRoster()
        let v28 = r.suggest(from: "stranger", suggestionID: "s0", track: track())
        #expect(v28 == nil)
        _ = r.requestJoin(id: "g1", name: "One"); _ = r.approve(id: "g1")
        for i in 0..<MusicRoomLimits.suggestionsPerGuest {
            let made = r.suggest(from: "g1", suggestionID: "s\(i)", track: track("t\(i)"))
            #expect(made != nil)
        }
        let v29 = r.suggest(from: "g1", suggestionID: "extra", track: track("x"))
        #expect(v29 == nil)
        let v30 = r.resolveSuggestion(id: "s0")
        #expect(v30?.guestName == "One")
        let v31 = r.resolveSuggestion(id: "s0")
        #expect(v31 == nil)            // answered once
        r.remove(id: "g1")
        #expect(r.suggestions.isEmpty)                            // a guest who leaves takes their suggestions along
    }

    @Test func hostOnlyMessagesFromAGuestEarnAKick() {
        #expect(MusicRoomMessage.anchor(MusicRoomAnchor(id: 1, track: nil, position: 0, hostTime: 0, rate: 1, isPlaying: false)).isHostOnly)
        #expect(MusicRoomMessage.kick.isHostOnly && MusicRoomMessage.closed.isHostOnly && MusicRoomMessage.approve(ref: nil).isHostOnly)
        #expect(!MusicRoomMessage.leave.isHostOnly && !MusicRoomMessage.ping(t0: 1).isHostOnly)
        var r = MusicRoomRoster()
        _ = r.requestJoin(id: "g1", name: "One"); _ = r.approve(id: "g1")
        for _ in 0..<(MusicRoomLimits.strikesToKick - 1) {
            let kicked = r.strike(id: "g1")
            #expect(!kicked)
        }
        let v32 = r.strike(id: "g1")
        #expect(v32)
    }

    @Test func rosterListsTheHostFirst() {
        var r = MusicRoomRoster()
        _ = r.requestJoin(id: "g1", name: "One"); _ = r.approve(id: "g1")
        let list = r.participants(hostID: "h", hostName: "Host")
        #expect(list.map(\.id) == ["h", "g1"] && list[0].isHost && !list[1].isHost)
    }

    @Test func messageRateIsTwentyPerSecond() {
        var l = MusicRemoteRateLimiter(limit: MusicRoomLimits.messagesPerSecond)
        var allowed = 0
        for i in 0..<30 {
            if l.allow(at: Double(i) * 0.01) { allowed += 1 }
        }
        #expect(allowed == 20)
    }

    @Test func rooms_shareTheDevicesServiceType() {
        #expect(MusicRoomLimits.serviceType == "_streamsetu-music._tcp")
    }
}
