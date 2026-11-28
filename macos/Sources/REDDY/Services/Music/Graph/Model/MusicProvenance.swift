import Foundation

/// Where a claim came from. A string, so a new source needs no change here.
struct MusicSourceID: Hashable, Codable, Sendable, RawRepresentable, ExpressibleByStringLiteral, CustomStringConvertible {
    var rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { rawValue = value }
    var description: String { rawValue }

    static let musicbrainz: MusicSourceID = "musicbrainz"
    static let wikidata: MusicSourceID = "wikidata"
    static let tmdb: MusicSourceID = "tmdb"
    static let listenbrainz: MusicSourceID = "listenbrainz"
    static let discogs: MusicSourceID = "discogs"
    static let jiosaavn: MusicSourceID = "jiosaavn"
    static let appleMusic: MusicSourceID = "appleMusic"
    static let ytMusic: MusicSourceID = "ytMusic"
    static let imdb: MusicSourceID = "imdb"
    static let wikipedia: MusicSourceID = "wikipedia"
    static let omdb: MusicSourceID = "omdb"
    static let lastfm: MusicSourceID = "lastfm"
    static let matcher: MusicSourceID = "matcher"
    static let user: MusicSourceID = "user"

    /// Higher beats lower when claims disagree (section 3.4 item 11): the person, then MusicBrainz and Wikidata, then IMDb and TMDB (equal: a disagreement is `conflicted`), then Wikipedia, OMDb, Discogs,
    /// provider artist maps and tags, provider text, and last the app's own heuristics. A provider source not listed ranks as provider text.
    var rank: Int {
        switch rawValue {
        case "user": 6
        case "musicbrainz", "wikidata": 5
        case "imdb", "tmdb": 4
        case "wikipedia", "omdb", "discogs": 3
        case "matcher": 1
        default: 2
        }
    }
    /// Sources that can make an edge `verified`.
    var isAuthoritative: Bool { rank >= 4 }
}

/// The licence a stored fact carries; it decides how long it may be kept.
enum SourceLicense: Int, Codable, Sendable, Hashable {
    case cc0 = 0, ccBySa, ccByNcSa, termsRestricted, providerCache, user, derived
}

enum Stance: Int, Codable, Sendable, Hashable { case contradicts = 0, asserts = 1 }

/// One claim about an edge: who said it, when, under which licence, how sure.
struct MusicProvenance: Hashable, Codable, Sendable {
    var source: MusicSourceID
    var sourceRef: String?
    var retrievedAt: Date
    var expiresAt: Date?
    var license: SourceLicense
    var score: Float?
    var matcherVersion: Int?
    /// Short tokens: "isrc", "title+year", "composer-match", and "stated" when the source states the link in so many words.
    var evidence: [String]
    var stance: Stance
    var userOverride: Bool

    init(source: MusicSourceID, sourceRef: String? = nil, retrievedAt: Date = Date(), expiresAt: Date? = nil, license: SourceLicense = .providerCache,
         score: Float? = nil, matcherVersion: Int? = nil, evidence: [String] = [], stance: Stance = .asserts, userOverride: Bool = false) {
        self.source = source; self.sourceRef = sourceRef; self.retrievedAt = retrievedAt; self.expiresAt = expiresAt; self.license = license
        self.score = score; self.matcherVersion = matcherVersion; self.evidence = evidence; self.stance = stance; self.userOverride = userOverride
    }

    static let statedToken = "stated"
    var statesLink: Bool { evidence.contains(Self.statedToken) }
    func isExpired(at now: Date) -> Bool { expiresAt.map { $0 <= now } ?? false }
}
