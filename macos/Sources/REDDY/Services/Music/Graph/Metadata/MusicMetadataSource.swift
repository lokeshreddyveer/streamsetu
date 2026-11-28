import Foundation

// Licence posture: non-commercial; revisit before any paid release. (The owner's rule: StreamSetu is not used commercially, so TMDB, MusicBrainz
// genres and tags (CC BY-NC-SA), Discogs and Last.fm may be used with their attribution kept in provenance. Revisit every source term before a paid release.)
//
// The metadata layer's shared vocabulary (graph design section 3.2). A source never mints ids and never returns a UI model: it returns drafts
// (entities with the ids and names a source knows) and edge claims between drafts, each with its provenance. Only the resolver maps drafts to ids.

/// How a claim names an entity before ids exist: an id the graph already has, an external id, or a key that is only valid inside one batch.
enum MusicDraftRef: Hashable, Sendable {
    case known(MusicEntityID)
    case external(MusicEntityKind, ExternalID)
    case local(MusicEntityKind, String)

    var kind: MusicEntityKind {
        switch self { case .known(let id): id.kind; case .external(let k, _): k; case .local(let k, _): k }
    }
}

struct MusicSourceDraft: Sendable {
    var ref: MusicDraftRef
    var entity: MusicEntityDraft
    init(_ ref: MusicDraftRef, _ entity: MusicEntityDraft) { self.ref = ref; self.entity = entity }
}

/// One claimed edge between two drafts. The batch supplies source, time and licence; the claim supplies how sure and why.
struct MusicClaimDraft: Sendable {
    var subject: MusicDraftRef
    var predicate: MusicPredicate
    var object: MusicDraftRef
    var role: MusicRole?
    var attributes: EdgeAttributes = [:]
    var order: Int?
    var creditLevel: CreditLevel = .unknown
    var confidence: Float = 0.9
    var evidence: [String] = []
    /// The source says the link in so many words (the only way a soundtrack or song-in-film edge can become verified).
    var stated = false
    var stance: Stance = .asserts
    var sourceRef: String?
    /// A claim whose licence differs from its batch's (MusicBrainz genres are CC BY-NC-SA while its core data is CC0).
    var license: SourceLicense?
    /// Per-fact attribution shown where the fact is displayed ("MusicBrainz", "Wikipedia", "IMDb", "TMDB"). Stored on the edge as `attribution`.
    var attribution: String?
}

/// "Looked, found nothing": remembered for a short time so the same question is not asked again.
struct MusicNegativeResult: Sendable, Hashable {
    var facet: String
    var key: String
    var ttl: TimeInterval = 7 * 86_400
}

/// Everything one fetch learned.
struct MusicClaimBatch: Sendable {
    var source: MusicSourceID
    var license: SourceLicense
    var retrievedAt: Date
    /// How long the facts may be kept (TMDB text: 30 days); becomes each fact's expiry.
    var retention: TimeInterval?
    /// Shown by the UI wherever these facts appear ("TMDB"); recorded on every edge and entity the batch writes.
    var attribution: String?
    var drafts: [MusicSourceDraft] = []
    var claims: [MusicClaimDraft] = []
    var negatives: [MusicNegativeResult] = []
    /// Follow-ups the source suggests (bounded).
    var next: [MusicSourceRequest] = []
    /// Image paths a source offered (TMDB profile or poster paths, Cover Art Archive addresses), by draft ref. Transient: never written to the graph.
    var imageHints: [MusicDraftRef: String] = [:]
    /// Candidates of a search: scored by the resolver, never written as facts.
    var isSearch = false
    /// Served from a memory of an earlier reply because the network failed.
    var stale = false

    init(source: MusicSourceID, license: SourceLicense, retrievedAt: Date = Date(), retention: TimeInterval? = nil, attribution: String? = nil) {
        self.source = source; self.license = license; self.retrievedAt = retrievedAt; self.retention = retention; self.attribution = attribution
    }

    var isEmpty: Bool { drafts.isEmpty && claims.isEmpty }
    func draft(_ ref: MusicDraftRef) -> MusicSourceDraft? { drafts.first { $0.ref == ref } }
}

/// A question for one source: a facet name and plain string parameters. `key` is what single-flight and caches compare.
struct MusicSourceRequest: Hashable, Sendable {
    var source: MusicSourceID
    var facet: String
    var params: [String: String]

    init(_ source: MusicSourceID, _ facet: String, _ params: [String: String] = [:]) { self.source = source; self.facet = facet; self.params = params }

    var key: String {
        source.rawValue + "|" + facet + "|" + params.sorted { $0.key < $1.key }.map { $0.key + "=" + MusicGraphText.fold($0.value) }.joined(separator: "&")
    }

    func param(_ k: String) -> String? { params[k].flatMap { $0.isEmpty ? nil : $0 } }
}

