import Foundation
import CryptoKit

/// The one place that turns bytes into hex text and hashes strings, so no file carries its own copy.
enum MusicHash {
    /// Lower-case hex of any run of bytes.
    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        for b in bytes { out.append(digits[Int(b >> 4)]); out.append(digits[Int(b & 0x0f)]) }
        return String(decoding: out, as: UTF8.self)
    }

    /// SHA-256 as hex; `prefix` keeps only that many leading bytes (two hex characters each).
    static func sha256(_ data: Data, prefix: Int? = nil) -> String {
        let d = SHA256.hash(data: data)
        return hex(prefix.map { Array(d.prefix($0)) } ?? Array(d))
    }
    static func sha256(_ text: String, prefix: Int? = nil) -> String { sha256(Data(text.utf8), prefix: prefix) }

    /// MD5, only for services that require it (Last.fm signs requests with it); never used for anything secret.
    static func md5(_ text: String) -> String { hex(Insecure.MD5.hash(data: Data(text.utf8))) }
}
