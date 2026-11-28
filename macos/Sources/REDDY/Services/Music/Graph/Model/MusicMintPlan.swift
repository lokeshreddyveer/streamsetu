import Foundation

/// An entity to create plus the entities it is linked to and the claims that link them, as an adapter reads them off an existing saved record.
/// Pure data: the index turns it into rows (one transaction for the entities, one for the claims).
struct MusicMintPlan: Sendable {
    struct Link: Sendable {
        var draft: MusicEntityDraft
        var predicate: MusicPredicate
        /// `.outgoing`: primary is the subject. `.incoming`: the linked entity is the subject (a person's credit read from the person's side).
        var direction: MusicEdgeDirection = .outgoing
        var role: MusicRole?
        var attributes: EdgeAttributes = [:]
        var order: Int?
        var creditLevel: CreditLevel = .unknown
        var score: Float?
        var evidence: [String] = []
    }
    var primary: MusicEntityDraft
    var links: [Link] = []
    /// Who the claims come from (a provider id, or tmdb/wikidata).
    var source: MusicSourceID
    var license: SourceLicense = .providerCache
    var retrievedAt: Date = Date()
    var expiresAt: Date?
    /// Used for links with no score of their own.
    var defaultScore: Float = 0.6
}
