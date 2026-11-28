import Foundation
import Network
import CryptoKit
import Observation

// This device as the host of a room. Nothing listens or advertises until `open` is called, and it all stops on `close`. The host's own
// player is the authority: guests follow the anchors it sends, and the host approves every join and every suggested song.

// MARK: Who is in the room (pure)

struct MusicRoomRoster: Sendable {
    struct Pending: Identifiable, Equatable, Sendable { var id: String; var name: String }
    struct Suggestion: Identifiable, Equatable, Sendable { var id: String; var guestID: String; var guestName: String; var track: MusicRoomTrack }
    enum JoinResult: Equatable, Sendable { case queued, full, alreadyMember }

    let capacity: Int
    private(set) var members: [MusicRoomParticipant] = []
    private(set) var pending: [Pending] = []
    private(set) var suggestions: [Suggestion] = []
    private var strikes: [String: Int] = [:]

    init(capacity: Int = MusicRoomLimits.maxGuests) { self.capacity = capacity }

    var isFull: Bool { members.count >= capacity }
    func isMember(_ id: String) -> Bool { members.contains { $0.id == id } }

    /// A guest knocked (the code was right). It waits for the host. A room that is full turns the guest away at once.
    mutating func requestJoin(id: String, name: String) -> JoinResult {
        if isMember(id) { return .alreadyMember }
        if isFull || (pending.count >= capacity && !pending.contains { $0.id == id }) { return .full }
        pending.removeAll { $0.id == id }
        pending.append(Pending(id: id, name: name))
        return .queued
    }

    /// The host said yes. Refused (nil) when the guest is not waiting or the last seat went meanwhile.
    mutating func approve(id: String) -> MusicRoomParticipant? {
        guard let p = pending.first(where: { $0.id == id }), !isFull else { return nil }
        pending.removeAll { $0.id == id }
        let m = MusicRoomParticipant(id: p.id, name: p.name, isHost: false)
        members.append(m)
        return m
    }

    @discardableResult
    mutating func deny(id: String) -> Bool {
        guard pending.contains(where: { $0.id == id }) else { return false }
        pending.removeAll { $0.id == id }
        return true
    }

    /// The guest left, was kicked or lost the connection: seat, queue place, suggestions and strikes all go.
    mutating func remove(id: String) {
        members.removeAll { $0.id == id }
        pending.removeAll { $0.id == id }
        suggestions.removeAll { $0.guestID == id }
        strikes[id] = nil
    }

    /// A member proposed a song. Non-members, and members with too many open proposals, are ignored.
    mutating func suggest(from id: String, suggestionID: String, track: MusicRoomTrack) -> Suggestion? {
        guard let who = members.first(where: { $0.id == id }), suggestions.count < MusicRoomLimits.maxPendingSuggestions,
              suggestions.filter({ $0.guestID == id }).count < MusicRoomLimits.suggestionsPerGuest,
              !suggestions.contains(where: { $0.id == suggestionID }) else { return nil }
        let s = Suggestion(id: suggestionID, guestID: id, guestName: who.name, track: track)
        suggestions.append(s)
        return s
    }

    mutating func resolveSuggestion(id: String) -> Suggestion? {
        guard let s = suggestions.first(where: { $0.id == id }) else { return nil }
        suggestions.removeAll { $0.id == id }
        return s
    }

    /// Counts a message a guest had no right to send. True when it was the one that earns a kick.
    mutating func strike(id: String) -> Bool {
        strikes[id, default: 0] += 1
        return strikes[id, default: 0] >= MusicRoomLimits.strikesToKick
    }

    func participants(hostID: String, hostName: String) -> [MusicRoomParticipant] {
        [MusicRoomParticipant(id: hostID, name: hostName, isHost: true)] + members
    }
}

@MainActor
private final class RoomHostSession {
    enum Phase { case hello, auth, pending, member }
    let transport: MusicRemoteTransport
    var phase = Phase.hello
    var guestID = ""
    var guestName = ""
    var code: String?
    var sealer: MusicRemoteSealer?
    var opener: MusicRemoteSealer?
    var limiter = MusicRemoteRateLimiter(limit: MusicRoomLimits.messagesPerSecond)
    var timeout: Task<Void, Never>?
    init(transport: MusicRemoteTransport) { self.transport = transport }
}

@MainActor @Observable
final class MusicRoomHost {
    private(set) var isOpen = false
    private(set) var error: String?
    private(set) var roomName = ""
    /// The code to show, only while it is valid.
    private(set) var code: String?
    private(set) var codeExpiresAt: Date?
    private(set) var lockedUntil: Date?
    /// The host first, then the approved guests.
    private(set) var participants: [MusicRoomParticipant] = []
    private(set) var pendingJoins: [MusicRoomRoster.Pending] = []
    private(set) var pendingSuggestions: [MusicRoomRoster.Suggestion] = []

