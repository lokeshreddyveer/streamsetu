import Foundation

/// The identity of an edge: `(subject, predicate, object, qualifier)`. Many sources may claim the same edge; each claim is a fact.
struct MusicEdgeKey: Hashable, Codable, Sendable {
    var subject: MusicEntityID
    var predicate: MusicPredicate
    var object: MusicEntityID
    /// Part of the identity: the role, the character, a disc-position key; "" when none.
    var qualifier: String

    init(subject: MusicEntityID, predicate: MusicPredicate, object: MusicEntityID, qualifier: String = "") {
        self.subject = subject; self.predicate = predicate; self.object = object; self.qualifier = qualifier
    }
}

/// Small string attributes of an edge, with typed readers for the ones the app uses.
struct EdgeAttributes: Hashable, Codable, Sendable, ExpressibleByDictionaryLiteral {
    var values: [String: String]
    init(_ values: [String: String] = [:]) { self.values = values }
    init(dictionaryLiteral elements: (String, String)...) { values = Dictionary(elements, uniquingKeysWith: { $1 }) }

    subscript(key: String) -> String? { get { values[key] } set { values[key] = newValue } }
    var isEmpty: Bool { values.isEmpty }

    var characterName: String? { get { values["character"] } set { values["character"] = newValue } }
    var instrument: String? { get { values["instrument"] } set { values["instrument"] = newValue } }
    var creditOrder: Int? { get { values["creditOrder"].flatMap(Int.init) } set { values["creditOrder"] = newValue.map(String.init) } }
    var disc: Int? { get { values["disc"].flatMap(Int.init) } set { values["disc"] = newValue.map(String.init) } }
    var position: Int? { get { values["position"].flatMap(Int.init) } set { values["position"] = newValue.map(String.init) } }
    var dubLanguage: String? { get { values["dub"] } set { values["dub"] = newValue } }
    var versionKind: MusicVersionKind? { get { values["versionKind"].flatMap(MusicVersionKind.init(rawValue:)) } set { values["versionKind"] = newValue?.rawValue } }
}

/// A typed claim between two entities, with the aggregate of everything the store knows about it.
struct MusicEdge: Hashable, Codable, Sendable {
    var subject: MusicEntityID
    var predicate: MusicPredicate
    var object: MusicEntityID
    var qualifier: String
    var attributes: EdgeAttributes
    /// 0...1, aggregated from the claims. The store sets it; a caller's value is only a hint for the first claim.
    var confidence: Float
    var status: EdgeStatus
    var creditLevel: CreditLevel
    /// Retracted by contradicting evidence or by the person; kept so it is not inferred again.
    var tombstone: Bool
    /// Display order within the subject's edges of this predicate (billing order, track position), nil when unordered.
    var order: Int?

    init(subject: MusicEntityID, predicate: MusicPredicate, object: MusicEntityID, qualifier: String = "", attributes: EdgeAttributes = [:],
         confidence: Float = 0, status: EdgeStatus = .inferred, creditLevel: CreditLevel = .unknown, tombstone: Bool = false, order: Int? = nil) {
        self.subject = subject; self.predicate = predicate; self.object = object; self.qualifier = qualifier; self.attributes = attributes
        self.confidence = confidence; self.status = status; self.creditLevel = creditLevel; self.tombstone = tombstone; self.order = order
    }

    /// Convenience for a role-qualified credit (`performedBy` with role singer, and so on).
    init(subject: MusicEntityID, predicate: MusicPredicate, object: MusicEntityID, role: MusicRole, attributes: EdgeAttributes = [:],
         creditLevel: CreditLevel = .unknown, order: Int? = nil) {
        self.init(subject: subject, predicate: predicate, object: object, qualifier: role.rawValue, attributes: attributes, creditLevel: creditLevel, order: order)
    }

    var key: MusicEdgeKey { MusicEdgeKey(subject: subject, predicate: predicate, object: object, qualifier: qualifier) }
    var role: MusicRole? { qualifier.isEmpty ? nil : MusicRole(rawValue: qualifier) }
}

