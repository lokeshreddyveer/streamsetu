import Foundation
import Network
import Observation

/// The devices this one has been paired with, kept in preferences (public keys and names only, nothing secret).
final class LanTrustStore: LanTrust, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "lan.trusted"
    private let lock = NSLock()

    init(defaults: UserDefaults) { self.defaults = defaults }

    func all() -> [LanPeer] {
        lock.lock(); defer { lock.unlock() }
        return load()
    }
    func find(_ publicX963: Data) -> LanPeer? { all().first { $0.publicX963 == publicX963 } }
    func add(_ peer: LanPeer) {
        lock.lock(); defer { lock.unlock() }
        var list = load().filter { $0.id != peer.id }
        list.append(peer)
        save(list)
    }
    func remove(id: String) {
        lock.lock(); defer { lock.unlock() }
        save(load().filter { $0.id != id })
    }
    private func load() -> [LanPeer] { defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([LanPeer].self, from: $0) } ?? [] }
    private func save(_ list: [LanPeer]) { defaults.set(try? JSONEncoder().encode(list), forKey: key) }
}

/// A switch that is read from other threads.
final class LanFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var value: Bool { get { lock.lock(); defer { lock.unlock() }; return on } set { lock.lock(); on = newValue; lock.unlock() } }
}

/// Sync on this network: finds the person's other devices, pairs with them once (both people compare six digits), and then keeps favourites, Watch Later, collections and resume points in step.
@MainActor @Observable
final class LanSyncService {
    struct Prompt: Identifiable {
        let id = UUID()
        let digits: String
        let peerName: String
        let answer: LanAnswer
    }

    private(set) var enabled = false
    private(set) var found: [LanFound] = []
    private(set) var trusted: [LanPeer] = []
    private(set) var prompt: Prompt?
    private(set) var status = "Off"
    private(set) var lastSync: Date?
    /// True while the "Add a device" screen is open, so an unknown device that connects may be paired.
    private(set) var pairingOpen = false
    private(set) var pairingMessage: String?

    private let credentials: CredentialStore
    private let trust: LanTrustStore
    private let data: LanData
    private let pairingFlag = LanFlag()
    private let onApplied: @MainActor (Int) -> Void
    private var identity: LanCrypto.Identity?
    private var discovery: LanDiscovery?
    private var timer: Task<Void, Never>?
    private var busy: Set<String> = []
    private let deviceName: String
    private static let identityRef = "lan.identity"

    init(credentials: CredentialStore, defaults: UserDefaults, data: LanData, deviceName: String, onApplied: @escaping @MainActor (Int) -> Void) {
        self.credentials = credentials; self.trust = LanTrustStore(defaults: defaults); self.data = data; self.deviceName = deviceName; self.onApplied = onApplied
        trusted = trust.all()
    }

