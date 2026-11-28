import Foundation

// Related people for every role that has no page of its own for them (a lyricist, a producer, an instrumentalist, a conductor): people credited in the same role
// on songs of the people this person worked with most. Only credits the graph holds; two songs in common at least; nothing is guessed from style.

extension MusicPersonReader {
    /// People with one of `roles` credited on the songs of the top collaborators (three people, twenty songs each), ranked by the songs they share.
    func relatedPeers(through top: [MusicCollaborator], roles: Set<MusicRole>) async -> [MusicPersonEntry] {
        var obs: [MusicCreditObservation] = []
        for c in top.prefix(3) {
            if Task.isCancelled { break }
            var works = Set<MusicEntityID>()
            for p in [MusicPredicate.composedBy, .musicDirectedBy, .performedBy] {
                for e in await incoming(c.id, p, limit: 20) where Self.songKinds.contains(e.subject.kind) { works.insert(e.subject) }
            }
            for w in works.sorted().prefix(20) {
                for e in await outgoing(w) where MusicPersonRoles.counts(e) && e.object.kind.isAgent && e.object != person {
                    if let r = MusicPersonRoles.effectiveRole(e), roles.contains(r) {
                        obs.append(MusicCreditObservation(work: w, agent: e.object, role: r, level: .song, confidence: e.confidence))
                    }
                }
            }
        }
        let ranked = MusicCollaboration.rank(obs, excluding: [person], minCount: 2, limit: 12)
        return await collaboratorEntries(ranked) { .sharedCollaborators($0.workCount) }
    }
}
