import Foundation
import Network

/// Runs a block once, however many times it is asked (connection state handlers fire more than once).
final class LanOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

/// A TCP connection that sends and receives whole frames: 4 bytes (big endian) with the length, then the body, at most 8 MiB, as in docs/WIFI-SYNC.md.
final class NWLanLink: LanLink, @unchecked Sendable {
    static let maxFrame = 8 << 20
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "app.streamsetu.lan.link")

    init(_ connection: NWConnection) { self.connection = connection }

    /// Waits until the connection is up. `limit` ends the whole conversation after that many seconds, so a device that goes quiet never leaves it hanging.
    func open(limit: TimeInterval = 300) async throws {
        let once = LanOnce()
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.take() { k.resume() }
                case .failed(let e): if once.take() { k.resume(throwing: e) }
                case .cancelled: if once.take() { k.resume(throwing: LanError.badFrame) }
                default: break
                }
            }
            connection.start(queue: queue)
        }
        let c = connection
        queue.asyncAfter(deadline: .now() + limit) { c.cancel() }
    }

    func close() { connection.cancel() }

    func send(_ frame: Data) async throws {
        guard frame.count <= Self.maxFrame else { throw LanError.badFrame }
        var head = Data(count: 4)
        let n = UInt32(frame.count)
        head[0] = UInt8(n >> 24 & 0xff); head[1] = UInt8(n >> 16 & 0xff); head[2] = UInt8(n >> 8 & 0xff); head[3] = UInt8(n & 0xff)
        try await write(head + frame)
    }

    func receive() async throws -> Data {
        let head = [UInt8](try await read(4))
        let n = Int(head[0]) << 24 | Int(head[1]) << 16 | Int(head[2]) << 8 | Int(head[3])
        guard n <= Self.maxFrame else { throw LanError.badFrame }
        return n == 0 ? Data() : try await read(n)
    }

    private func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { k.resume(throwing: error) } else { k.resume() }
            })
        }
    }

    private func read(_ n: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, _, error in
                if let error { k.resume(throwing: error) }
                else if let data, data.count == n { k.resume(returning: data) }
                else { k.resume(throwing: LanError.badFrame) }
            }
        }
    }
}

/// Devices found on the network while sync is on.
struct LanFound: Identifiable, Equatable, @unchecked Sendable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
}

/// Announces this device as `_streamsetu-sync._tcp` and accepts connections, and looks for the others. No data moves here; see `LanSyncService`.
final class LanDiscovery: @unchecked Sendable {
    static let serviceType = "_streamsetu-sync._tcp"
    private let deviceId: String
    private let deviceName: String
    private var listener: NWListener?
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "app.streamsetu.lan.discovery")
    var onConnection: (@Sendable (NWConnection) -> Void)?
    var onFound: (@Sendable ([LanFound]) -> Void)?

    init(deviceId: String, deviceName: String) { self.deviceId = deviceId; self.deviceName = deviceName }

    func start() {
        stop()
        if let l = try? NWListener(using: .tcp) {
            var txt = NWTXTRecord()
            txt["id"] = deviceId
            txt["name"] = deviceName
            l.service = NWListener.Service(name: deviceId, type: Self.serviceType, txtRecord: txt)
            l.newConnectionHandler = { [weak self] c in self?.onConnection?(c) }
            l.start(queue: queue)
            listener = l
        }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        let me = deviceId
        b.browseResultsChangedHandler = { [weak self] results, _ in
            var seen: [String: LanFound] = [:]
            for r in results {
                guard case .bonjour(let txt) = r.metadata, let id = txt["id"], id != me else { continue }
                seen[id] = LanFound(id: id, name: txt["name"] ?? "Device", endpoint: r.endpoint)
            }
            self?.onFound?(seen.values.sorted { $0.name < $1.name })
        }
        b.start(queue: queue)
        browser = b
    }

    func stop() {
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
    }

    func connect(_ found: LanFound) -> NWLanLink { NWLanLink(NWConnection(to: found.endpoint, using: .tcp)) }
}