    @ObservationIgnored private let deviceID: @MainActor () -> String
    @ObservationIgnored private let deviceName: String
    @ObservationIgnored private weak var source: (any MusicRoomPlayable)?
    @ObservationIgnored private let wallClock: @MainActor () -> Date
    @ObservationIgnored private let uptime: @MainActor () -> Double
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var sessions: [ObjectIdentifier: RoomHostSession] = [:]
    @ObservationIgnored private var roster = MusicRoomRoster()
    @ObservationIgnored private var codeGuard = MusicPairingGuard()
    @ObservationIgnored private var tracker = MusicRoomAnchorTracker()
    @ObservationIgnored private var lastQueueKeys: [String] = []
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var codeTimer: Task<Void, Never>?
    @ObservationIgnored private var observing = false

    init(deviceID: @escaping @MainActor () -> String, deviceName: String, source: any MusicRoomPlayable,
         wallClock: @escaping @MainActor () -> Date = { Date() }, uptime: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.deviceID = deviceID; self.deviceName = deviceName; self.source = source; self.wallClock = wallClock; self.uptime = uptime
    }

    // MARK: lifecycle

    /// Opens the room: listens, advertises and shows a first code. Everything stops again on `close`.
    func open() {
        guard listener == nil else { return }
        error = nil
        roomName = deviceName
        do {
            let l = try NWListener(using: MusicRemoteNetwork.tcpParameters())
            l.service = NWListener.Service(name: deviceName, type: MusicRoomLimits.serviceType, domain: nil,
                                           txtRecord: NWTXTRecord(["id": deviceID(), MusicRoomLimits.txtFlagKey: "1", "v": String(MusicRoomLimits.version)]))
            l.newConnectionHandler = { [weak self] connection in MainActor.assumeIsolated { self?.accept(connection) } }
            l.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if case .failed = state {
                        self.error = "The room could not start listening. Check that Local Network access is allowed in System Settings."
                        self.close()
                    }
                }
            }
            listener = l
            isOpen = true
            roster = MusicRoomRoster()
            tracker.reset(); lastQueueKeys = []
            l.start(queue: .main)
            newCode()
            publish()
            observeSource()
        } catch {
            self.error = "The room could not start listening."
        }
    }

    /// Tells every guest, hangs up, stops advertising and throws away the code.
    func close() {
        for s in sessions.values where s.phase == .member { send(.closed, to: s) }
        listener?.cancel(); listener = nil
        isOpen = false
        codeGuard.cancel()
        codeTimer?.cancel(); codeTimer = nil
        heartbeat?.cancel(); heartbeat = nil
        let all = Array(sessions.values)
        sessions.removeAll()
        for s in all { s.transport.close(nil) }
        roster = MusicRoomRoster()
        publish()
    }

    // MARK: code

    /// A fresh code. Refused while the room is locked after too many wrong tries.
    func newCode() {
        guard isOpen else { return }
        codeGuard.issue(now: wallClock())
        publishCode()
        codeTimer?.cancel()
        codeTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(MusicPairingGuard.codeLifetime * 1_000_000_000) + 200_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshCode()
        }
    }

    func refreshCode() {
        codeGuard.refresh(now: wallClock())
        publishCode()
    }

    private func publishCode() {
        let now = wallClock()
        code = codeGuard.activeCode(now: now)
        codeExpiresAt = code == nil ? nil : codeGuard.expiresAt
        lockedUntil = codeGuard.isLocked(now: now) ? codeGuard.lockedUntil : nil
    }

    private func publish() {
        participants = isOpen ? roster.participants(hostID: deviceID(), hostName: deviceName) : []
        pendingJoins = roster.pending
        pendingSuggestions = roster.suggestions
    }

    // MARK: the host's decisions

    func approveJoin(_ id: String) {
        guard let s = session(for: id, phase: .pending), let member = roster.approve(id: id) else {
            if let s = session(for: id, phase: .pending) { send(.error(MusicRoomError.roomFull.message), to: s); s.transport.close(nil) }
            return
        }
        s.phase = .member
        s.timeout?.cancel()
        _ = member
        send(.welcome(roomName: roomName, roster: roster.participants(hostID: deviceID(), hostName: deviceName), queue: queueDescriptors()), to: s)
        publish()
        broadcast(.roster(participants))
        sendAnchor(force: true)
        startHeartbeat()
    }

    func denyJoin(_ id: String) {
        guard let s = session(for: id, phase: .pending) else { return }
        roster.deny(id: id)
        send(.deny(ref: nil), to: s)
        s.transport.close(nil)
        publish()
    }

    func approveSuggestion(_ id: String) {
        guard let s = roster.resolveSuggestion(id: id) else { return }
        source?.roomEnqueue(s.track.asTrack())
        if let session = session(for: s.guestID, phase: .member) { send(.approve(ref: id), to: session) }
        publish()
    }

    func denySuggestion(_ id: String) {
        guard let s = roster.resolveSuggestion(id: id) else { return }
        if let session = session(for: s.guestID, phase: .member) { send(.deny(ref: id), to: session) }
        publish()
    }

    func kick(_ id: String) {
        guard let s = session(for: id, phase: .member) else { return }
        send(.kick, to: s)
        s.transport.close(nil)
    }

    private func session(for guestID: String, phase: RoomHostSession.Phase) -> RoomHostSession? {
        sessions.values.first { $0.guestID == guestID && $0.phase == phase }
    }

    // MARK: connections

    private func accept(_ connection: NWConnection) {
        guard isOpen, sessions.count < MusicRoomLimits.maxGuests * 2 else { connection.cancel(); return }
        let transport = MusicRemoteTransport(connection: connection)
        let s = RoomHostSession(transport: transport)
        sessions[ObjectIdentifier(s)] = s
        transport.onFrame = { [weak self, weak s] frame in
            guard let self, let s else { return }
            self.handle(frame, in: s)
        }
        transport.onClosed = { [weak self, weak s] _ in
            guard let self, let s else { return }
            self.dropped(s)
        }
        s.timeout = Task { [weak s] in
            try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
            if let s, s.phase == .hello || s.phase == .auth { s.transport.close(.timedOut) }
        }
        transport.start()
    }

    private func dropped(_ s: RoomHostSession) {
        s.timeout?.cancel()
        sessions[ObjectIdentifier(s)] = nil
        guard !s.guestID.isEmpty, s.phase == .member || s.phase == .pending else { return }
        // A newer connection from the same guest may already hold the seat.
        if sessions.values.contains(where: { $0.guestID == s.guestID && ($0.phase == .member || $0.phase == .pending) }) { return }
        let wasMember = s.phase == .member
        roster.remove(id: s.guestID)
        publish()
        if wasMember { broadcast(.roster(participants)) }
        if roster.members.isEmpty { heartbeat?.cancel(); heartbeat = nil }
    }

    private func handle(_ frame: Data, in s: RoomHostSession) {
        switch s.phase {
        case .hello: handleHello(frame, s)
        case .auth: handleAuth(frame, s)
        case .pending, .member: handleActive(frame, s)
        }
    }

    private func refuse(_ s: RoomHostSession, _ e: MusicRoomError) {
        if let data = try? JSONEncoder().encode(MusicRoomHello.refusal(e)) { s.transport.send(data) }
        s.transport.close(nil)
    }

    private func handleHello(_ frame: Data, _ s: RoomHostSession) {
        guard let hello = try? MusicRoomHello.decode(frame), hello.error == nil else { s.transport.close(.malformed("hello")); return }
        let now = wallClock()
        codeGuard.refresh(now: now); publishCode()
        if codeGuard.isLocked(now: now) { refuse(s, .locked); return }
        guard let code = codeGuard.activeCode(now: now) else { refuse(s, .codeClosed); return }
        if roster.isFull && !roster.isMember(hello.deviceID) { refuse(s, .roomFull); return }
        s.guestID = hello.deviceID
        s.guestName = MusicRoomSanitizer.text(hello.name, max: MusicRoomLimits.maxName)
        s.code = code
        let mine = MusicRemoteHandshake.newKeyPair()
        let nonce = MusicRemoteHandshake.randomNonce()
        let reply = MusicRoomHello(deviceID: deviceID(), name: deviceName, publicKey: mine.publicKey.rawRepresentation, nonce: nonce)
        guard let keys = try? MusicRoomHandshake.derive(privateKey: mine, peerPublic: hello.publicKey, code: code, guestNonce: hello.nonce,
                                                        hostNonce: nonce, guestPublic: hello.publicKey, hostPublic: mine.publicKey.rawRepresentation),
              let data = try? JSONEncoder().encode(reply) else { s.transport.close(.authenticationFailed); return }
        s.sealer = MusicRemoteSealer(key: keys.hostToGuest)
        s.opener = MusicRemoteSealer(key: keys.guestToHost)
        s.phase = .auth
        s.transport.send(data)
    }

    private func handleAuth(_ frame: Data, _ s: RoomHostSession) {
        let now = wallClock()
        let join: MusicRoomMessage
        do {
            guard let plain = try s.opener?.open(frame) else { throw MusicRoomError.authenticationFailed }
            join = try MusicRoomMessage.decode(plain)
            guard join.kind == .join, let id = join.id, id == s.guestID else { throw MusicRoomError.authenticationFailed }
            // The code must still be the live one: it may have expired or changed while this guest was typing.
            codeGuard.refresh(now: now)
            guard codeGuard.activeCode(now: now) == s.code else { throw MusicRoomError.authenticationFailed }
        } catch {
            // A wrong code is the only way to land here with a well-formed hello, so it counts as a wrong try.
            codeGuard.recordFailure(now: now); publishCode()
            s.transport.close(.authenticationFailed)
            return
        }
        s.guestName = join.name ?? s.guestName
        // The same guest coming back replaces the old connection.
        for other in sessions.values where other !== s && other.guestID == s.guestID && other.phase != .hello { other.transport.close(nil) }
        switch roster.requestJoin(id: s.guestID, name: s.guestName) {
        case .queued:
            s.phase = .pending
            send(.pending, to: s)
            publish()
            let id = s.guestID
            s.timeout?.cancel()
            s.timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(MusicRoomLimits.approvalSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.denyJoin(id)
            }
        case .full:
            send(.error(MusicRoomError.roomFull.message), to: s)
            s.transport.close(nil)
        case .alreadyMember:
            s.transport.close(nil)
        }
    }

    private func handleActive(_ frame: Data, _ s: RoomHostSession) {
        let message: MusicRoomMessage
        do {
            guard let plain = try s.opener?.open(frame) else { throw MusicRoomError.authenticationFailed }
            message = try MusicRoomMessage.decode(plain)
        } catch { s.transport.close(.authenticationFailed); return }
        let received = uptime()
        guard s.limiter.allow(at: ProcessInfo.processInfo.systemUptime) else { strike(s); return }
        switch message.kind {
        case .ping:
            guard let t0 = message.t0 else { return }
            send(.pong(t0: t0, t1: received, t2: uptime()), to: s)
        case .leave:
            s.transport.close(nil)
        case .suggest:
            guard s.phase == .member, let t = message.track, let ref = message.ref else { strike(s); return }
            if roster.suggest(from: s.guestID, suggestionID: ref, track: t) != nil {
                // Party mode: a guest's song joins the queue at once (the per-guest limit still applies); otherwise the host decides.
                if MusicListeningModes.profile.guestsMayQueue { approveSuggestion(ref) } else { publish() }
            }
        default:
            // Anything a guest has no right to send is ignored, and enough of it removes the guest.
            strike(s)
        }
    }

    private func strike(_ s: RoomHostSession) {
        if roster.strike(id: s.guestID) {
            send(.kick, to: s)
            s.transport.close(nil)
        }
    }

    // MARK: sending

    private func send(_ m: MusicRoomMessage, to s: RoomHostSession) {
        guard let data = try? m.encoded(), let sealed = try? s.sealer?.seal(data) else { s.transport.close(.malformed("send")); return }
        s.transport.send(sealed)
    }

    private func broadcast(_ m: MusicRoomMessage) {
        for s in sessions.values where s.phase == .member { send(m, to: s) }
    }

    private func queueDescriptors() -> [MusicRoomTrack] {
        guard let source else { return [] }
        return MusicRoomMessage.fittingQueue(source.roomQueueWindow.prefix(MusicRoomLimits.maxQueue).map { MusicRoomTrack($0) }).tracks ?? []
    }

    // MARK: following the host's player

    /// Looks at the player only when it changes (song, play state, queue, or a position tick) and sends an anchor only when something that
    /// matters changed. The player ticks only while it plays, so a paused or idle host costs nothing here.
    private func observeSource() {
        guard !observing, isOpen, let source else { return }
        observing = true
        withObservationTracking {
            _ = source.roomTrack; _ = source.roomIsPlaying; _ = source.roomIsBuffering; _ = source.roomQueueWindow; _ = source.roomTick
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observing = false
                self.sourceChanged()
                self.observeSource()
            }
        }
    }

    private func sourceChanged() {
        guard isOpen, source != nil else { return }
        let keys = (source?.roomQueueWindow ?? []).prefix(MusicRoomLimits.maxQueue).map { $0.uid }
        if keys != lastQueueKeys {
            lastQueueKeys = Array(keys)
            broadcast(MusicRoomMessage.fittingQueue(queueDescriptors()))
            sendAnchor(force: true)
        } else {
            sendAnchor(force: false)
        }
    }

    private func sendAnchor(force: Bool) {
        guard let source else { return }
        let track = source.roomTrack.map { MusicRoomTrack($0) }?.sanitized()
        // A song that is still loading counts as paused, so guests wait instead of racing ahead of a silent host.
        let playing = source.roomIsPlaying && !source.roomIsBuffering
        guard let a = tracker.observe(track: track, position: source.roomLivePosition, isPlaying: playing, hostNow: uptime(), force: force) else { return }
        broadcast(.anchor(a))
    }

    /// The one periodic message: the same anchor refreshed from the live position, every ten seconds, only while guests are present.
    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(MusicRoomLimits.heartbeat * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                if self.roster.members.isEmpty { self.heartbeat = nil; return }
                self.sendAnchor(force: true)
            }
        }
    }
}
