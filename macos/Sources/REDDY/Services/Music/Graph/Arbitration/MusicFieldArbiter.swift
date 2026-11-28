import Foundation

// Field-level evidence arbitration. Several sources can name different values for one fact (a song's language, its release year, who composed it). The arbiter
// weighs the evidence by how specific it is to the thing itself, how much that source is trusted for that field, whether the source states it outright and how
// fresh it is. Sources that draw on the same upstream data count as ONE witness. It returns every candidate with its reasons, and a winner only when the
// evidence is enough: otherwise the field stays unknown. Nothing here reads the network or the graph, so it is tested on its own.

/// The facts the arbiter decides.
enum MusicArbitratedField: String, Codable, CaseIterable, Sendable {
    case title, composer, lyricist, singer, performer, artwork, filmAssociation, language, releaseYear, region, soundtrackEdition, translation, franchise, raga, tala

    /// Fields that can have several true values at once (a song has several singers).
    var isMultiValued: Bool {
        switch self { case .composer, .lyricist, .singer, .performer, .raga, .tala, .translation: true; default: false }
    }

    /// Confidence a value needs before it is accepted.
    var minimumConfidence: Double {
        switch self {
        case .language, .releaseYear, .region, .filmAssociation, .soundtrackEdition, .franchise: 0.6
        case .raga, .tala: 0.7
        default: 0.55
        }
    }

    /// The least specific kind of evidence that can ever make a value verified. For facts about the song itself, a fact that holds for the whole film or
    /// album is context, not proof.
    var minimumSpecificity: MusicEvidenceSpecificity {
        switch self {
        case .language, .composer, .lyricist, .singer, .performer, .title, .raga, .tala, .translation: .release
        default: .film
        }
    }
}

/// How closely a piece of evidence is about the exact thing in question.
enum MusicEvidenceSpecificity: Int, Codable, Comparable, Sendable {
    case context = 0, film, release, recording
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

struct MusicFieldEvidence: Hashable, Codable, Sendable {
    var value: String
    var display: String
    var source: MusicSourceID
    /// The upstream the source says it took the fact from (a label or distributor), when it says so.
    var lineage: String?
    var specificity: MusicEvidenceSpecificity
    /// The credit names its role ("composer"), not a generic artist line.
    var roleExplicit: Bool
    /// The source states the fact in so many words.
    var states: Bool
    var retrievedAt: Date
    var userOverride: Bool

    init(value: String, display: String? = nil, source: MusicSourceID, lineage: String? = nil, specificity: MusicEvidenceSpecificity, roleExplicit: Bool = true,
         states: Bool = true, retrievedAt: Date = Date(), userOverride: Bool = false) {
        self.value = value; self.display = display ?? value; self.source = source; self.lineage = lineage; self.specificity = specificity
        self.roleExplicit = roleExplicit; self.states = states; self.retrievedAt = retrievedAt; self.userOverride = userOverride
    }

    /// The independent witness this evidence belongs to: the stated lineage, else the family of the source.
    var witness: String { userOverride ? "user" : (lineage.map { "lineage:" + MusicText.normalize($0) } ?? "family:" + MusicSourceFamily.of(source)) }
}

enum MusicFieldAuthority {
    /// How far a source is trusted for a field, 0...1. Authority is per field: a provider leads its own catalogue facts, MusicBrainz leads credits and identity,
    /// TMDB and Wikidata lead film facts. A source not listed gets a modest default.
    static func weight(_ field: MusicArbitratedField, _ source: MusicSourceID) -> Double {
        switch (field, source.rawValue) {
        case (_, "user"): return 1
        case (.composer, "musicbrainz"), (.lyricist, "musicbrainz"), (.singer, "musicbrainz"), (.performer, "musicbrainz"), (.title, "musicbrainz"): return 0.95
        case (.composer, "wikidata"), (.lyricist, "wikidata"), (.singer, "wikidata"): return 0.8
        case (.composer, "discogs"), (.lyricist, "discogs"), (.singer, "discogs"), (.performer, "discogs"): return 0.7
        case (.composer, "jiosaavn"), (.lyricist, "jiosaavn"), (.singer, "jiosaavn"): return 0.55
        case (.composer, "appleMusic"), (.lyricist, "appleMusic"), (.singer, "appleMusic"): return 0.5
        case (.filmAssociation, "tmdb"), (.filmAssociation, "wikidata"), (.releaseYear, "tmdb"), (.region, "wikidata"), (.franchise, "tmdb"), (.franchise, "wikidata"): return 0.9
        case (.filmAssociation, "imdb"), (.releaseYear, "imdb"): return 0.75
        case (.language, "musicbrainz"), (.releaseYear, "musicbrainz"), (.soundtrackEdition, "musicbrainz"), (.translation, "musicbrainz"): return 0.9
        case (.language, "jiosaavn"), (.language, "appleMusic"), (.releaseYear, "jiosaavn"), (.releaseYear, "appleMusic"), (.language, "provider"): return 0.6
        case (.language, "graph"), (.language, "film"): return 0.7
        case (.raga, "wikipedia"), (.raga, "wikidata"), (.tala, "wikidata"): return 0.8
        case (.raga, "saraga"), (.tala, "saraga"): return 0.9
        case (.artwork, "musicbrainz"), (.artwork, "coverart"): return 0.9
        case (.artwork, _): return 0.75
        default: return 0.5
        }
    }
}

struct MusicFieldCandidate: Hashable, Codable, Sendable, Identifiable {
    var value: String
    var display: String
    var sources: [String]
    /// The independent witnesses behind it (lineage or source family), after copies were folded together.
    var witnesses: [String]
    var confidence: Double
    /// The most specific evidence behind it.
    var specificity: MusicEvidenceSpecificity
    var id: String { value }
}

enum MusicFieldStatus: String, Codable, Sendable { case agreed, singleWitness, conflicted, insufficient, overridden, contextOnly, empty }

struct MusicFieldDecision: Hashable, Codable, Sendable {
    var field: MusicArbitratedField
    var candidates: [MusicFieldCandidate]
    /// The accepted values: one for a single-valued field, any number for a multi-valued one, none when the evidence is not enough.
    var winners: [String]
    var status: MusicFieldStatus
    var reason: String
    var decidedAt: Date

