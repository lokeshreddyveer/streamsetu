import Testing
import Foundation
import CryptoKit
@testable import REDDY

@Suite("Music remote protocol") struct RemoteProtocolTests {
    // MARK: framing

    @Test func framesRoundTripAndSplitAcrossReads() throws {
        let a = try MusicRemoteFraming.encode(Data("one".utf8))
        let b = try MusicRemoteFraming.encode(Data("two".utf8))
        var buf = MusicRemoteFrameBuffer()
        let all = a + b
        var out: [Data] = []
        for byte in all { out += try buf.append(Data([byte])) }
        #expect(out.map { String(decoding: $0, as: UTF8.self) } == ["one", "two"])
        #expect(buf.pendingBytes == 0)
    }

    @Test func oversizedAndEmptyFramesAreRejectedBeforeBuffering() throws {
        var buf = MusicRemoteFrameBuffer()
        var header = Data()
        withUnsafeBytes(of: UInt32(MusicRemoteLimits.maxFrame + 1).bigEndian) { header.append(contentsOf: $0) }
        #expect(throws: MusicRemoteError.frameTooLarge) { try buf.append(header) }
        var zero = MusicRemoteFrameBuffer()
        #expect(throws: MusicRemoteError.emptyFrame) { try zero.append(Data([0, 0, 0, 0])) }
        #expect(throws: MusicRemoteError.frameTooLarge) { try MusicRemoteFraming.encode(Data(count: MusicRemoteLimits.maxFrame + 1)) }
    }

    // MARK: messages

    @Test func malformedMessagesThrowInsteadOfCrashing() {
        for bad in ["", "{", "[]", "{\"v\":1}", "{\"v\":1,\"kind\":\"nope\"}", "{\"v\":2,\"kind\":\"auth\"}", "{\"v\":1,\"kind\":\"command\"}", "{\"v\":1,\"kind\":\"state\"}"] {
            #expect(throws: MusicRemoteError.self) { try MusicRemoteMessage.decode(Data(bad.utf8)) }
        }
        #expect(throws: MusicRemoteError.self) { try MusicRemoteMessage.decode(Data(repeating: 65, count: MusicRemoteLimits.maxFrame + 1)) }
    }

    @Test func commandsAreClamped() throws {
        let vol = try MusicRemoteCommand.volume(7).validated()
        #expect(vol.volume == 1)
        #expect(throws: MusicRemoteError.self) { try MusicRemoteCommand.volume(.nan).validated() }
        #expect(throws: MusicRemoteError.self) { try MusicRemoteCommand.seek(-1).validated() }
        #expect(throws: MusicRemoteError.self) { try MusicRemoteCommand.seek(.infinity).validated() }
        #expect(throws: MusicRemoteError.self) { try MusicRemoteCommand(kind: .seek).validated() }
        #expect(throws: MusicRemoteError.self) { try MusicRemoteCommand.playTrack([]).validated() }
        let many = (0...MusicRemoteLimits.maxQueueTracks).map { MusicRemoteTrack(providerID: "p", id: "\($0)", title: "t", artist: "a") }
        #expect(throws: MusicRemoteError.self) { try MusicRemoteCommand.playTrack(many).validated() }
        let ok = try MusicRemoteCommand.playTrack([MusicRemoteTrack(providerID: "p", id: "1", title: "t", artist: "a")], startAt: 9).validated()
        #expect(ok.startAt == 0)
    }

    @Test func stateAndArtworkCarryNoPathsOrTokens() throws {
        #expect(MusicRemoteSanitizer.artworkURL("file:///Users/me/cover.jpg") == nil)
        #expect(MusicRemoteSanitizer.artworkURL("https://u:p@host.example/a.jpg") == nil)
        #expect(MusicRemoteSanitizer.artworkURL("https://host.example/a.jpg?access_token=abc") == nil)
        #expect(MusicRemoteSanitizer.artworkURL("https://host.example/a.jpg?w=300") == "https://host.example/a.jpg?w=300")
        let s = MusicRemoteState(hasTrack: true, title: "T\u{0007}x", artist: "A", artworkURL: "/private/path.jpg", position: .nan, duration: -4,
                                 isPlaying: true, volume: 9, queueCount: 3, queueIndex: 1, upNext: Array(repeating: "n", count: 20)).sanitized()
        #expect(s.title == "Tx"); #expect(s.artworkURL == nil); #expect(s.position == 0); #expect(s.duration == 0)
        #expect(s.volume == 1); #expect(s.upNext.count == MusicRemoteLimits.upNextCount)
        let m = try MusicRemoteMessage.decode(MusicRemoteMessage.state(s).encoded())
        #expect(m.state == s)
    }

