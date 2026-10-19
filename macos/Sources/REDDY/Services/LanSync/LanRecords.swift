import Foundation

/// A value inside a record, as JSON carries it.
enum LanValue: Codable, Equatable, Sendable {
    case string(String), int(Int64), double(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int64.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else { self = .string(try c.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        }
    }

    var string: String? { if case .string(let s) = self { s } else { nil } }
    var number: Double? { switch self { case .int(let i): Double(i); case .double(let d): d; default: nil } }
    var integer: Int64? { switch self { case .int(let i): i; case .double(let d): Int64(d); default: nil } }
    var flag: Bool? { if case .bool(let b) = self { b } else { nil } }
}

/// One thing that is kept in step between devices (see docs/WIFI-SYNC.md): `kind` is `fav`, `prog`, `col` or `colitem`, `key` says which one, `ts` is when it last changed (milliseconds),
/// and `deleted` says it was removed. `value` carries the rest, and is absent for a removal.
struct LanRecord: Codable, Equatable, Sendable {
    var kind: String
    var key: [String]
    var ts: Int64
    var deleted = false
    var value: [String: LanValue]?

    enum CodingKeys: String, CodingKey { case kind = "k", key, ts, del, value = "v" }

    init(kind: String, key: [String], ts: Int64, deleted: Bool = false, value: [String: LanValue]? = nil) {
        self.kind = kind; self.key = key; self.ts = ts; self.deleted = deleted; self.value = value
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind); key = try c.decode([String].self, forKey: .key); ts = try c.decode(Int64.self, forKey: .ts)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .del) ?? false
        value = try c.decodeIfPresent([String: LanValue].self, forKey: .value)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind); try c.encode(key, forKey: .key); try c.encode(ts, forKey: .ts)
        if deleted { try c.encode(true, forKey: .del) }
        try c.encodeIfPresent(value, forKey: .value)
    }

    var identity: String { kind + "\u{1}" + key.joined(separator: "\u{1}") }
}

/// Whether a change that arrived should replace what is here: only a strictly newer change does, so the same state sent back and forth settles.
func lanShouldApply(localTs: Int64?, remoteTs: Int64) -> Bool { localTs.map { remoteTs > $0 } ?? true }

/// The key that stands for a playlist on every device: the first 16 hex characters of SHA-256 of its address, lower-cased, without http(s):// and without trailing slashes.
enum LanSourceKey {
    static func of(_ address: String) -> String {
        var a = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://"] where a.hasPrefix(prefix) { a.removeFirst(prefix.count); break }
        while a.hasSuffix("/") { a.removeLast() }
        return LanCrypto.sha256(Data(a.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Every message of the conversation; which fields are present depends on `t`.
struct LanMessage: Codable, Sendable {
    var t: String
    var v: Int?
    var pub: String?
    var name: String?
    var nonce: String?
    var mode: String?
    var why: String?
    var ok: Bool?
    var records: [LanRecord]?
    var more: Bool?
}
