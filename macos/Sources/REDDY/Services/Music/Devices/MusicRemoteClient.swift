import Foundation
import Network
import CryptoKit
import Observation

// This device as the controller. It connects only when the person picks a device, and it can pair (with the code shown on the other
// device) or reconnect to a device it already paired with.

@MainActor @Observable
final class MusicRemoteClient {
    enum Status: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    private(set) var status = Status.idle
    private(set) var remote: MusicRemoteState?
    private(set) var remoteName = ""
    private(set) var remoteID = ""

    @ObservationIgnored private let deviceID: @MainActor () -> String
    @ObservationIgnored private let deviceName: String
    @ObservationIgnored private let paired: MusicPairedDevices
    @ObservationIgnored private var transport: MusicRemoteTransport?
    @ObservationIgnored private var sealer: MusicRemoteSealer?
    @ObservationIgnored private var opener: MusicRemoteSealer?
    @ObservationIgnored private var limiter = MusicRemoteRateLimiter()
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var pending: Pending?

    private struct Pending {
        var mode: MusicRemoteHandshake.Mode
        var secret: Data
        var key: Curve25519.KeyAgreement.PrivateKey
        var nonce: Data
        var expectedHostID: String?
        var phase = 0
        var pairKey: Data?
        var hostName = ""
        var hostID = ""
    }

    init(deviceID: @escaping @MainActor () -> String, deviceName: String, paired: MusicPairedDevices) {
        self.deviceID = deviceID; self.deviceName = deviceName; self.paired = paired
    }

    /// With a code, pairs with the device and keeps the key. Without one, the device must already be paired.
    func connect(to peer: MusicPeer, code: String?) {
        disconnect()
        let mode: MusicRemoteHandshake.Mode
        let secret: Data
        if let code {
            let trimmed = code.filter(\.isNumber)
            guard trimmed.count == 6 else { status = .failed("Enter the 6-digit code shown on the other device."); return }
            mode = .pair; secret = Data(trimmed.utf8)
        } else {
            guard let record = paired.record(peer.id, role: .host) else { status = .failed(MusicRemoteError.notPaired.message); return }
            mode = .session; secret = record.key
        }
        pending = Pending(mode: mode, secret: secret, key: MusicRemoteHandshake.newKeyPair(), nonce: MusicRemoteHandshake.randomNonce(),
                          expectedHostID: mode == .session ? peer.id : nil)
        remoteName = peer.name
        status = .connecting
        let t = MusicRemoteTransport(connection: NWConnection(to: peer.endpoint, using: MusicRemoteNetwork.tcpParameters()))
        transport = t
        t.onReady = { [weak self] in self?.sendHello() }
        t.onFrame = { [weak self] frame in self?.handle(frame) }
        t.onClosed = { [weak self] reason in self?.closed(reason) }
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, self.status == .connecting else { return }
            self.fail(.timedOut)
        }
        t.start()
    }

    func disconnect() {
        if status == .connected { sendSealed(.bye) }
        timeout?.cancel(); timeout = nil
        let t = transport
        transport = nil; sealer = nil; opener = nil; pending = nil
        t?.onClosed = nil
        t?.close(nil)
        remote = nil
        status = .idle
    }

    /// Sends one command. Anything above 20 a second is dropped here, so a dragged slider never gets the connection cut.
    func send(_ command: MusicRemoteCommand) {
        guard status == .connected, limiter.allow(at: ProcessInfo.processInfo.systemUptime) else { return }
        sendSealed(.command(command))
    }

    // MARK: handshake

    private func sendHello() {
        guard let p = pending else { return }
        let hello = MusicRemoteHello(mode: p.mode, deviceID: deviceID(), name: deviceName,
                                     publicKey: p.key.publicKey.rawRepresentation, nonce: p.nonce)
        guard let data = try? JSONEncoder().encode(hello) else { fail(.malformed("hello")); return }
        transport?.send(data)
    }

    private func handle(_ frame: Data) {
        guard var p = pending else { handleActive(frame); return }
        if p.phase == 0 {
            let hello: MusicRemoteHello
            do { hello = try MusicRemoteHello.decode(frame) } catch { fail(.malformed("hello")); return }
            if let text = hello.error { failText(text); return }
            if let expected = p.expectedHostID, hello.deviceID != expected { fail(.authenticationFailed); return }
            let mine = p.key.publicKey.rawRepresentation
            guard let keys = try? MusicRemoteHandshake.derive(
                privateKey: p.key, peerPublic: hello.publicKey, mode: p.mode, secret: p.secret, controllerNonce: p.nonce,
                hostNonce: hello.nonce, controllerPublic: mine, hostPublic: hello.publicKey) else { fail(.authenticationFailed); return }
            sealer = MusicRemoteSealer(key: keys.controllerToHost)
            opener = MusicRemoteSealer(key: keys.hostToController)
            p.pairKey = keys.pairKey.withUnsafeBytes { Data($0) }
            p.hostName = hello.name; p.hostID = hello.deviceID
            p.phase = 1
            pending = p
            remoteID = hello.deviceID
            sendSealed(.auth)
            return
        }
        // The host's "ready" opens only if it knew the same code or key, which is how the controller knows the host is genuine.
        do {
            guard let plain = try opener?.open(frame) else { throw MusicRemoteError.authenticationFailed }
            let m = try MusicRemoteMessage.decode(plain)
            guard m.kind == .ready, let state = m.state else { throw MusicRemoteError.authenticationFailed }
            if p.mode == .pair, let key = p.pairKey {
                paired.add(deviceID: p.hostID, name: p.hostName, role: .host, key: key)
            }
            remote = state
            remoteName = p.hostName.isEmpty ? remoteName : p.hostName
            pending = nil
            timeout?.cancel(); timeout = nil
            status = .connected
        } catch { fail(.authenticationFailed) }
    }

    private func handleActive(_ frame: Data) {
        do {
            guard let plain = try opener?.open(frame) else { throw MusicRemoteError.authenticationFailed }
            let m = try MusicRemoteMessage.decode(plain)
            switch m.kind {
            case .state, .ready: remote = m.state
            case .error: if let t = m.text { status = .failed(t) }
            case .bye: disconnect()
            default: break
            }
        } catch { fail(.authenticationFailed) }
    }

    private func sendSealed(_ m: MusicRemoteMessage) {
        guard let data = try? m.encoded(), let sealed = try? sealer?.seal(data) else { return }
        transport?.send(sealed)
    }

    private func fail(_ e: MusicRemoteError) { failText(e.message) }

    private func failText(_ text: String) {
        timeout?.cancel(); timeout = nil
        let t = transport
        transport = nil; sealer = nil; opener = nil; pending = nil
        t?.onClosed = nil
        t?.close(nil)
        remote = nil
        status = .failed(text)
    }

    private func closed(_ reason: MusicRemoteError?) {
        guard status == .connecting || status == .connected else { return }
        transport = nil; sealer = nil; opener = nil; pending = nil
        timeout?.cancel(); timeout = nil
        remote = nil
        status = reason.map { .failed($0.message) } ?? .failed(MusicRemoteError.closed.message)
    }
}
