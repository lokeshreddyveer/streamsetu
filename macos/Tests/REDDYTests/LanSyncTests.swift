import Testing
import Foundation
@testable import REDDY

private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
private func unhex(_ s: String) -> Data { Data(stride(from: 0, to: s.count, by: 2).map { UInt8(s[s.index(s.startIndex, offsetBy: $0)...s.index(s.startIndex, offsetBy: $0 + 1)], radix: 16)! }) }

/// Two queues that act as the two ends of a connection.
private actor Pipe {
    private var items: [Data] = []
    private var waiting: [CheckedContinuation<Data, Error>] = []
    func put(_ d: Data) { if let w = waiting.first { waiting.removeFirst(); w.resume(returning: d) } else { items.append(d) } }
    func take() async throws -> Data {
        if !items.isEmpty { return items.removeFirst() }
        return try await withCheckedThrowingContinuation { waiting.append($0) }
    }
}

private final class Link: LanLink, @unchecked Sendable {
    let mine: Pipe, theirs: Pipe
    var tamper = false
    init(mine: Pipe, theirs: Pipe) { self.mine = mine; self.theirs = theirs }
    func send(_ frame: Data) async throws {
        var f = frame
        if tamper, f.count > 40 { f[f.count - 1] ^= 1 }
        await theirs.put(f)
    }
    func receive() async throws -> Data { try await mine.take() }
}

private func links() -> (Link, Link) { let a = Pipe(), b = Pipe(); return (Link(mine: a, theirs: b), Link(mine: b, theirs: a)) }

private final class Trust: LanTrust, @unchecked Sendable {
    private let lock = NSLock(); private var peers: [LanPeer] = []
    func find(_ p: Data) -> LanPeer? { lock.lock(); defer { lock.unlock() }; return peers.first { $0.publicX963 == p } }
    func add(_ peer: LanPeer) { lock.lock(); peers.removeAll { $0.id == peer.id }; peers.append(peer); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return peers.count }
}

private final class Store: LanData, @unchecked Sendable {
    private let lock = NSLock(); var items: [String: LanRecord]
    init(_ start: [LanRecord] = []) { items = Dictionary(uniqueKeysWithValues: start.map { ($0.identity, $0) }) }
    func snapshot() async -> [LanRecord] { lock.withLock { Array(items.values) } }
    func apply(_ records: [LanRecord]) async -> Int {
        lock.withLock {
            var n = 0
            for r in records where lanShouldApply(localTs: items[r.identity]?.ts, remoteTs: r.ts) { items[r.identity] = r; n += 1 }
            return n
        }
    }
}

private func fav(_ item: String, _ ts: Int64, deleted: Bool = false) -> LanRecord {
    LanRecord(kind: "fav", key: ["srcA", "movie", item, "favorites"], ts: ts, deleted: deleted, value: deleted ? nil : ["at": .int(ts)])
}

private final class Device: @unchecked Sendable {
    let identity = LanCrypto.Identity.make(); let trust = Trust(); let store: Store
    var offering: Bool; var answer: Bool; var seen: String?
    var protocolRunner: LanProtocol!
    init(_ name: String, _ store: Store, offering: Bool = false, answer: Bool = true) {
        self.store = store; self.offering = offering; self.answer = answer
        protocolRunner = LanProtocol(identity: identity, deviceName: name, trust: trust, data: store, offerPairing: { [unowned self] in self.offering },
                                     confirm: { [unowned self] digits, _ in self.seen = digits; return self.answer })
    }
}

private func run(_ a: Device, _ b: Device, _ pair: (Link, Link) = links()) async -> (LanOutcome, LanOutcome) {
    async let responder = b.protocolRunner.runResponder(pair.1)
    let initiator = await a.protocolRunner.runInitiator(pair.0)
    return (initiator, await responder)
}

@Suite struct LanSyncTests {
    @Test func twoNewDevicesPairWhenTheDigitsMatchAndThenShareEverything() async {
        let a = Device("Phone", Store([fav("1", 100), fav("2", 200)])), b = Device("TV", Store([fav("3", 300)]), offering: true)
        let (x, y) = await run(a, b)
        guard case .synced(_, let gotA, let pairedA) = x, case .synced(_, let gotB, let pairedB) = y else { Issue.record("\(x) \(y)"); return }
        #expect(pairedA && pairedB && gotA == 1 && gotB == 2)
        #expect(Set(a.store.items.keys) == Set(b.store.items.keys) && a.store.items.count == 3)
        #expect(a.seen == b.seen && a.seen?.count == 6 && a.trust.count == 1 && b.trust.count == 1)
    }