    /// Makes the service match the switch in Settings.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on { start() } else { stop() }
    }

    private func loadIdentity() -> LanCrypto.Identity {
        if let saved = (try? credentials.load(ref: Self.identityRef))?.password, let raw = Data(base64Encoded: saved), let id = try? LanCrypto.Identity(raw: raw) { return id }
        let fresh = LanCrypto.Identity.make()
        try? credentials.save(Credentials(username: "sync", password: fresh.raw.base64EncodedString(), url: nil), ref: Self.identityRef)
        return fresh
    }

    private func start() {
        let id = loadIdentity()
        identity = id
        status = "Looking for your devices…"
        let d = LanDiscovery(deviceId: id.deviceId, deviceName: deviceName)
        d.onConnection = { [weak self] c in Task { @MainActor in self?.accept(c) } }
        d.onFound = { [weak self] list in Task { @MainActor in self?.foundChanged(list) } }
        d.start()
        discovery = d
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 90_000_000_000)
                await self?.syncNow()
            }
        }
    }

    /// The links open right now (to a device we dialled or one that dialled us). Turning the service off closes them, so no exchange outlives it and reads or writes the next profile's data.
    private var openLinks: [UUID: () -> Void] = [:]

    private func stop() {
        openLinks.values.forEach { $0() }; openLinks = [:]
        discovery?.stop(); discovery = nil
        timer?.cancel(); timer = nil
        found = []; status = "Off"; pairingOpen = false; pairingFlag.value = false
        prompt?.answer.resolve(false); prompt = nil
    }

    private func foundChanged(_ list: [LanFound]) {
        let old = Set(found.map(\.id))
        found = list
        if list.isEmpty { status = trusted.isEmpty ? "No other devices found" : "Your other devices are not on this network" }
        // a paired device that just appeared: bring it up to date
        if list.contains(where: { f in !old.contains(f.id) && trusted.contains(where: { t in t.id == f.id }) }) { Task { await syncNow() } }
    }

    /// Opens or closes the "Add a device" screen's willingness to be paired.
    func setPairing(open: Bool) {
        pairingOpen = open; pairingFlag.value = open
        pairingMessage = nil
    }

    func forget(_ peer: LanPeer) { trust.remove(id: peer.id); trusted = trust.all() }

    private var nudgeTask: Task<Void, Never>?
    /// Something worth telling the other devices about happened (playback started or stopped): sync shortly, once, however many such events come together.
    func nudge() {
        guard enabled, !trusted.isEmpty else { return }
        nudgeTask?.cancel()
        nudgeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { await self?.syncNow() }
        }
    }

    /// Syncs with every paired device that is on the network now.
    func syncNow() async {
        guard enabled else { return }
        for f in found where trusted.contains(where: { $0.id == f.id }) { await run(f, pairing: false) }
    }

    /// Starts pairing with a device found on the network (the person tapped it in "Add a device").
    func pair(with f: LanFound) async { await run(f, pairing: true) }

    private func makeProtocol() -> LanProtocol? {
        guard let identity else { return nil }
        let flag = pairingFlag
        return LanProtocol(identity: identity, deviceName: deviceName, trust: trust, data: data,
                           offerPairing: { flag.value },
                           confirm: { [weak self] digits, name in await self?.ask(digits: digits, peerName: name) ?? false })
    }

    private func run(_ f: LanFound, pairing: Bool) async {
        guard let discovery, let proto = makeProtocol(), !busy.contains(f.id) else { return }
        busy.insert(f.id); defer { busy.remove(f.id) }
        status = "Syncing with \(f.name)…"
        let link = discovery.connect(f)
        let key = UUID(); openLinks[key] = { link.close() }
        defer { openLinks[key] = nil }
        do { try await link.open() } catch { status = "Could not reach \(f.name)"; return }
        let outcome = await proto.runInitiator(link)
        link.close()
        guard enabled else { return }          // switched off meanwhile: whatever came back is not applied
        finish(outcome, name: f.name)
    }

    private func accept(_ c: NWConnection) {
        guard enabled, let proto = makeProtocol() else { c.cancel(); return }
        let link = NWLanLink(c)
        let key = UUID(); openLinks[key] = { link.close() }
        Task {
            defer { openLinks[key] = nil }
            do { try await link.open() } catch { return }
            let outcome = await proto.runResponder(link)
            link.close()
            guard enabled else { return }
            finish(outcome, name: nil)
        }
    }

    private func finish(_ outcome: LanOutcome, name: String?) {
        trusted = trust.all()
        switch outcome {
        case .synced(let peer, let received, let paired):
            lastSync = Date()
            status = "Synced with \(peer.name)"
            if paired { pairingMessage = "\(peer.name) is now paired."; pairingOpen = false; pairingFlag.value = false }
            if received > 0 { onApplied(received) }
        case .refused(let why):
            status = why == "not paired" ? "\(name ?? "A device") is not paired with this one" : "Pairing was not confirmed"
            if pairingOpen { pairingMessage = status }
        case .failed:
            status = "Sync with \(name ?? "a device") did not finish"
        }
        prompt?.answer.resolve(false); prompt = nil
    }

    /// Shows the six digits and waits for the person to say whether they match the other device's.
    private func ask(digits: String, peerName: String) async -> Bool {
        await withCheckedContinuation { (k: CheckedContinuation<Bool, Never>) in
            let answer = LanAnswer(k)
            prompt?.answer.resolve(false)
            prompt = Prompt(digits: digits, peerName: peerName, answer: answer)
        }
    }

    func answer(_ matches: Bool) {
        prompt?.answer.resolve(matches)
        prompt = nil
    }
}

/// An answer that can be given once.
final class LanAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var k: CheckedContinuation<Bool, Never>?
    init(_ k: CheckedContinuation<Bool, Never>) { self.k = k }
    func resolve(_ value: Bool) {
        lock.lock(); let c = k; k = nil; lock.unlock()
        c?.resume(returning: value)
    }
}
