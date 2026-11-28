import Foundation

/// A person's Wikidata id, found once by the page's strict name lookup, is kept on the person (through the same resolver that every other id goes through), so the
/// next visit, the filmography, the timeline and the picture lookup all start from the id instead of each searching the name again with its own rules.
enum MusicPersonIdentityLink {
    /// Records `qid` on `person` unless it already holds a Wikidata id. Silent: the page never waits for it, and nothing is written when the resolver is not up.
    static func remember(qid: String, person: MusicEntityID, name: String, isGroup: Bool, year: Int?, hasWikidata: Bool) async {
        guard !hasWikidata, MusicPersonWikidataParser.isQID(qid), let resolver = MusicFilmGraphLink.shared.resolver else { return }
        var batch = MusicClaimBatch(source: .wikidata, license: .cc0, retrievedAt: Date())
        let ref = MusicDraftRef.known(person)
        batch.drafts.append(MusicSourceDraft(ref, MusicEntityDraft(kind: isGroup ? .group : .person, name: name, year: year, externalIDs: [ExternalID(.wikidata, qid)])))
        _ = try? await resolver.ingest(batch, bind: [ref: person])
    }
}