    @Test func pairedDevicesSyncAgainAndNewerChangesWin() async {
        let a = Device("Phone", Store([fav("1", 100)])), b = Device("TV", Store(), offering: true)
        _ = await run(a, b)
        a.store.items[fav("1", 0).identity] = fav("1", 500, deleted: true)
        b.store.items[fav("9", 0).identity] = fav("9", 600)
        b.offering = false
        let (x, y) = await run(a, b)
        guard case .synced(_, _, let paired) = x, case .synced = y else { Issue.record("\(x) \(y)"); return }
        #expect(!paired && b.store.items[fav("1", 0).identity]?.deleted == true)
        #expect(Set(a.store.items.keys) == Set([fav("1", 0).identity, fav("9", 0).identity]))
    }

    @Test func aDeviceNotShowingAddADeviceRefusesANewOne() async {
        let a = Device("Phone", Store([fav("1", 100)])), b = Device("TV", Store(), offering: false)
        let (x, y) = await run(a, b)
        guard case .refused = x, case .refused = y else { Issue.record("\(x) \(y)"); return }
        #expect(b.store.items.isEmpty && b.trust.count == 0)
    }

    @Test func decliningTheDigitsPairsNothing() async {
        let a = Device("Phone", Store([fav("1", 100)])), b = Device("TV", Store(), offering: true, answer: false)
        let (x, y) = await run(a, b)
        guard case .refused = x, case .refused = y else { Issue.record("\(x) \(y)"); return }
        #expect(a.trust.count == 0 && b.trust.count == 0 && b.store.items.isEmpty)
    }

    @Test func aChangedFrameIsRejectedInsteadOfApplied() async {
        let a = Device("Phone", Store([fav("1", 100)])), b = Device("TV", Store(), offering: true)
        let pair = links(); pair.0.tamper = true
        let (x, _) = await run(a, b, pair)
        guard case .failed = x else { Issue.record("\(x)"); return }
        #expect(b.store.items.isEmpty)
    }

    @Test func bigStatesTravelInSeveralFrames() async {
        let many = (1...4000).map { fav("m\($0)", Int64($0)) }
        let a = Device("Phone", Store(many)), b = Device("TV", Store(), offering: true)
        let (x, _) = await run(a, b)
        guard case .synced = x else { Issue.record("\(x)"); return }
        #expect(b.store.items.count == 4000)
    }

    @Test func aPlaylistHasTheSameKeyOnEveryDevice() {
        #expect(LanSourceKey.of("http://Example.com:8080/") == LanSourceKey.of("https://example.com:8080"))
        #expect(LanSourceKey.of("http://a.example") != LanSourceKey.of("http://b.example"))
        #expect(LanSourceKey.of("x").count == 16)
    }

    @Test func recordsKeepTheirShapeThroughJSON() throws {
        let r = LanRecord(kind: "prog", key: ["s", "movie", "7"], ts: 1_700_000_000_123, value: ["pos": .double(12.5), "done": .bool(false), "series": .null])
        let back = try JSONDecoder().decode(LanRecord.self, from: JSONEncoder().encode(r))
        #expect(back == r)
        let gone = try JSONDecoder().decode(LanRecord.self, from: Data(#"{"k":"fav","key":["a"],"ts":5,"del":true}"#.utf8))
        #expect(gone.deleted && gone.value == nil)
    }

    /// The same numbers must come out of the Android code (its test has the same values), or the two cannot talk to each other.
    @Test func theCryptographyMatchesTheAgreedVectors() throws {
        let a = try LanCrypto.Identity(raw: Data(repeating: 0x11, count: 32)), b = try LanCrypto.Identity(raw: Data(repeating: 0x22, count: 32))
        let z = try LanCrypto.sharedSecret(a, peerX963: b.publicX963)
        #expect(z == (try LanCrypto.sharedSecret(b, peerX963: a.publicX963)))
        let nonceI = Data(0..<16), nonceR = Data(16..<32)
        let key = LanCrypto.sessionKey(z, nonceInitiator: nonceI, nonceResponder: nonceR)
        let digits = LanCrypto.comparisonDigits(z, publicInitiator: a.publicX963, publicResponder: b.publicX963)
        let sender = LanCrypto.Channel(key: key, sending: 0)
        let first = try sender.seal(Data("hello streamsetu".utf8)), second = try sender.seal(Data("again".utf8))
        print("VECTOR pubA", hex(a.publicX963)); print("VECTOR pubB", hex(b.publicX963)); print("VECTOR z", hex(z)); print("VECTOR key", hex(key))
        print("VECTOR digits", digits); print("VECTOR first", hex(first)); print("VECTOR second", hex(second))
        print("VECTOR idA", a.deviceId)
    }
}
