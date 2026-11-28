import Foundation
import CryptoKit
import Observation
import Security

// Pairing and session crypto. The 6-digit code is low in entropy, so it is never put on the wire and never checked by comparison:
// both sides mix it into an ephemeral key agreement, and the code is right only if the first sealed message opens. A guesser therefore
// gets exactly one try per connection, and the host counts every failed try.

enum MusicRemoteHandshake {
    enum Mode: String, Codable, Sendable { case pair, session }

    struct Keys: Sendable {
        let controllerToHost: SymmetricKey
        let hostToController: SymmetricKey
        /// Long-term key both sides keep after a first pairing. Unused for later sessions.
        let pairKey: SymmetricKey
    }

    static func newKeyPair() -> Curve25519.KeyAgreement.PrivateKey { Curve25519.KeyAgreement.PrivateKey() }

    static func randomNonce() -> Data { Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }) }

    /// `secret` is the pairing code (pair mode) or the stored pair key (session mode).
    static func derive(privateKey: Curve25519.KeyAgreement.PrivateKey, peerPublic: Data, mode: Mode, secret: Data,
                       controllerNonce: Data, hostNonce: Data, controllerPublic: Data, hostPublic: Data) throws -> Keys {
        let shared: SharedSecret
        do {
            let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublic)
            shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        } catch { throw MusicRemoteError.authenticationFailed }
        var transcript = Data("streamsetu-music-remote-v1-\(mode.rawValue)".utf8)
        for part in [secret, controllerNonce, hostNonce, controllerPublic, hostPublic] {
            transcript.append(contentsOf: UInt16(part.count).bigEndianBytes)
            transcript.append(part)
        }
        let salt = Data(SHA256.hash(data: transcript))
        func key(_ label: String) -> SymmetricKey {
            shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data(label.utf8), outputByteCount: 32)
        }
        return Keys(controllerToHost: key("c2h"), hostToController: key("h2c"), pairKey: key("pair"))
    }
}

private extension UInt16 {
    var bigEndianBytes: [UInt8] { [UInt8(self >> 8), UInt8(self & 0xff)] }
}

/// Seals frames with ChaCha20-Poly1305. The nonce is a per-direction counter that is never sent, so a replayed, dropped or reordered
/// frame fails to open.
struct MusicRemoteSealer: Sendable {
    private let key: SymmetricKey
    private var counter: UInt64 = 0
    init(key: SymmetricKey) { self.key = key }

    private func nonce() throws -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: bytes)
    }

    mutating func seal(_ plain: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plain, using: key, nonce: nonce())
        counter += 1
        return box.ciphertext + box.tag
    }

    mutating func open(_ sealed: Data) throws -> Data {
        guard sealed.count > 16 else { throw MusicRemoteError.authenticationFailed }
        do {
            let box = try ChaChaPoly.SealedBox(nonce: nonce(), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
            let plain = try ChaChaPoly.open(box, using: key)
            counter += 1
            return plain
        } catch { throw MusicRemoteError.authenticationFailed }
    }
}

// MARK: Pairing code lifetime

/// The one-time code on the host: valid for two minutes, single use, and five wrong tries lock pairing for ten minutes.
struct MusicPairingGuard: Sendable {
    static let codeLifetime: TimeInterval = 120
    static let maxFailures = 5
    static let lockDuration: TimeInterval = 600

    private(set) var code: String?
    private(set) var expiresAt: Date?
    private(set) var failures = 0
    private(set) var lockedUntil: Date?

    static func randomCode() -> String {
        String(format: "%06d", Int.random(in: 0..<1_000_000))
    }

    func isLocked(now: Date) -> Bool { lockedUntil.map { now < $0 } ?? false }

    func lockRemaining(now: Date) -> TimeInterval { max(0, lockedUntil?.timeIntervalSince(now) ?? 0) }

    /// The code, only while it is still valid.
    func activeCode(now: Date) -> String? {
        guard !isLocked(now: now), let code, let expiresAt, now < expiresAt else { return nil }
        return code
    }

    /// Starts a new code. Refused (nil) while locked.
    @discardableResult
    mutating func issue(now: Date, code: String = MusicPairingGuard.randomCode()) -> String? {
        refresh(now: now)
        guard !isLocked(now: now) else { return nil }
        self.code = code
        self.expiresAt = now.addingTimeInterval(Self.codeLifetime)
        return code
    }

