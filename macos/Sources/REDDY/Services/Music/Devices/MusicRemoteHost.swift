import Foundation
import Network
import CryptoKit
import Observation

// This device as the one being controlled. Nothing listens or advertises until `start()` is called, and `start()` is called only when the
// person switches "Allow other devices to control this one" on. Every command needs a session that proved a paired key or the live code.

@MainActor
private final class HostSession {
    enum Phase { case hello, auth, active }
    let transport: MusicRemoteTransport
    var phase = Phase.hello
    var mode = MusicRemoteHandshake.Mode.session
    var peerID = ""
    var peerName = ""
    var codeUsed: String?
    var pairKey: Data?
    var sealer: MusicRemoteSealer?
    var opener: MusicRemoteSealer?
    var limiter = MusicRemoteRateLimiter()
    var violations = 0
    var lastSent: MusicRemoteState?
    var timeout: Task<Void, Never>?
    init(transport: MusicRemoteTransport) { self.transport = transport }
}

@MainActor @Observable
final class MusicRemoteHost {
    private(set) var isRunning = false
    private(set) var error: String?
    /// The code to show, only while it is valid.
    private(set) var pairingCode: String?
    private(set) var pairingExpiresAt: Date?
    private(set) var pairingLockedUntil: Date?
    /// Names of the controllers connected right now.
    private(set) var connectedNames: [String] = []

    @ObservationIgnored private let deviceID: @MainActor () -> String
    @ObservationIgnored private let deviceName: String
    @ObservationIgnored private let paired: MusicPairedDevices
    @ObservationIgnored private weak var player: (any MusicRemoteControllable)?
    @ObservationIgnored private let clock: @MainActor () -> Date
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var sessions: [ObjectIdentifier: HostSession] = [:]
    @ObservationIgnored private var pairing = MusicPairingGuard()
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var codeTimer: Task<Void, Never>?
    private static let maxSessions = 4
    private static let handshakeSeconds: UInt64 = 10

    init(deviceID: @escaping @MainActor () -> String, deviceName: String, paired: MusicPairedDevices,
         player: any MusicRemoteControllable, clock: @escaping @MainActor () -> Date = { Date() }) {
        self.deviceID = deviceID; self.deviceName = deviceName; self.paired = paired; self.player = player; self.clock = clock
    }

    // MARK: lifecycle

