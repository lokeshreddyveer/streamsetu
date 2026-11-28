import Foundation

/// The two-signal merge rule (section 3.4 item 6) as a pure helper: merging two entities needs either one shared strong id, or at least two
/// independent signals from different families at a combined score of 0.85 or more, and no blocker. A name alone never merges, and never for a person.
enum MusicMergeRule {
    enum Family: String, Sendable, CaseIterable, Hashable { case name, creditOverlap, workOverlap, date, duration, externalIDAdjacency }

    enum Blocker: String, Sendable, Hashable {
        case differentStrongIDSameScheme, lifeYearsApart, durationApart, filmYearsApart, noMergeDecision, languageCountry
    }

    struct Signal: Sendable, Hashable {
        var family: Family
        var score: Float
        init(_ family: Family, _ score: Float) { self.family = family; self.score = score }
    }

    struct Evidence: Sendable {
        var kind: MusicEntityKind
        var sharedStrongID = false
        var signals: [Signal] = []
        var blockers: Set<Blocker> = []
        init(kind: MusicEntityKind, sharedStrongID: Bool = false, signals: [Signal] = [], blockers: Set<Blocker> = []) {
            self.kind = kind; self.sharedStrongID = sharedStrongID; self.signals = signals; self.blockers = blockers
        }
    }

    enum Decision: Equatable, Sendable {
        /// At least 0.85 with two families, or a shared strong id: link or merge, status `inferred` unless a strong id says otherwise.
        case merge
        /// 0.60 to 0.85, or one family only: keep as a low-confidence candidate (0.6), soft wording.
        case probable
        case reject
    }

    static let mergeThreshold: Float = 0.85
    static let probableThreshold: Float = 0.60

    static func decide(_ e: Evidence) -> Decision {
        if !e.blockers.isEmpty { return .reject }
        if e.sharedStrongID { return .merge }
        // Best score per family; the combined score is a noisy-or across families.
        var best: [Family: Float] = [:]
        for s in e.signals { best[s.family] = max(best[s.family] ?? 0, s.score) }
        let strong = best.filter { $0.value >= 0.5 }
        let combined = 1 - best.values.reduce(Float(1)) { $0 * (1 - min(1, max(0, $1))) }
        // A name is never enough by itself; for a person it never counts as one of the two signals either.
        let independent = strong.keys.filter { !(e.kind == .person && $0 == .name) }
        if independent.count >= 2, combined >= mergeThreshold { return .merge }
        if combined >= probableThreshold { return .probable }
        return .reject
    }

    /// The blockers that can be read off two entities' fields and strong ids. Credit and decision based blockers are added by the caller.
    static func blockers(kind: MusicEntityKind, strongIDsA: [ExternalID], strongIDsB: [ExternalID], yearA: Int?, yearB: Int?,
                         durationMsA: Int?, durationMsB: Int?, hasVersionEdge: Bool = false, namedNoMerge: Bool = false) -> Set<Blocker> {
        var out: Set<Blocker> = []
        let a = Dictionary(grouping: strongIDsA, by: \.scheme), b = Dictionary(grouping: strongIDsB, by: \.scheme)
        for (scheme, ids) in a {
            // Providers hand out many uids per item; only the catalogue schemes that are unique per entity can contradict.
            guard scheme != .provider, scheme != .localUUID, let other = b[scheme] else { continue }
            if Set(ids.map(\.value)).isDisjoint(with: other.map(\.value)) { out.insert(.differentStrongIDSameScheme) }
        }
        if let ya = yearA, let yb = yearB {
            if kind == .person, abs(ya - yb) > 2 { out.insert(.lifeYearsApart) }
            if kind == .film, abs(ya - yb) > 1 { out.insert(.filmYearsApart) }
        }
        if kind == .recording, !hasVersionEdge, let da = durationMsA, let db = durationMsB, da > 0, db > 0 {
            let hi = Double(max(da, db)), lo = Double(min(da, db))
            if (hi - lo) / hi > 0.25 { out.insert(.durationApart) }
        }
        if namedNoMerge { out.insert(.noMergeDecision) }
        return out
    }
}
