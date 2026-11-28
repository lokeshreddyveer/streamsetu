import Foundation

/// The people a person has worked with, drawn as a network: the person in the middle and their most frequent collaborators around them, each with how many
/// works they share. It reads only credits the graph holds (every musical role on the person's works) and says how many works it looked at.
struct MusicCollaboratorNetwork: Equatable, Sendable {
    struct Node: Equatable, Sendable, Identifiable { var id: MusicEntityID; var name: String; var kind: MusicEntityKind; var shared: Int }
    var center: MusicEntityID
    var centerName: String
    var nodes: [Node]
    var worksChecked: Int

    static let maxNodes = 12

    static func load(for person: MusicEntityID, store: any MusicGraphStoring) async -> MusicCollaboratorNetwork? {
        guard let snap = try? await store.entity(person) else { return nil }
        let reader = MusicPersonReader(store: store, person: person)
        // The person's works under every musical view, each counted once.
        var works: [MusicEntityID] = []
        var seen = Set<MusicEntityID>()
        for view in [MusicPersonView.singer, .composer, .lyricist, .producer, .instrumentalist] {
            for w in await reader.works(view: view, kinds: MusicPersonReader.songKinds, cap: 60) where seen.insert(w.snap.id).inserted { works.append(w.snap.id) }
        }
        let roles = Set(MusicRole.allCases.filter(\.isMusical))
        let observed = await reader.observations(of: Array(works.prefix(120)), roles: roles, releaseLevel: false, filmLevel: false)
        let ranked = MusicCollaboration.rank(observed, excluding: [person], limit: maxNodes)
        var nodes: [Node] = []
        for c in ranked {
            guard let s = await reader.snapshot(c.id) else { continue }
            nodes.append(Node(id: s.id, name: s.name, kind: s.kind, shared: c.workCount))
        }
        return MusicCollaboratorNetwork(center: snap.id, centerName: snap.name, nodes: nodes, worksChecked: min(works.count, 120))
    }
}