    func start() {
        guard listener == nil else { return }
        error = nil
        do {
            let l = try NWListener(using: MusicRemoteNetwork.tcpParameters())
            l.service = NWListener.Service(name: deviceName, type: MusicRemoteLimits.serviceType, domain: nil,
                                           txtRecord: NWTXTRecord(["id": deviceID(), "v": String(MusicRemoteLimits.version)]))
            l.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            l.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if case .failed = state {
                        self.error = "This device could not start listening. Check that Local Network access is allowed in System Settings."
                        self.stop()
                    }
                }
            }
            listener = l
            isRunning = true
            l.start(queue: .main)
        } catch {
            self.error = "This device could not start listening."
        }
    }

    /// Stops listening and advertising, hangs up on every controller and throws away any pairing code.
    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        closePairing()
        for s in sessions.values { s.transport.close(nil) }
        sessions.removeAll()
        publishConnected()
        ticker?.cancel(); ticker = nil
    }

    func disconnect(deviceID: String) {
        for s in sessions.values where s.peerID == deviceID { s.transport.close(nil) }
    }

    // MARK: pairing

    /// Shows a fresh code. Refused while pairing is locked.
    func openPairing() {
        guard isRunning else { return }
        pairing.issue(now: clock())
        publishPairing()
        codeTimer?.cancel()
        codeTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(MusicPairingGuard.codeLifetime * 1_000_000_000) + 200_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshPairing()
        }
    }

    func closePairing() {
        pairing.cancel()
        codeTimer?.cancel(); codeTimer = nil
        publishPairing()
    }

    func refreshPairing() {
        pairing.refresh(now: clock())
        publishPairing()
    }

    private func publishPairing() {
        let now = clock()
        pairingCode = pairing.activeCode(now: now)
        pairingExpiresAt = pairingCode == nil ? nil : pairing.expiresAt
        pairingLockedUntil = pairing.isLocked(now: now) ? pairing.lockedUntil : nil
    }

    private func publishConnected() {
        connectedNames = sessions.values.filter { $0.phase == .active }.map(\.peerName).sorted()
    }

    // MARK: connections

    private func accept(_ connection: NWConnection) {
        guard isRunning, sessions.count < Self.maxSessions else { connection.cancel(); return }
        let transport = MusicRemoteTransport(connection: connection)
        let session = HostSession(transport: transport)
        let key = ObjectIdentifier(session)
        sessions[key] = session
        transport.onFrame = { [weak self, weak session] frame in
            guard let self, let session else { return }
            self.handle(frame, in: session)
        }
        transport.onClosed = { [weak self, weak session] _ in
            guard let self, let session else { return }
            session.timeout?.cancel()
            self.sessions[ObjectIdentifier(session)] = nil
            self.publishConnected()
        }
        session.timeout = Task { [weak session] in
            try? await Task.sleep(nanoseconds: Self.handshakeSeconds * 1_000_000_000)
            if let session, session.phase != .active { session.transport.close(.timedOut) }
        }
        transport.start()
    }

    private func handle(_ frame: Data, in s: HostSession) {
        switch s.phase {
        case .hello: handleHello(frame, s)
        case .auth: handleAuth(frame, s)
        case .active: handleActive(frame, s)
        }
    }

    private func refuse(_ s: HostSession, _ e: MusicRemoteError) {
        if let data = try? JSONEncoder().encode(MusicRemoteHello.refusal(e, mode: s.mode)) { s.transport.send(data) }
        s.transport.close(e)
    }

    private func handleHello(_ frame: Data, _ s: HostSession) {
        guard let hello = try? MusicRemoteHello.decode(frame), hello.error == nil else { s.transport.close(.malformed("hello")); return }
        let now = clock()
        pairing.refresh(now: now); publishPairing()
        s.mode = hello.mode; s.peerID = hello.deviceID; s.peerName = hello.name
        let secret: Data
        switch hello.mode {
        case .session:
            guard let record = paired.record(hello.deviceID, role: .controller) else { refuse(s, .notPaired); return }
            secret = record.key
        case .pair:
            if pairing.isLocked(now: now) { refuse(s, .locked); return }
            guard let code = pairing.activeCode(now: now) else { refuse(s, .pairingClosed); return }
            s.codeUsed = code
            secret = Data(code.utf8)
        }
        let mine = MusicRemoteHandshake.newKeyPair()
        let nonce = MusicRemoteHandshake.randomNonce()
        let reply = MusicRemoteHello(mode: hello.mode, deviceID: deviceID(), name: deviceName,
                                     publicKey: mine.publicKey.rawRepresentation, nonce: nonce)
        guard let keys = try? MusicRemoteHandshake.derive(
            privateKey: mine, peerPublic: hello.publicKey, mode: hello.mode, secret: secret, controllerNonce: hello.nonce,
            hostNonce: nonce, controllerPublic: hello.publicKey, hostPublic: mine.publicKey.rawRepresentation),
              let data = try? JSONEncoder().encode(reply) else { s.transport.close(.authenticationFailed); return }
        s.sealer = MusicRemoteSealer(key: keys.hostToController)
        s.opener = MusicRemoteSealer(key: keys.controllerToHost)
        s.pairKey = keys.pairKey.withUnsafeBytes { Data($0) }
        s.phase = .auth
        s.transport.send(data)
    }

    private func handleAuth(_ frame: Data, _ s: HostSession) {
        let now = clock()
        do {
            guard let plain = try s.opener?.open(frame), try MusicRemoteMessage.decode(plain).kind == .auth else { throw MusicRemoteError.authenticationFailed }
            if s.mode == .pair {
                pairing.refresh(now: now)
                guard let used = s.codeUsed, pairing.activeCode(now: now) == used, let key = s.pairKey else { throw MusicRemoteError.authenticationFailed }
                paired.add(deviceID: s.peerID, name: s.peerName, role: .controller, key: key, now: now)
                pairing.recordSuccess()
                codeTimer?.cancel(); codeTimer = nil
                publishPairing()
            } else {
                guard paired.record(s.peerID, role: .controller) != nil else { throw MusicRemoteError.notPaired }
            }
        } catch {
            if s.mode == .pair { pairing.recordFailure(now: now); publishPairing() }
            s.transport.close(.authenticationFailed)
            return
        }
        s.pairKey = nil
        s.phase = .active
        s.timeout?.cancel()
        publishConnected()
        let state = player?.remoteSnapshot() ?? .idle
        s.lastSent = state
        send(.ready(state), to: s)
        startTicker()
    }

    private func handleActive(_ frame: Data, _ s: HostSession) {
        let message: MusicRemoteMessage
        do {
            guard let plain = try s.opener?.open(frame) else { throw MusicRemoteError.authenticationFailed }
            message = try MusicRemoteMessage.decode(plain)
        } catch { s.transport.close(.authenticationFailed); return }
        guard paired.record(s.peerID, role: .controller) != nil else { s.transport.close(.notPaired); return }
        switch message.kind {
        case .command:
            guard s.limiter.allow(at: ProcessInfo.processInfo.systemUptime) else {
                s.violations += 1
                if s.violations > 100 { s.transport.close(.rateLimited) }
                return
            }
            guard let command = message.command, let player else { return }
            player.apply(command)
            pushState(to: s, force: true)
        case .bye: s.transport.close(nil)
        default: break
        }
    }

    // MARK: state

    private func send(_ m: MusicRemoteMessage, to s: HostSession) {
        guard let data = try? m.encoded(), let sealed = try? s.sealer?.seal(data) else { s.transport.close(.malformed("send")); return }
        s.transport.send(sealed)
    }

    private func pushState(to s: HostSession, force: Bool) {
        guard s.phase == .active, let state = player?.remoteSnapshot() else { return }
        if !force && state == s.lastSent { return }
        s.lastSent = state
        send(.state(state), to: s)
    }

    /// One tick a second, and only while somebody is connected, so an idle host costs nothing.
    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                let active = self.sessions.values.filter { $0.phase == .active }
                if active.isEmpty { self.ticker = nil; return }
                for s in active { self.pushState(to: s, force: false) }
            }
        }
    }
}
