import Foundation

/// One credit seen on one work: this agent had this role on this song, album or film. The raw material of every "worked with" list.
struct MusicCreditObservation: Hashable, Sendable {
    var work: MusicEntityID
    var agent: MusicEntityID
    var role: MusicRole
    var level: CreditLevel
    var confidence: Float
}

struct MusicCollaborator: Hashable, Sendable, Identifiable {
    var id: MusicEntityID
    var roles: [MusicRole]
    /// Distinct works they share with the page's person.
    var workCount: Int
    /// Song-level credits weigh more than album-level, album-level more than film-level.
    var weight: Double
    var sampleWorks: [MusicEntityID]
}

enum MusicCollaboration {
    static func levelWeight(_ l: CreditLevel) -> Double {
        switch l { case .song: 1.0; case .album: 0.7; case .film: 0.5; case .unknown: 0.4 }
    }

    /// Counts distinct works per agent, ignores the excluded ids (the person and their own groups), orders by weight, then count, then a stable
    /// key. The same agent in two roles on one work counts once for that work.
    static func rank(_ observations: [MusicCreditObservation], excluding: Set<MusicEntityID>, minCount: Int = 1, limit: Int = 24) -> [MusicCollaborator] {
        struct Acc { var works: [MusicEntityID: Double] = [:]; var order: [MusicEntityID] = []; var roles: Set<MusicRole> = [] }
        var acc: [MusicEntityID: Acc] = [:]
        for o in observations where !excluding.contains(o.agent) {
            var a = acc[o.agent] ?? Acc()
            let w = levelWeight(o.level) * Double(max(0.1, min(1, o.confidence == 0 ? 0.5 : o.confidence)))
            if let cur = a.works[o.work] { a.works[o.work] = max(cur, w) } else { a.works[o.work] = w; a.order.append(o.work) }
            a.roles.insert(o.role)
            acc[o.agent] = a
        }
        let all = acc.map { (id, a) in
            MusicCollaborator(id: id, roles: MusicRole.allCases.filter { a.roles.contains($0) }, workCount: a.works.count, weight: a.works.values.reduce(0, +),
                              sampleWorks: Array(a.order.prefix(3)))
        }
        return all.filter { $0.workCount >= minCount }
            .sorted { a, b in
                if a.workCount != b.workCount { return a.workCount > b.workCount }
                if abs(a.weight - b.weight) > 0.0001 { return a.weight > b.weight }
                return a.id < b.id
            }
            .prefix(limit).map { $0 }
    }
}