    @Test func trackConversionNeverCarriesStreams() {
        let t = MusicTrack(id: "1", providerID: "audius", title: "Song", durationMs: 1000, artists: [MusicArtistRef(id: "a", name: "A")],
                           thumbnails: [MusicThumbnail(url: "https://x.example/c.jpg", width: 300)],
                           directStreams: [MusicStream(url: "https://x.example/s.mp3?token=1", codec: "mp3", container: "mp3")])
        let wire = MusicRemoteTrack(t)
        let json = String(decoding: (try? JSONEncoder().encode(wire)) ?? Data(), as: UTF8.self)
        #expect(!json.contains("token"))
        #expect(wire.asTrack().directStreams == nil)
        #expect(wire.asTrack().uid == "audius:1")
    }

    // MARK: crypto

    private func pair(code controller: String, host: String) throws -> (MusicRemoteHandshake.Keys, MusicRemoteHandshake.Keys) {
        let c = MusicRemoteHandshake.newKeyPair(), h = MusicRemoteHandshake.newKeyPair()
        let cn = MusicRemoteHandshake.randomNonce(), hn = MusicRemoteHandshake.randomNonce()
        let cp = c.publicKey.rawRepresentation, hp = h.publicKey.rawRepresentation
        let ck = try MusicRemoteHandshake.derive(privateKey: c, peerPublic: hp, mode: .pair, secret: Data(controller.utf8), controllerNonce: cn, hostNonce: hn, controllerPublic: cp, hostPublic: hp)
        let hk = try MusicRemoteHandshake.derive(privateKey: h, peerPublic: cp, mode: .pair, secret: Data(host.utf8), controllerNonce: cn, hostNonce: hn, controllerPublic: cp, hostPublic: hp)
        return (ck, hk)
    }

    @Test func rightCodeGivesMatchingKeysAndFramesOpen() throws {
        let (ck, hk) = try pair(code: "123456", host: "123456")
        var send = MusicRemoteSealer(key: ck.controllerToHost), recv = MusicRemoteSealer(key: hk.controllerToHost)
        let sealed = try send.seal(Data("hello".utf8))
        #expect(try recv.open(sealed) == Data("hello".utf8))
        #expect(ck.pairKey.withUnsafeBytes { Data($0) } == hk.pairKey.withUnsafeBytes { Data($0) })
    }

    @Test func wrongCodeCannotOpenAnything() throws {
        let (ck, hk) = try pair(code: "123456", host: "654321")
        var send = MusicRemoteSealer(key: ck.controllerToHost), recv = MusicRemoteSealer(key: hk.controllerToHost)
        #expect(throws: MusicRemoteError.authenticationFailed) { try recv.open(try send.seal(Data("hello".utf8))) }
    }

    @Test func replayedReorderedAndTamperedFramesFail() throws {
        let key = SymmetricKey(size: .bits256)
        var a = MusicRemoteSealer(key: key), b = MusicRemoteSealer(key: key)
        let f1 = try a.seal(Data("1".utf8)), f2 = try a.seal(Data("2".utf8))
        #expect(throws: MusicRemoteError.authenticationFailed) { try b.open(f2) }
        _ = try b.open(f1)
        #expect(throws: MusicRemoteError.authenticationFailed) { try b.open(f1) }
        var bad = f2; bad[bad.startIndex] ^= 1
        #expect(throws: MusicRemoteError.authenticationFailed) { try b.open(bad) }
        #expect(try b.open(f2) == Data("2".utf8))
        #expect(throws: MusicRemoteError.authenticationFailed) { try b.open(Data([1, 2, 3])) }
    }

