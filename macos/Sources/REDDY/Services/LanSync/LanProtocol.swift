import Foundation

/// A framed, ordered link between two devices (a TCP connection in the app, a pair of queues in the tests).
protocol LanLink: Sendable {
    func send(_ frame: Data) async throws
    func receive() async throws -> Data
}

struct LanPeer: Equatable, Codable, Sendable {
    let id: String
    let name: String
    let publicX963: Data
}

/// The devices this one has been paired with.
protocol LanTrust: Sendable {
    func find(_ publicX963: Data) -> LanPeer?
    func add(_ peer: LanPeer)
}

/// What is kept in step: everything this device has, and a place to put what the other device sent.
protocol LanData: Sendable {
    func snapshot() async -> [LanRecord]
    /// Applies records that arrived, keeping each one only when it is newer than what is here. Returns how many changed something.
    func apply(_ records: [LanRecord]) async -> Int
}

enum LanOutcome: Equatable, Sendable {
    case synced(peer: LanPeer, received: Int, paired: Bool)
    case refused(String)
    case failed(String)
}

/// The conversation between two devices, as in docs/WIFI-SYNC.md: hello, a session key, pairing when the other device is new, then one exchange of everything each side has.
/// `offerPairing` says whether this device is showing its "Add a device" screen; `confirm` shows the six digits to the person and waits for their answer.
final class LanProtocol: Sendable {
    private let identity: LanCrypto.Identity
    private let deviceName: String
    private let trust: LanTrust
    private let data: LanData
    private let offerPairing: @Sendable () -> Bool
    private let confirm: @Sendable (_ digits: String, _ peerName: String) async -> Bool
    private let chunk: Int

    init(identity: LanCrypto.Identity, deviceName: String, trust: LanTrust, data: LanData, offerPairing: @escaping @Sendable () -> Bool,
         confirm: @escaping @Sendable (String, String) async -> Bool, chunk: Int = 1500) {
        self.identity = identity; self.deviceName = deviceName; self.trust = trust; self.data = data
        self.offerPairing = offerPairing; self.confirm = confirm; self.chunk = chunk
    }

    func runInitiator(_ link: LanLink) async -> LanOutcome {
        do {
            let nonce = LanCrypto.randomBytes(16)
            try await link.send(hello(nonce))
            let reply = try decode(try await link.receive())
            guard let peerPub = reply.pub.flatMap({ Data(base64Encoded: $0) }), let peerName = reply.name, let peerNonce = reply.nonce.flatMap({ Data(base64Encoded: $0) }) else { throw LanError.badMessage }
            let z = try LanCrypto.sharedSecret(identity, peerX963: peerPub)
            let channel = LanCrypto.Channel(key: LanCrypto.sessionKey(z, nonceInitiator: nonce, nonceResponder: peerNonce), sending: 0)
            let known = trust.find(peerPub)
            try await link.send(channel.seal(encode(LanMessage(t: "start", mode: known == nil ? "pair" : "sync"))))
            let peer = known ?? LanPeer(id: LanCrypto.deviceId(peerPub), name: peerName, publicX963: peerPub)
            var paired = false
            let first = try decode(channel.open(try await link.receive()))
            switch first.t {
            case "reject": return .refused(first.why ?? "refused")
            case "pair":
                let digits = LanCrypto.comparisonDigits(z, publicInitiator: identity.publicX963, publicResponder: peerPub)
                let ok = await confirm(digits, peerName)
                try await link.send(channel.seal(encode(LanMessage(t: "pair", ok: ok))))
                let theirs = try decode(channel.open(try await link.receive()))
                guard ok, theirs.ok == true else { return .refused("not confirmed") }
                trust.add(peer); paired = true
            case "ready": break
            default: return .failed("unexpected answer")
            }
            try await send(await data.snapshot(), over: link, channel)
            var received = 0
            while true {
                let m = try decode(channel.open(try await link.receive()))
                guard m.t == "state" else { return .failed("unexpected answer") }
                received += await data.apply(m.records ?? [])
                if m.more != true { break }
            }
            try await link.send(channel.seal(encode(LanMessage(t: "bye"))))
            return .synced(peer: peer, received: received, paired: paired)
        } catch { return .failed("\(error)") }
    }

    func runResponder(_ link: LanLink) async -> LanOutcome {
        do {
            let first = try decode(try await link.receive())
            guard let peerPub = first.pub.flatMap({ Data(base64Encoded: $0) }), let peerName = first.name, let peerNonce = first.nonce.flatMap({ Data(base64Encoded: $0) }) else { throw LanError.badMessage }
            let nonce = LanCrypto.randomBytes(16)
            try await link.send(hello(nonce))
            let z = try LanCrypto.sharedSecret(identity, peerX963: peerPub)
            let channel = LanCrypto.Channel(key: LanCrypto.sessionKey(z, nonceInitiator: peerNonce, nonceResponder: nonce), sending: 1)
            let start = try decode(channel.open(try await link.receive()))
            let known = trust.find(peerPub)
            let peer = known ?? LanPeer(id: LanCrypto.deviceId(peerPub), name: peerName, publicX963: peerPub)
            var paired = false
            if start.mode == "pair" || known == nil {
                guard offerPairing() else {
                    try await link.send(channel.seal(encode(LanMessage(t: "reject", why: "not-paired"))))
                    return .refused("not paired")
                }
                try await link.send(channel.seal(encode(LanMessage(t: "pair"))))
                let digits = LanCrypto.comparisonDigits(z, publicInitiator: peerPub, publicResponder: identity.publicX963)
                let ok = await confirm(digits, peerName)
                let theirs = try decode(channel.open(try await link.receive()))
                try await link.send(channel.seal(encode(LanMessage(t: "pair", ok: ok))))
                guard ok, theirs.ok == true else { return .refused("not confirmed") }
                trust.add(peer); paired = true
            } else {
                try await link.send(channel.seal(encode(LanMessage(t: "ready"))))
            }
            var received = 0
            while true {
                let m = try decode(channel.open(try await link.receive()))
                guard m.t == "state" else { return .failed("unexpected message") }
                received += await data.apply(m.records ?? [])
                if m.more != true { break }
            }
            try await send(await data.snapshot(), over: link, channel)
            let bye = try decode(channel.open(try await link.receive()))
            guard bye.t == "bye" else { return .failed("unexpected message") }
            return .synced(peer: peer, received: received, paired: paired)
        } catch { return .failed("\(error)") }
    }

    private func hello(_ nonce: Data) throws -> Data {
        try encode(LanMessage(t: "hello", v: 1, pub: identity.publicX963.base64EncodedString(), name: deviceName, nonce: nonce.base64EncodedString()))
    }

    private func send(_ records: [LanRecord], over link: LanLink, _ channel: LanCrypto.Channel) async throws {
        if records.isEmpty { try await link.send(channel.seal(encode(LanMessage(t: "state", records: [], more: false)))); return }
        var start = 0
        while start < records.count {
            let end = min(start + chunk, records.count)
            try await link.send(channel.seal(encode(LanMessage(t: "state", records: Array(records[start..<end]), more: end < records.count))))
            start = end
        }
    }

    private func encode(_ m: LanMessage) throws -> Data { try JSONEncoder().encode(m) }
    private func decode(_ d: Data) throws -> LanMessage { try JSONDecoder().decode(LanMessage.self, from: d) }
}