    var winner: String? { winners.first }
    /// Candidates that only context supports (the film's language for a song): shown, worded as possible, never verified.
    var contextOnly: [MusicFieldCandidate] { candidates.filter { $0.specificity < field.minimumSpecificity } }
}

enum MusicFieldArbiter {
    /// Evidence older than this loses a little of its strength; it is never thrown away.
    static let freshDays = 365.0
    static let margin = 0.15

    static func strength(_ e: MusicFieldEvidence, field: MusicArbitratedField, now: Date) -> Double {
        if e.userOverride { return 1 }
        let specificity: Double = switch e.specificity { case .recording: 1; case .release: 0.9; case .film: 0.6; case .context: 0.4 }
        let role = e.roleExplicit ? 1.0 : 0.6
        let said = e.states ? 1.0 : 0.8
        let age = max(0, now.timeIntervalSince(e.retrievedAt) / 86_400)
        let fresh = age <= freshDays ? 1.0 : max(0.85, 1 - (age - freshDays) / 3650)
        return MusicFieldAuthority.weight(field, e.source) * specificity * role * said * fresh
    }

    static func decide(field: MusicArbitratedField, evidence: [MusicFieldEvidence], now: Date = Date()) -> MusicFieldDecision {
        guard !evidence.isEmpty else {
            return MusicFieldDecision(field: field, candidates: [], winners: [], status: .empty, reason: "No source gave a value.", decidedAt: now)
        }
        var byValue: [String: [MusicFieldEvidence]] = [:]
        for e in evidence { byValue[e.value, default: []].append(e) }
        var candidates: [MusicFieldCandidate] = byValue.map { value, list in
            // One witness counts once, at its strongest claim: copies add nothing.
            var best: [String: Double] = [:]
            // Context-only evidence (a film's language for a song) never adds to a song-level value that has stronger evidence.
            let strong = list.filter { $0.specificity >= field.minimumSpecificity }
            for e in (strong.isEmpty ? list : strong) { best[e.witness] = max(best[e.witness] ?? 0, strength(e, field: field, now: now)) }
            let confidence = 1 - best.values.reduce(1.0) { $0 * (1 - $1) }
            return MusicFieldCandidate(value: value, display: list.first?.display ?? value, sources: Array(Set(list.map(\.source.rawValue))).sorted(),
                                       witnesses: best.keys.sorted(), confidence: confidence, specificity: list.map(\.specificity).max() ?? .context)
        }
        candidates.sort { $0.confidence != $1.confidence ? $0.confidence > $1.confidence : $0.value < $1.value }
        let now0 = now

        if let o = evidence.first(where: \.userOverride) {
            return MusicFieldDecision(field: field, candidates: candidates, winners: [o.value], status: .overridden, reason: "You set this value.", decidedAt: now0)
        }
        // Only evidence at least as specific as the field needs can make a value verified.
        let proven = candidates.filter { $0.specificity >= field.minimumSpecificity }
        if proven.isEmpty {
            return MusicFieldDecision(field: field, candidates: candidates, winners: [], status: .contextOnly,
                                      reason: "Only evidence about the film or album was found, which does not prove it for this song.", decidedAt: now0)
        }
        let accepted = proven.filter { $0.confidence >= field.minimumConfidence }
        if field.isMultiValued {
            guard !accepted.isEmpty else {
                return MusicFieldDecision(field: field, candidates: candidates, winners: [], status: .insufficient, reason: "No value reached the confidence needed (\(percent(field.minimumConfidence))).", decidedAt: now0)
            }
            let reason = accepted.map { "\($0.display): \($0.witnesses.count) independent witness\($0.witnesses.count == 1 ? "" : "es"), \(percent($0.confidence))" }.joined(separator: "; ")
            let status: MusicFieldStatus = accepted.allSatisfy { $0.witnesses.count == 1 } ? .singleWitness : .agreed
            return MusicFieldDecision(field: field, candidates: candidates, winners: accepted.map(\.value), status: status, reason: reason, decidedAt: now0)
        }
        guard let top = proven.first, top.confidence >= field.minimumConfidence else {
            return MusicFieldDecision(field: field, candidates: candidates, winners: [], status: .insufficient,
                                      reason: "The best value reached \(percent(proven.first?.confidence ?? 0)); \(percent(field.minimumConfidence)) is needed.", decidedAt: now0)
        }
        if proven.count > 1, let second = proven.dropFirst().first, second.confidence >= field.minimumConfidence, top.confidence - second.confidence < margin {
            return MusicFieldDecision(field: field, candidates: candidates, winners: [], status: .conflicted,
                                      reason: "\(top.display) (\(percent(top.confidence))) and \(second.display) (\(percent(second.confidence))) are too close to choose.", decidedAt: now0)
        }
        let status: MusicFieldStatus = top.witnesses.count > 1 ? .agreed : .singleWitness
        let why = "\(top.display): \(top.witnesses.count) independent witness\(top.witnesses.count == 1 ? "" : "es") (\(top.sources.joined(separator: ", "))), \(percent(top.confidence))"
        return MusicFieldDecision(field: field, candidates: candidates, winners: [top.value], status: status, reason: why, decidedAt: now0)
    }

    private static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
}