/// One edge plus the claim that supports it, for batch ingest.
struct MusicEdgeClaim: Sendable {
    var edge: MusicEdge
    var provenance: MusicProvenance
    init(_ edge: MusicEdge, _ provenance: MusicProvenance) { self.edge = edge; self.provenance = provenance }
}

/// Sources that draw on the same underlying data count as one witness. Three catalogues repeating one label's credit are not three confirmations, and
/// Wikipedia and Wikidata share their editors. A source with no entry stands alone.
enum MusicSourceFamily {
    static func of(_ s: MusicSourceID) -> String {
        switch s.rawValue {
        case "jiosaavn", "appleMusic", "ytMusic", "deezer", "spotify", "audius", "graph", "provider": "catalogue"
        case "wikidata", "wikipedia": "wikimedia"
        case "musicbrainz", "listenbrainz": "musicbrainz"
        default: s.rawValue
        }
    }
}

/// The pure rules that turn many claims into one confidence and one status (section 1.3).
enum MusicEdgeAggregator {
    struct Result: Equatable, Sendable { var confidence: Float; var status: EdgeStatus; var tombstone: Bool }

    /// The default strength of a claim that carries no score of its own.
    static func defaultScore(_ f: MusicProvenance) -> Float {
        if f.userOverride { return 1 }
        switch f.source.rank { case 5: return 0.95; case 4: return 0.9; case 3: return 0.8; case 2: return 0.6; default: return 0.5 }
    }

    /// Verified needs an authoritative source asserting the edge and nobody of equal or higher rank contradicting it. For soundtrack and
    /// song-in-film links the source must also STATE the link (or be the person): a matcher or a provider's wording only ever gives `inferred`.
    static func aggregate(predicate: MusicPredicate, facts: [MusicProvenance], now: Date = Date()) -> Result {
        let live = facts.filter { !$0.isExpired(at: now) }
        let asserts = live.filter { $0.stance == .asserts }
        let denies = live.filter { $0.stance == .contradicts }
        let topAssert = asserts.map { $0.userOverride ? 9 : $0.source.rank }.max() ?? -1
        let topDeny = denies.map { $0.userOverride ? 9 : $0.source.rank }.max() ?? -1

        if asserts.isEmpty { return Result(confidence: 0, status: .inferred, tombstone: !denies.isEmpty) }
        if topDeny > topAssert { return Result(confidence: 0, status: .inferred, tombstone: true) }

        // One witness per family of sources: the strongest claim of each family counts, so copied data cannot add up to false certainty.
        var strongest: [String: Float] = [:]
        for f in asserts {
            // A claim that names its own upstream (a label or distributor) is a witness of its own; otherwise it counts with the family of its source.
            let lineage = f.evidence.first { $0.hasPrefix("lineage:") }.map { "lineage:" + MusicText.normalize(String($0.dropFirst(8))) }
            let family = f.userOverride ? "user" : (lineage ?? MusicSourceFamily.of(f.source))
            strongest[family] = max(strongest[family] ?? 0, min(1, max(0, f.score ?? defaultScore(f))))
        }
        let miss = strongest.values.reduce(Float(1)) { $0 * (1 - $1) }
        var confidence = 1 - miss

        let conflicted = topDeny == topAssert && topDeny >= 0
        let qualifies: (MusicProvenance) -> Bool = { f in
            if f.userOverride { return true }
            guard f.source.isAuthoritative else { return false }
            return predicate.requiresStatement ? f.statesLink : true
        }
        let verified = asserts.contains(where: qualifies)
        let status: EdgeStatus = conflicted ? .conflicted : (verified ? .verified : .inferred)
        confidence = status == .verified ? min(1, confidence) : min(0.99, confidence)
        if status == .conflicted { confidence = min(confidence, 0.6) }
        return Result(confidence: confidence, status: status, tombstone: false)
    }
}
