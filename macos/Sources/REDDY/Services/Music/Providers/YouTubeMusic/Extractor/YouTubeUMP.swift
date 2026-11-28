import Foundation

// The container YouTube's server-driven streaming answers in: a flat run of parts, each `[type][size][payload]`, where type and size use a
// variable-length integer whose first byte says how many bytes follow. Parsing is pure and tolerant: a cut-off last part is reported, never
// guessed at.

enum YouTubeUMP {
    struct Part: Sendable, Equatable {
        var type: Int
        var payload: [UInt8]
    }

    enum PartType {
        static let mediaHeader = 20, media = 21, mediaEnd = 22
        static let nextRequestPolicy = 35, formatInitialization = 42, redirect = 43, error = 44
        static let reloadPlayerResponse = 46, contextUpdate = 57, streamProtectionStatus = 58
    }

    /// Reads one length value at `i`. Returns nil when the bytes run out.
    static func readVarint(_ b: [UInt8], at i: Int) -> (value: Int, length: Int)? {
        guard i < b.count else { return nil }
        let b0 = Int(b[i])
        let length = b0 < 0x80 ? 1 : b0 < 0xC0 ? 2 : b0 < 0xE0 ? 3 : b0 < 0xF0 ? 4 : 5
        guard i + length <= b.count else { return nil }
        func at(_ k: Int) -> Int { Int(b[i + k]) }
        switch length {
        case 1: return (b0, 1)
        case 2: return ((b0 & 0x3F) + 64 * at(1), 2)
        case 3: return ((b0 & 0x1F) + 32 * (at(1) + 256 * at(2)), 3)
        case 4: return ((b0 & 0x0F) + 16 * (at(1) + 256 * (at(2) + 256 * at(3))), 4)
        default: return (at(1) | at(2) << 8 | at(3) << 16 | at(4) << 24, 5)
        }
    }

    static func encodeVarint(_ v: Int) -> [UInt8] {
        switch v {
        case ..<0x80: return [UInt8(v)]
        case ..<0x4000: return [UInt8(0x80 | (v & 0x3F)), UInt8(v >> 6)]
        case ..<0x200000: return [UInt8(0xC0 | (v & 0x1F)), UInt8((v >> 5) & 0xFF), UInt8(v >> 13)]
        case ..<0x10000000: return [UInt8(0xE0 | (v & 0x0F)), UInt8((v >> 4) & 0xFF), UInt8((v >> 12) & 0xFF), UInt8(v >> 20)]
        default: return [0xF0, UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        }
    }

    /// Splits a body into parts. `complete` is false when the data ended inside a part.
    static func parse(_ data: [UInt8]) -> (parts: [Part], complete: Bool) {
        var parts: [Part] = []
        var i = 0
        while i < data.count {
            guard let t = readVarint(data, at: i), let s = readVarint(data, at: i + t.length) else { return (parts, false) }
            let start = i + t.length + s.length
            guard start + s.value <= data.count else { return (parts, false) }
            parts.append(Part(type: t.value, payload: Array(data[start..<start + s.value])))
            i = start + s.value
        }
        return (parts, true)
    }

    static func encode(_ parts: [Part]) -> [UInt8] {
        parts.flatMap { encodeVarint($0.type) + encodeVarint($0.payload.count) + $0.payload }
    }
}

// MARK: minimal protobuf

/// Just enough protobuf to write one request and read a few fields of the answers.
enum YTMWire {
    static func varint(_ v: UInt64) -> [UInt8] {
        var out: [UInt8] = [], n = v
        repeat { var b = UInt8(n & 0x7F); n >>= 7; if n != 0 { b |= 0x80 }; out.append(b) } while n != 0
        return out
    }
    static func field(_ number: Int, varint v: UInt64) -> [UInt8] { varint(UInt64(number << 3)) + varint(v) }
    static func field(_ number: Int, bytes: [UInt8]) -> [UInt8] { varint(UInt64(number << 3 | 2)) + varint(UInt64(bytes.count)) + bytes }
    static func field(_ number: Int, string: String) -> [UInt8] { field(number, bytes: Array(string.utf8)) }
    static func field(_ number: Int, float v: Float) -> [UInt8] {
        let bits = v.bitPattern
        return varint(UInt64(number << 3 | 5)) + [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF), UInt8((bits >> 16) & 0xFF), UInt8(bits >> 24)]
    }

    enum Value: Equatable { case varint(UInt64), bytes([UInt8]), fixed32(UInt32), fixed64(UInt64) }

    /// All fields of one message in order; nil when the bytes are malformed.
    static func parse(_ b: [UInt8]) -> [(number: Int, value: Value)]? {
        var out: [(Int, Value)] = []
        var i = 0
        func readVar() -> UInt64? {
            var r: UInt64 = 0, shift: UInt64 = 0
            while i < b.count, shift < 64 { let x = b[i]; i += 1; r |= UInt64(x & 0x7F) << shift; if x & 0x80 == 0 { return r }; shift += 7 }
            return nil
        }
        while i < b.count {
            guard let tag = readVar() else { return nil }
            let num = Int(tag >> 3)
            switch tag & 7 {
            case 0: guard let v = readVar() else { return nil }; out.append((num, .varint(v)))
            case 2:
                guard let l = readVar(), i + Int(l) <= b.count else { return nil }
                out.append((num, .bytes(Array(b[i..<i + Int(l)])))); i += Int(l)
            case 5:
                guard i + 4 <= b.count else { return nil }
                out.append((num, .fixed32(UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24))); i += 4
            case 1:
                guard i + 8 <= b.count else { return nil }
                var v: UInt64 = 0
                for k in 0..<8 { v |= UInt64(b[i + k]) << UInt64(8 * k) }
                out.append((num, .fixed64(v))); i += 8
            default: return nil
            }
        }
        return out
    }
}