    @Test func badPeerKeyIsRejected() {
        #expect(throws: MusicRemoteError.authenticationFailed) {
            try MusicRemoteHandshake.derive(privateKey: MusicRemoteHandshake.newKeyPair(), peerPublic: Data(count: 5), mode: .session, secret: Data(),
                                            controllerNonce: Data(), hostNonce: Data(), controllerPublic: Data(), hostPublic: Data())
        }
    }

    // MARK: pairing code

    @Test func codeExpiresAfterTwoMinutesAndWorksOnce() {
        var g = MusicPairingGuard()
        let t0 = Date(timeIntervalSince1970: 1000)
        #expect(g.issue(now: t0, code: "111111") == "111111")
        #expect(g.activeCode(now: t0.addingTimeInterval(119)) == "111111")
        #expect(g.activeCode(now: t0.addingTimeInterval(120)) == nil)
        g.issue(now: t0, code: "222222")
        g.recordSuccess()
        #expect(g.activeCode(now: t0) == nil)
    }

    @Test func fiveWrongTriesLockForTenMinutes() {
        var g = MusicPairingGuard()
        let t0 = Date(timeIntervalSince1970: 5000)
        g.issue(now: t0, code: "111111")
        for _ in 0..<4 { g.recordFailure(now: t0) }
        #expect(!g.isLocked(now: t0)); #expect(g.activeCode(now: t0) == "111111")
        g.recordFailure(now: t0)
        #expect(g.isLocked(now: t0)); #expect(g.activeCode(now: t0) == nil)
        #expect(g.issue(now: t0.addingTimeInterval(599), code: "333333") == nil)
        #expect(g.issue(now: t0.addingTimeInterval(600), code: "333333") == "333333")
        #expect(!g.isLocked(now: t0.addingTimeInterval(600)))
    }

    @Test func randomCodesAreSixDigits() {
        for _ in 0..<50 { let c = MusicPairingGuard.randomCode(); #expect(c.count == 6 && c.allSatisfy(\.isNumber)) }
    }

    // MARK: rate limit and addresses

    @Test func rateLimiterAllowsTwentyPerSecond() {
        var r = MusicRemoteRateLimiter()
        var first: [Bool] = []
        for _ in 0..<20 { first.append(r.allow(at: 10)) }
        let extra = r.allow(at: 10.5)
        let later = r.allow(at: 11.01)
        #expect(first.allSatisfy { $0 })
        #expect(!extra)
        #expect(later)
    }

    @Test func onlyPrivateAddressesPass() {
        #expect(MusicRemoteAddress.isPrivate([192, 168, 1, 5]))
        #expect(MusicRemoteAddress.isPrivate([10, 0, 0, 1]))
        #expect(MusicRemoteAddress.isPrivate([172, 16, 0, 1])); #expect(MusicRemoteAddress.isPrivate([172, 31, 255, 1]))
        #expect(!MusicRemoteAddress.isPrivate([172, 32, 0, 1])); #expect(!MusicRemoteAddress.isPrivate([8, 8, 8, 8]))
        #expect(MusicRemoteAddress.isPrivate([169, 254, 1, 1]))
        var ll = [UInt8](repeating: 0, count: 16); ll[0] = 0xfe; ll[1] = 0x80
        #expect(MusicRemoteAddress.isPrivate(ll))
        var ula = [UInt8](repeating: 0, count: 16); ula[0] = 0xfd
        #expect(MusicRemoteAddress.isPrivate(ula))
        var global = [UInt8](repeating: 0, count: 16); global[0] = 0x20; global[1] = 0x01
        #expect(!MusicRemoteAddress.isPrivate(global))
        var mapped = [UInt8](repeating: 0, count: 16); mapped[10] = 0xff; mapped[11] = 0xff; mapped[12] = 8; mapped[13] = 8; mapped[14] = 8; mapped[15] = 8
        #expect(!MusicRemoteAddress.isPrivate(mapped))
        #expect(!MusicRemoteAddress.isPrivate([]))
    }

    // MARK: paired devices

    @Test @MainActor func pairedDevicesPersistAndRevoke() {
        let store = MusicRemoteMemoryStore()
        let list = MusicPairedDevices(store: store)
        var revoked: [String] = []
        list.onRevoked = { revoked.append($0.deviceID) }
        let id = list.ownDeviceID
        #expect(!id.isEmpty); #expect(list.ownDeviceID == id)
        list.add(deviceID: "phone", name: "Phone", role: .controller, key: Data(repeating: 7, count: 32))
        list.add(deviceID: "mac", name: "Mac", role: .host, key: Data(repeating: 8, count: 32))
        #expect(MusicPairedDevices(store: store).devices.count == 2)
        #expect(list.record("phone", role: .controller) != nil); #expect(list.record("phone", role: .host) == nil)
        list.revoke(list.controllers[0])
        #expect(revoked == ["phone"]); #expect(list.controllers.isEmpty)
        #expect(MusicPairedDevices(store: store).devices.count == 1)
    }
}
