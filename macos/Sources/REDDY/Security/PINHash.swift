import Foundation
import CommonCrypto
import CryptoKit

/// How a PIN is kept on the device. One SHA-256 pass is far too cheap for a number of four to eight digits: anyone holding a copy of the database or a backup could try every PIN
/// in seconds. A PIN is stored as PBKDF2-HMAC-SHA256, a deliberately slow derivation, with the number of rounds written into the stored text so it can be raised later:
///
///     pbkdf2-sha256$<rounds>$<64 hex digits>
///
/// The rounds are measured on the device so one check takes about a quarter of a second (a phone does far more than a Fire TV Stick). A PIN stored the old way (64 hex digits, salt
/// and PIN hashed once) is still accepted, and is stored again in the new form the first time the right PIN is entered. Wrong tries are throttled separately (PINThrottle).
enum PINHash {
    static let scheme = "pbkdf2-sha256"
    static let minRounds = 60_000, maxRounds = 600_000
    static let targetSeconds = 0.25

    enum Check: Equatable { case wrong, right, rightButOld }

    /// PBKDF2-HMAC-SHA256 of the PIN's digits. [length] is 32 bytes unless a test asks for more.
    static func derive(_ pin: String, salt: Data, rounds: Int, length: Int = 32) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: length)
        let pw = Array(pin.utf8)
        _ = pw.withUnsafeBufferPointer { p in
            salt.withUnsafeBytes { s in
                p.baseAddress!.withMemoryRebound(to: Int8.self, capacity: pw.count) { pp in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pp, pw.count, s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), &out, length)
                }
            }
        }
        return out
    }

    /// The number of rounds that makes one check take about [targetSeconds] on this device, between [minRounds] and [maxRounds]. Measured once per launch.
    static let calibratedRounds: Int = {
        let probe = 20_000
        let start = Date()
        _ = derive("0000", salt: Data("calibrate".utf8), rounds: probe)
        let took = max(Date().timeIntervalSince(start), 0.0005)
        return min(maxRounds, max(minRounds, Int(Double(probe) * targetSeconds / took)))
    }()

    /// The text to store for this PIN and salt.
    static func make(_ pin: String, salt: Data, rounds: Int? = nil) -> String {
        let r = rounds ?? calibratedRounds
        return "\(scheme)$\(r)$" + hex(derive(pin, salt: salt, rounds: r))
    }

    /// Whether the PIN matches what was stored. `.rightButOld` means it matches but the stored text is the old single-pass form and should be replaced with [make].
    static func verify(_ pin: String, salt: Data, stored: String) -> Check {
        let parts = stored.split(separator: "$", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 3, parts[0] == scheme, let rounds = Int(parts[1]), rounds > 0, rounds <= 10_000_000 {
            return constantTimeEqual(hex(derive(pin, salt: salt, rounds: rounds)), parts[2]) ? .right : .wrong
        }
        if parts.count == 1 {
            let legacy = hex(Array(SHA256.hash(data: salt + Data(pin.utf8))))
            return constantTimeEqual(legacy, stored) ? .rightButOld : .wrong
        }
        return .wrong
    }

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    /// Compared in full whatever the first difference, so timing says nothing about the PIN.
    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
