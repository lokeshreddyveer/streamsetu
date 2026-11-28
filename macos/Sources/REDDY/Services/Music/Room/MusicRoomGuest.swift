import Foundation
import Network
import CryptoKit
import Observation

// This device as a guest: finding rooms on the local network, one encrypted connection to the host, and the clock measurement. It reports
// what the host says through callbacks; MusicRoomSession decides what to do with it.

// MARK: Finding rooms

/// Rooms nearby. Browsing starts only when the person asks and stops when they leave the page.
@MainActor @Observable
final class MusicRoomDiscovery {
    private(set) var rooms: [MusicPeer] = []
    private(set) var isBrowsing = false
    private(set) var note: String?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private let ownDeviceID: @MainActor () -> String

    init(ownDeviceID: @escaping @MainActor () -> String) { self.ownDeviceID = ownDeviceID }

    func start() {
        guard browser == nil else { return }
        note = nil
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: MusicRoomLimits.serviceType, domain: nil), using: MusicRemoteNetwork.tcpParameters())
        b.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .failed, .waiting: self.note = "Could not look for rooms. Check that Local Network access is allowed for this app in System Settings."
                case .ready: self.note = nil
                default: break
                }
            }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let mapped = results.compactMap { Self.room(from: $0) }
            MainActor.assumeIsolated { self?.apply(mapped) }
        }
        browser = b
        isBrowsing = true
        b.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
        rooms = []
    }

    /// Only services that carry the room flag; a plain Devices listener is not a room.
    nonisolated static func room(from r: NWBrowser.Result) -> MusicPeer? {
        guard case .service(let name, _, _, _) = r.endpoint, case .bonjour(let txt) = r.metadata, txt[MusicRoomLimits.txtFlagKey] == "1" else { return nil }
        var id = name
        if let v = txt["id"], !v.isEmpty, v.count <= MusicRoomLimits.maxName { id = v }
        return MusicPeer(id: id, name: MusicRoomSanitizer.text(name, max: MusicRoomLimits.maxName), endpoint: r.endpoint)
    }

    private func apply(_ found: [MusicPeer]) {
        let me = ownDeviceID()
        rooms = found.filter { $0.id != me }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: The connection

@MainActor
final class MusicRoomGuest {
    enum Phase: Equatable { case idle, connecting, handshaking, awaitingApproval, member, closed }

    private(set) var phase = Phase.idle
    private(set) var clock = MusicRoomClockEstimator()
    private(set) var lastHeardAt: Double = 0

    var onApprovalPending: (@MainActor () -> Void)?
    var onWelcome: (@MainActor (_ roomName: String, _ roster: [MusicRoomParticipant], _ queue: [MusicRoomTrack]) -> Void)?
    var onRoster: (@MainActor ([MusicRoomParticipant]) -> Void)?
    var onAnchor: (@MainActor (MusicRoomAnchor) -> Void)?
    var onQueue: (@MainActor ([MusicRoomTrack]) -> Void)?
    var onSuggestionAnswer: (@MainActor (_ ref: String, _ approved: Bool) -> Void)?
    var onClockUpdated: (@MainActor () -> Void)?
    /// Called once, when the connection ends for any reason. `nil` means the line simply dropped.
    var onClosed: (@MainActor (MusicRoomError?) -> Void)?

    private let deviceID: String
    private let name: String
    private let uptime: @MainActor () -> Double
    private var transport: MusicRemoteTransport?
    private var sealer: MusicRemoteSealer?
    private var opener: MusicRemoteSealer?
    private var key: Curve25519.KeyAgreement.PrivateKey?
    private var nonce = Data()
    private var code = ""
    private var timeout: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var pingStart: Double?
    private var measuring = false
    private var pingsSent = 0
    private var finalReason: MusicRoomError?

    init(deviceID: String, name: String, uptime: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.deviceID = deviceID; self.name = name; self.uptime = uptime
    }

    // MARK: connecting

    func connect(to endpoint: NWEndpoint, code: String) {
        guard phase == .idle || phase == .closed else { return }
        guard let normalized = MusicRoomHandshake.normalizedCode(code) else { finish(.authenticationFailed); return }
        self.code = normalized
        key = MusicRemoteHandshake.newKeyPair()
        nonce = MusicRemoteHandshake.randomNonce()
        finalReason = nil
        phase = .connecting
        let t = MusicRemoteTransport(connection: NWConnection(to: endpoint, using: MusicRemoteNetwork.tcpParameters()))
        transport = t
        t.onReady = { [weak self] in self?.sendHello() }
        t.onFrame = { [weak self] frame in self?.handle(frame) }
        t.onClosed = { [weak self] reason in
            guard let self else { return }
            self.finish(self.finalReason ?? Self.map(reason))
        }
        arm(seconds: 10)
        t.start()
    }

    /// Says goodbye and hangs up.
    func leave() {
        send(.leave)
        finalReason = nil
        close()
    }

    func close() {
        guard phase != .closed else { return }
        transport?.close(nil)
        if phase != .closed { finish(finalReason) }
    }

    func suggest(_ track: MusicRoomTrack) {
        guard phase == .member else { return }
        send(.suggest(id: UUID().uuidString, track))
    }

    private static func map(_ r: MusicRemoteError?) -> MusicRoomError? {
        switch r {
        case .privateNetworkOnly: .privateNetworkOnly
        case .timedOut: .timedOut
        case .authenticationFailed: .authenticationFailed
        case .none: nil
        default: .malformed("connection")
        }
    }

    private func finish(_ reason: MusicRoomError?) {
        guard phase != .closed else { return }
        let wasMember = phase == .member
        let before = phase
        phase = .closed
        timeout?.cancel(); watchdog?.cancel()
        sealer = nil; opener = nil
        transport = nil
        // Before the host let us in, a hang-up means the code was wrong or the host said no; once in, it means the line dropped.
        let r: MusicRoomError? = reason ?? (wasMember ? nil : (before == .awaitingApproval ? .denied : .authenticationFailed))
        onClosed?(r)
    }

    private func arm(seconds: Double) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.phase != .member, self.phase != .closed else { return }
            self.finalReason = .timedOut
            self.transport?.close(.timedOut)
        }
    }

    // MARK: handshake

    private func sendHello() {
        guard phase == .connecting, let key else { return }
        phase = .handshaking
        let hello = MusicRoomHello(deviceID: deviceID, name: name, publicKey: key.publicKey.rawRepresentation, nonce: nonce)
        if let data = try? JSONEncoder().encode(hello) { transport?.send(data) }
    }

    private func handle(_ frame: Data) {
        lastHeardAt = uptime()
        switch phase {
        case .handshaking: handleHostHello(frame)
        case .awaitingApproval, .member: handleSealed(frame)
        default: break
        }
    }

    private func handleHostHello(_ frame: Data) {
        guard let hello = try? MusicRoomHello.decode(frame) else { fail(.malformed("hello")); return }
        if hello.error != nil {
            // The host says why it refused; its words are shown as plain text by the session, so only the kind is kept.
            fail(Self.refusalKind(hello.error))
            return
        }
        guard let key, let keys = try? MusicRoomHandshake.derive(privateKey: key, peerPublic: hello.publicKey, code: code, guestNonce: nonce,
                                                                 hostNonce: hello.nonce, guestPublic: key.publicKey.rawRepresentation,
                                                                 hostPublic: hello.publicKey) else { fail(.authenticationFailed); return }
        sealer = MusicRemoteSealer(key: keys.guestToHost)
        opener = MusicRemoteSealer(key: keys.hostToGuest)
        phase = .awaitingApproval
        send(.join(id: deviceID, name: name))
        // Time for the host to look at the screen.
        arm(seconds: MusicRoomLimits.approvalSeconds + 15)
    }

    private static func refusalKind(_ text: String?) -> MusicRoomError {
        for e in [MusicRoomError.locked, .codeClosed, .roomFull] where e.message == text { return e }
        return .authenticationFailed
    }

    private func fail(_ e: MusicRoomError) {
        finalReason = e
        transport?.close(nil)
        finish(e)
    }

    private func handleSealed(_ frame: Data) {
        let m: MusicRoomMessage
        do {
            guard let plain = try opener?.open(frame) else { throw MusicRoomError.authenticationFailed }
            m = try MusicRoomMessage.decode(plain)
        } catch { fail((error as? MusicRoomError) ?? .authenticationFailed); return }
        switch m.kind {
        case .pending:
            onApprovalPending?()
        case .welcome:
            guard phase == .awaitingApproval else { return }
            phase = .member
            timeout?.cancel()
            startWatchdog()
            onWelcome?(m.name ?? "Room", m.roster ?? [], m.tracks ?? [])
            measureClock()
        case .deny:
            if let ref = m.ref { onSuggestionAnswer?(ref, false) } else { fail(.denied) }
        case .approve:
            if let ref = m.ref { onSuggestionAnswer?(ref, true) }
        case .roster: if phase == .member, let r = m.roster { onRoster?(r) }
        case .anchor: if phase == .member, let a = m.anchor { onAnchor?(a) }
        case .queue: if phase == .member, let t = m.tracks { onQueue?(t) }
        case .pong: if phase == .member { handlePong(m) }
        case .closed: fail(.roomClosed)
        case .kick: fail(.kicked)
        case .error: fail(m.text == MusicRoomError.roomFull.message ? .roomFull : .malformed("host error"))
        case .join, .suggest, .leave, .ping: break
        }
    }

    private func send(_ m: MusicRoomMessage) {
        guard let data = try? m.encoded(), let sealed = try? sealer?.seal(data) else { return }
        transport?.send(sealed)
    }

    /// One timer, re-armed only when it fires: the host sends an anchor at least every ten seconds, so a long silence means it is gone.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(MusicRoomLimits.silenceLimit * 1_000_000_000))
                guard let self, !Task.isCancelled, self.phase == .member else { return }
                if self.uptime() - self.lastHeardAt >= MusicRoomLimits.silenceLimit { self.transport?.close(nil); return }
            }
        }
    }

    // MARK: clock

    /// Five pings, one after the other; the best round trip wins. Does nothing if a measurement is already running.
    func measureClock() {
        guard phase == .member, !measuring else { return }
        measuring = true
        pingsSent = 0
        clock.beginMeasurement()
        sendPing()
    }

    private func sendPing() {
        let t0 = uptime()
        pingStart = t0
        pingsSent += 1
        send(.ping(t0: t0))
    }

    private func handlePong(_ m: MusicRoomMessage) {
        let t3 = uptime()
        guard measuring, let t0 = m.t0, let t1 = m.t1, let t2 = m.t2, let start = pingStart, abs(t0 - start) < 0.000_001 else { return }
        if let s = MusicRoomClockMath.sample(t0: t0, t1: t1, t2: t2, t3: t3) { clock.add(s) }
        if clock.pending.count < MusicRoomClockEstimator.roundsPerMeasurement && pingsSent < 2 * MusicRoomClockEstimator.roundsPerMeasurement {
            sendPing()
        } else {
            measuring = false
            if clock.finishMeasurement() { onClockUpdated?() }
        }
    }
}
