import Testing
import Foundation
import Network
@testable import REDDY

private final class Mem: LanData, @unchecked Sendable {
    private let lock = NSLock(); var items: [String: LanRecord]
    init(_ r: [LanRecord]) { items = Dictionary(uniqueKeysWithValues: r.map { ($0.identity, $0) }) }
    func snapshot() async -> [LanRecord] { lock.withLock { Array(items.values) } }
    func apply(_ records: [LanRecord]) async -> Int {
        lock.withLock { var n = 0; for r in records where lanShouldApply(localTs: items[r.identity]?.ts, remoteTs: r.ts) { items[r.identity] = r; n += 1 }; return n }
    }
}

private func rec(_ id: String, _ ts: Int64) -> LanRecord { LanRecord(kind: "fav", key: ["srcA", "movie", id, "favorites"], ts: ts, deleted: false, value: ["at": .int(ts)]) }

@Suite struct LanTransportTests {
    /// A real TCP connection on this computer: framing, the hello, pairing and one exchange all work over it.
    @Test func twoDevicesPairAndSyncOverTCP() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let accepted = AsyncStream<NWConnection>.makeStream()
        listener.newConnectionHandler = { accepted.continuation.yield($0) }
        let ready = AsyncStream<UInt16>.makeStream()
        listener.stateUpdateHandler = { if case .ready = $0, let p = listener.port?.rawValue { ready.continuation.yield(p) } }
        listener.start(queue: .global())
        defer { listener.cancel() }
        var port: UInt16 = 0
        for await p in ready.stream { port = p; break }

        let idA = LanCrypto.Identity.make(), idB = LanCrypto.Identity.make()
        let dataA = Mem([rec("one", 10)]), dataB = Mem([rec("two", 20)])
        let a = LanProtocol(identity: idA, deviceName: "A", trust: LanTrustStore(defaults: UserDefaults(suiteName: "lan.t.a.\(UUID())")!), data: dataA, offerPairing: { false }, confirm: { _, _ in true })
        let b = LanProtocol(identity: idB, deviceName: "B", trust: LanTrustStore(defaults: UserDefaults(suiteName: "lan.t.b.\(UUID())")!), data: dataB, offerPairing: { true }, confirm: { _, _ in true })

        let responder = Task { () -> LanOutcome in
            for await c in accepted.stream {
                let link = NWLanLink(c)
                try await link.open(limit: 20)
                defer { link.close() }
                return await b.runResponder(link)
            }
            return .failed("none")
        }
        let link = NWLanLink(NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp))
        try await link.open(limit: 20)
        let out = await a.runInitiator(link)
        link.close()
        guard case .synced(_, let got, let paired) = out else { Issue.record("initiator: \(out)"); return }
        #expect(paired)
        #expect(got == 1)
        guard case .synced(_, let got2, _) = try await responder.value else { Issue.record("responder failed"); return }
        #expect(got2 == 1)
        #expect(await dataA.snapshot().count == 2)
        #expect(await dataB.snapshot().count == 2)
    }

    @Test func trustedDevicesAreRememberedAndForgotten() {
        let d = UserDefaults(suiteName: "lan.t.\(UUID())")!
        let store = LanTrustStore(defaults: d)
        let peer = LanPeer(id: "abc", name: "iPad", publicX963: Data([4, 1, 2]))
        store.add(peer)
        #expect(LanTrustStore(defaults: d).find(Data([4, 1, 2]))?.name == "iPad")
        store.remove(id: "abc")
        #expect(LanTrustStore(defaults: d).all().isEmpty)
    }
}
