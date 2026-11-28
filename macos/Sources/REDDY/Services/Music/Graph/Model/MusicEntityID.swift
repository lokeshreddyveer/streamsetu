import Foundation
import CryptoKit

/// What a node of the music graph is (section 1.1 of the graph design). The raw values are stored in the database: never renumber.
enum MusicEntityKind: UInt8, Codable, Sendable, CaseIterable, Hashable {
    case recording = 0, work, track, album, release, film, series, person, group, playlist, genre, language, region, era, station

    /// The text used in an id (`album:7K2QXM4V9ZT3B`).
    var slug: String { String(describing: self) }
    init?(slug: String) { if let k = Self.allCases.first(where: { $0.slug == slug }) { self = k } else { return nil } }

    /// Kinds that are people-like credit targets.
    var isAgent: Bool { self == .person || self == .group }
    /// Kinds that are things a person can open as a page about a piece of work (a song, an album, a film).
    var isWork: Bool { switch self { case .recording, .work, .track, .album, .release, .film, .series: true; default: false } }
    /// Facet nodes: a few thousand rows at most, never evicted by age.
    var isFacet: Bool { switch self { case .genre, .language, .region, .era: true; default: false } }
}

/// A stable id: `kind:token`. The token is 13 characters of base32, derived ONCE, at creation, from a hash of the entity's first alias key
/// (a provider uid such as `jiosaavn:abc123`, or `kind|phonetic-key` for one minted locally) and never recomputed. So a route or a history
/// entry can build an id on the main actor without a database read: the same provider item always gives the same provisional id, and the store
/// later files the row under it. A merge keeps the survivor's id and leaves a redirect for the loser, so a saved id never breaks.
struct MusicEntityID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    let kind: MusicEntityKind
    let token: String

    init(kind: MusicEntityKind, token: String) { self.kind = kind; self.token = token }

    /// `kind:token`, or nil when the text is not one.
    init?(rawValue: String) {
        guard let colon = rawValue.firstIndex(of: ":"), let k = MusicEntityKind(slug: String(rawValue[..<colon])) else { return nil }
        let t = String(rawValue[rawValue.index(after: colon)...])
        guard t.count == Self.tokenLength, t.allSatisfy({ Self.alphabet.contains($0) }) else { return nil }
        self.kind = k; self.token = t
    }

    var rawValue: String { kind.slug + ":" + token }
    var description: String { rawValue }

    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let id = MusicEntityID(rawValue: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an entity id: \(s)"))
        }
        self = id
    }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }

    static func < (a: MusicEntityID, b: MusicEntityID) -> Bool { a.rawValue < b.rawValue }

    // MARK: derivation

    static let tokenLength = 13
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")   // Crockford base32: no I, L, O, U

    /// The id of an entity whose first alias key is `aliasKey`. Pure and total: same input, same id, on every device and launch.
    static func derive(kind: MusicEntityKind, aliasKey: String) -> MusicEntityID {
        let digest = SHA256.hash(data: Data((kind.slug + "|" + aliasKey).utf8))
        var v: UInt64 = 0
        for b in digest.prefix(8) { v = (v << 8) | UInt64(b) }
        var chars = [Character](repeating: "0", count: tokenLength)
        for i in stride(from: tokenLength - 1, through: 0, by: -1) { chars[i] = alphabet[Int(v & 31)]; v >>= 5 }
        return MusicEntityID(kind: kind, token: String(chars))
    }

    /// The id a provider item gets, with no database read. `providerUID` is the existing `providerID:id` uid.
    static func provisional(kind: MusicEntityKind, providerUID: String) -> MusicEntityID {
        derive(kind: kind, aliasKey: ExternalID(scheme: .provider, value: providerUID).aliasKey)
    }

    /// The id for an entity whose first alias is this external id.
    static func provisional(kind: MusicEntityKind, externalID: ExternalID) -> MusicEntityID { derive(kind: kind, aliasKey: externalID.aliasKey) }

    /// The id for an entity minted from a name alone (no id from any source): the folded name, plus the year when known so two films of one
    /// title do not collapse.
    static func provisional(kind: MusicEntityKind, name: String, year: Int? = nil) -> MusicEntityID {
        derive(kind: kind, aliasKey: "name|" + MusicGraphText.latin(name) + (year.map { "|\($0)" } ?? ""))
    }

    // MARK: route building

    /// A string for a route or a deep link (`reddy://music/album/7K2QXM4V9ZT3B`-style path component).
    var routePath: String { kind.slug + "/" + token }
    init?(routePath: String) {
        let parts = routePath.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        self.init(rawValue: parts[0] + ":" + parts[1])
    }
}
