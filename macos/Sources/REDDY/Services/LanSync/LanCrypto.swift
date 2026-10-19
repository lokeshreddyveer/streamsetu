import Foundation
import CryptoKit

/// The cryptography of sync on this network, as written in docs/WIFI-SYNC.md: a long-term P-256 key for each device, a shared secret from ECDH, a session key and the six
/// comparison digits from HKDF-SHA256, and AES-256-GCM for every frame after the hello. The Android apps do the same, so the two can talk to each other.
enum LanCrypto {
    struct Identity {
        let privateKey: P256.KeyAgreement.PrivateKey
        var publicX963: Data { privateKey.publicKey.x963Representation }
        var deviceId: String { LanCrypto.deviceId(publicX963) }
        static func make() -> Identity { Identity(privateKey: P256.KeyAgreement.PrivateKey()) }
        init(privateKey: P256.KeyAgreement.PrivateKey) { self.privateKey = privateKey }
        init(raw: Data) throws { privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: raw) }
        var raw: Data { privateKey.rawRepresentation }
    }

    static func randomBytes(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8.random(in: 0...255) }) }

    static func deviceId(_ publicX963: Data) -> String { SHA256.hash(data: publicX963).prefix(8).map { String(format: "%02x", $0) }.joined() }

    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    /// The 32-byte shared secret between our private key and the other device's public key.
    static func sharedSecret(_ identity: Identity, peerX963: Data) throws -> Data {
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: peerX963)
        let secret = try identity.privateKey.sharedSecretFromKeyAgreement(with: peer)
        return secret.withUnsafeBytes { Data($0) }
    }

    static func hkdf(_ ikm: Data, salt: Data, info: Data, length: Int) -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: info, outputByteCount: length)
        return key.withUnsafeBytes { Data($0) }
    }

    static func sessionKey(_ z: Data, nonceInitiator: Data, nonceResponder: Data) -> Data {
        hkdf(z, salt: nonceInitiator + nonceResponder, info: Data("streamsetu-sync-v1 session".utf8), length: 32)
    }

    /// The six digits both people compare while pairing.
    static func comparisonDigits(_ z: Data, publicInitiator: Data, publicResponder: Data) -> String {
        let b = [UInt8](hkdf(z, salt: publicInitiator + publicResponder, info: Data("streamsetu-sync-v1 sas".utf8), length: 4))
        let n = (UInt64(b[0]) << 24) | (UInt64(b[1]) << 16) | (UInt64(b[2]) << 8) | UInt64(b[3])
        return String(format: "%06d", n % 1_000_000)
    }

    /// One direction of an encrypted connection: `sending` is 0 for what the initiator sends and 1 for what the responder sends. Every frame uses the next counter.
    final class Channel {
        private let key: SymmetricKey
        private let sending: UInt8
        private var sent: UInt64 = 0
        private var received: UInt64 = 0

        init(key: Data, sending: UInt8) { self.key = SymmetricKey(data: key); self.sending = sending }

        func seal(_ plain: Data) throws -> Data {
            let box = try AES.GCM.seal(plain, using: key, nonce: AES.GCM.Nonce(data: Self.nonce(sending, sent)))
            sent += 1
            return box.ciphertext + box.tag
        }

        func open(_ frame: Data) throws -> Data {
            guard frame.count >= 16 else { throw LanError.badFrame }
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: Self.nonce(1 - sending, received)), ciphertext: frame.prefix(frame.count - 16), tag: frame.suffix(16))
            let plain = try AES.GCM.open(box, using: key)
            received += 1
            return plain
        }

        static func nonce(_ direction: UInt8, _ counter: UInt64) -> Data {
            var n = [UInt8](repeating: 0, count: 12)
            n[3] = direction
            for i in 0..<8 { n[11 - i] = UInt8((counter >> UInt64(8 * i)) & 0xff) }
            return Data(n)
        }
    }
}

enum LanError: Error { case badFrame, badMessage }