/// Facet names (the `cache_state.facet` column uses them too).
enum MusicFacet {
    static let recordingByISRC = "recordingByISRC"
    static let recordingSearch = "recordingSearch"
    static let recordingCredits = "recordingCredits"
    static let releaseGroupSearch = "releaseGroupSearch"
    static let releaseGroup = "releaseGroup"
    static let releaseTracklist = "releaseTracklist"
    static let workCredits = "workCredits"
    static let artist = "artist"
    static let filmSearch = "filmSearch"
    static let filmCredits = "filmCredits"
    static let personFilmography = "personFilmography"
    static let entityLinks = "entityLinks"
    static let recordingMetadata = "recordingMetadata"
    static let similarArtists = "similarArtists"
    static let providerCredits = "providerCredits"
    static let coverArt = "coverArt"
    static let reverseLookup = "reverseLookup"
    static let people = "people"
}

/// What a source costs and promises (section 3.3 and 3.8): its hosts, pacing, licence, retention, attribution and the sentence the person reads.
struct MusicSourcePolicy: Sendable {
    var hosts: [String]
    var license: SourceLicense
    var retention: TimeInterval?
    var attribution: String?
    /// Per facet, how long a fetched answer stays fresh.
    var ttl: [String: TimeInterval]
    var defaultTTL: TimeInterval
    /// On for a person who gave consent (the owner rule: sources start on). False only for Discogs.
    var defaultOn: Bool
    /// What is sent and to whom, in one plain sentence; shown in the Settings info popover.
    var privacyNote: String

    func ttl(for facet: String) -> TimeInterval { ttl[facet] ?? defaultTTL }
}

struct MusicFetchContext: Sendable {
    var now: @Sendable () -> Date = { Date() }
    var background = false
    init(now: @escaping @Sendable () -> Date = { Date() }, background: Bool = false) { self.now = now; self.background = background }
}

protocol MusicMetadataSource: Sendable {
    var id: MusicSourceID { get }
    var policy: MusicSourcePolicy { get }
    func fetch(_ request: MusicSourceRequest, context: MusicFetchContext) async throws -> MusicClaimBatch
}

enum MusicSourceError: Error, Equatable, Sendable {
    /// The source does not know this facet.
    case unsupported(String)
    /// A required parameter is missing.
    case badRequest(String)
    /// The source is off, unconfigured or gated.
    case disabled
    /// The host refused automated clients (a challenge page, 403): the source switches itself off for a while.
    case blocked
}

/// The HTTP seam of the sources: one `get`. Production wraps `MusicHTTP` behind the governor; tests answer from fixtures.
protocol MusicMetadataTransport: Sendable {
    func get(_ url: URL, query: [String: String], headers: [String: String]) async throws -> Data
}

extension MusicMetadataTransport {
    func get(_ url: URL, query: [String: String] = [:]) async throws -> Data { try await get(url, query: query, headers: [:]) }
}

/// Small shared helpers for sources and parsers.
enum MusicSourceKit {
    /// Facet node for a genre, mood or language name: one controlled key per folded name.
    static func facetDraft(_ kind: MusicEntityKind, _ name: String) -> MusicSourceDraft {
        let key = MusicGraphText.fold(name)
        return MusicSourceDraft(.local(kind, key), MusicEntityDraft(kind: kind, name: MusicTitleCase.capitalized(name)))
    }

    /// The User-Agent every metadata request carries: the app and its version plus the project address that `MusicHTTP` already sends. Never a
    /// personal address or name (MusicBrainz asks for a contact; the project page is that contact).
    static var userAgent: String {
        let v = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "1.0"
        return "StreamSetuMusic/\(v) (+https://github.com/lokeshreddyveerabhadra/streamsetu)"
    }
    static var headers: [String: String] { ["User-Agent": userAgent, "Accept": "application/json"] }

    /// `Date` of an ISO date or year string, as a year.
    static func year(_ s: String?) -> Int? { MusicGraphAdapters.year(s) }

    static func json(_ data: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }

    static func string(_ v: Any?) -> String? { (v as? String).flatMap { $0.isEmpty ? nil : $0 } }

    /// 2-letter ISO 639-1 where there is one, else the 3-letter code, lower case; nil for an empty or "mul"/"zxx"/"und" value.
    static func language(_ code: String?) -> String? {
        guard let c = code?.lowercased(), !c.isEmpty, !["mul", "zxx", "und"].contains(c) else { return nil }
        let map = ["hin": "hi", "tel": "te", "tam": "ta", "mal": "ml", "kan": "kn", "ben": "bn", "mar": "mr", "pan": "pa", "guj": "gu", "eng": "en",
                   "kor": "ko", "jpn": "ja", "urd": "ur", "spa": "es", "fra": "fr", "deu": "de", "zho": "zh", "ara": "ar", "tur": "tr"]
        return map[c] ?? c
    }
}