    /// Counts a wrong try. The fifth one locks pairing and throws the code away.
    mutating func recordFailure(now: Date) {
        refresh(now: now)
        failures += 1
        if failures >= Self.maxFailures {
            lockedUntil = now.addingTimeInterval(Self.lockDuration)
            failures = 0
            cancel()
        }
    }

    /// A correct code is good once.
    mutating func recordSuccess() { cancel(); failures = 0 }

    mutating func cancel() { code = nil; expiresAt = nil }

    /// Clears an elapsed lock or an elapsed code.
    mutating func refresh(now: Date) {
        if let l = lockedUntil, now >= l { lockedUntil = nil; failures = 0 }
        if let e = expiresAt, now >= e { cancel() }
    }
}

// MARK: Paired devices

struct MusicPairedDevice: Codable, Hashable, Identifiable, Sendable {
    enum Role: String, Codable, Sendable {
        /// This device may control me.
        case controller
        /// I may control this device.
        case host
    }
    var deviceID: String
    var name: String
    var role: Role
    var key: Data
    var pairedAt: Date
    var id: String { role.rawValue + ":" + deviceID }
}

/// Where the keys live. The real one is the Keychain; tests use memory.
protocol MusicRemoteSecretStore: AnyObject, Sendable {
    func read(_ account: String) -> Data?
    func write(_ account: String, _ data: Data)
    func delete(_ account: String)
}

final class MusicRemoteMemoryStore: MusicRemoteSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    init() {}
    func read(_ account: String) -> Data? { lock.lock(); defer { lock.unlock() }; return items[account] }
    func write(_ account: String, _ data: Data) { lock.lock(); items[account] = data; lock.unlock() }
    func delete(_ account: String) { lock.lock(); items[account] = nil; lock.unlock() }
}

/// The device keys and the paired list, in the Keychain under the Music service name.
final class MusicRemoteKeychain: MusicRemoteSecretStore, @unchecked Sendable {
    init() {}
    func read(_ account: String) -> Data? { MusicKeychain.shared.readData(account) }
    func write(_ account: String, _ data: Data) { MusicKeychain.shared.writeData(account, data) }
    func delete(_ account: String) { MusicKeychain.shared.remove(account) }
}

/// The paired list. Revoking removes the key at once and tells the host to hang up on that device.
@MainActor @Observable
final class MusicPairedDevices {
    private(set) var devices: [MusicPairedDevice] = []
    @ObservationIgnored private let store: any MusicRemoteSecretStore
    @ObservationIgnored var onRevoked: (@MainActor (MusicPairedDevice) -> Void)?
    private static let listAccount = "remote-paired-devices"
    private static let identityAccount = "remote-device-id"

    init(store: any MusicRemoteSecretStore = MusicRemoteKeychain()) {
        self.store = store
        if let data = store.read(Self.listAccount), let list = try? JSONDecoder().decode([MusicPairedDevice].self, from: data) { devices = list }
    }

    /// A random id for this device, made once and kept. It identifies the device to its own paired peers and nothing else.
    var ownDeviceID: String {
        if let d = store.read(Self.identityAccount), let s = String(data: d, encoding: .utf8), !s.isEmpty { return s }
        let id = UUID().uuidString
        store.write(Self.identityAccount, Data(id.utf8))
        return id
    }

    var controllers: [MusicPairedDevice] { devices.filter { $0.role == .controller } }
    var hosts: [MusicPairedDevice] { devices.filter { $0.role == .host } }

    func record(_ deviceID: String, role: MusicPairedDevice.Role) -> MusicPairedDevice? {
        devices.first { $0.deviceID == deviceID && $0.role == role }
    }

    func add(deviceID: String, name: String, role: MusicPairedDevice.Role, key: Data, now: Date = Date()) {
        devices.removeAll { $0.deviceID == deviceID && $0.role == role }
        devices.append(MusicPairedDevice(deviceID: deviceID, name: MusicRemoteSanitizer.text(name).prefix(MusicRemoteLimits.maxName).description, role: role, key: key, pairedAt: now))
        persist()
    }

    func revoke(_ d: MusicPairedDevice) {
        devices.removeAll { $0.id == d.id }
        persist()
        onRevoked?(d)
    }

    func revokeAll() {
        let old = devices
        devices = []
        persist()
        old.forEach { onRevoked?($0) }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(devices) { store.write(Self.listAccount, data) }
    }
}
