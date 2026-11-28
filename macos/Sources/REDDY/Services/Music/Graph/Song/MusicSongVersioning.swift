import Foundation

// The song page's answer to "which recording is this": original or a cover, remix, live, re-recording, karaoke... and of what (items 2, 10 and 11).
// Pure and Foundation-only. The evidence order is: a graph edge (`alternateOf` with its version kind), then what the entity row already says, then the
// words of the title. A title alone only ever gives an INFERRED kind and never a link to an original: nothing here is invented.

/// What kind of recording a song is and what it is a version of.
struct MusicSongVersion: Hashable, Sendable {
    enum Source: String, Sendable { case edge, snapshot, title, none }

    var kind: MusicVersionKind
    /// The recording this one is a version of, when an edge says so. Nil for an original and for a kind known from words only.
    var originalID: MusicEntityID?
    var status: EdgeStatus
    var confidence: Float
    var evidence: [String]
    var source: Source

    static let unknown = MusicSongVersion(kind: .unknown, originalID: nil, status: .inferred, confidence: 0, evidence: [], source: .none)

    /// Original and unknown recordings carry no badge; every other kind does.
    var showsBadge: Bool { switch kind { case .original, .unknown: false; default: true } }
    /// The page links to the original only for a real version with an edge that names it.
    var linksToOriginal: Bool { originalID != nil && showsBadge }
    /// A kind that is not stated by an authoritative source reads "Possibly ...".
    var isInferred: Bool { status != .verified }
    var isOriginal: Bool { kind == .original }
}

/// One other recording shown on the page, with how it relates to this one.
struct MusicSongVersionItem: Hashable, Sendable, Identifiable {
    enum Relation: Int, Sendable { case original = 0, version, sibling }

    var id: MusicEntityID
    var name: String
    var year: Int?
    var kind: MusicVersionKind
    var status: EdgeStatus
    var confidence: Float
    var relation: Relation
    var artistLine: String?
    var imageRef: String?
    var durationMs: Int?

    init(id: MusicEntityID, name: String, year: Int? = nil, kind: MusicVersionKind, status: EdgeStatus = .inferred, confidence: Float = 0,
         relation: Relation, artistLine: String? = nil, imageRef: String? = nil, durationMs: Int? = nil) {
        self.id = id; self.name = name; self.year = year; self.kind = kind; self.status = status; self.confidence = confidence
        self.relation = relation; self.artistLine = artistLine; self.imageRef = imageRef; self.durationMs = durationMs
    }
}

/// The versions of one kind, in display order.
struct MusicSongVersionGroup: Hashable, Sendable, Identifiable {
    var kind: MusicVersionKind
    var items: [MusicSongVersionItem]
    var id: String { kind.rawValue }
}

enum MusicSongVersioning {
    /// The order the groups appear in. Live recordings are not here: they have their own section (item 11).
    static let groupOrder: [MusicVersionKind] = [.original, .cover, .remix, .reRecording, .acoustic, .reprise, .instrumental, .karaoke, .translatedLyrics, .otherLanguage, .translatedSoundtrack, .dub, .unknown]

    private static func statusRank(_ s: EdgeStatus) -> Int { switch s { case .verified: 0; case .inferred: 1; case .conflicted: 2 } }

    /// Better first: verified before inferred before conflicted, then higher confidence, then a stable tie-break on the id.
    static func better(_ a: MusicEdge, _ b: MusicEdge) -> Bool {
        if statusRank(a.status) != statusRank(b.status) { return statusRank(a.status) < statusRank(b.status) }
        if a.confidence != b.confidence { return a.confidence > b.confidence }
        return a.object.rawValue < b.object.rawValue
    }

    /// The version of this recording. `outgoing` are the `alternateOf` edges whose subject is the recording (retracted ones are ignored).
    /// An outgoing edge reads "this recording is a <kind> of <object>"; one saying `original` is not a version and links to nothing.
    static func classify(snapshot: MusicEntitySnapshot, outgoing: [MusicEdge]) -> MusicSongVersion {
        let edges = outgoing.filter { $0.predicate == .alternateOf && $0.subject == snapshot.id && !$0.tombstone }
        let versions = edges.filter { ($0.attributes.versionKind ?? .unknown) != .original }.sorted(by: better)
        if let top = versions.first {
            let kind = top.attributes.versionKind ?? .unknown
            return MusicSongVersion(kind: kind, originalID: top.object, status: top.status, confidence: top.confidence, evidence: ["edge"], source: .edge)
        }
        if edges.contains(where: { $0.attributes.versionKind == .original }) {
            let e = edges.filter { $0.attributes.versionKind == .original }.sorted(by: better)[0]
            return MusicSongVersion(kind: .original, originalID: nil, status: e.status, confidence: e.confidence, evidence: ["edge"], source: .edge)
        }
        if let raw = snapshot.attrs["versionKind"], let k = MusicVersionKind(rawValue: raw), k != .unknown {
            let ev = (snapshot.attrs["versionEvidence"] ?? "").split(separator: ",").map(String.init)
            return MusicSongVersion(kind: k, originalID: nil, status: .inferred, confidence: 0.5, evidence: ev.isEmpty ? ["row"] : ev, source: .snapshot)
        }
        if let hint = MusicCreditsAdapter.versionHint(title: snapshot.name) {
            return MusicSongVersion(kind: hint.kind, originalID: nil, status: .inferred, confidence: 0.4, evidence: hint.evidence, source: .title)
        }
        return .unknown
    }

    /// Groups the other recordings by kind (live ones are returned by `liveItems`). Within a group: earliest year first, then name, then id.
    /// One recording appears once: when it reaches the page by several routes the strongest relation wins (original, then version, then sibling).
    static func group(_ items: [MusicSongVersionItem], excluding self_: MusicEntityID? = nil) -> [MusicSongVersionGroup] {
        let rows = dedupe(items, excluding: self_).filter { $0.kind != .live }
        let by = Dictionary(grouping: rows, by: { $0.kind })
        return groupOrder.compactMap { k in
            guard let list = by[k], !list.isEmpty else { return nil }
            return MusicSongVersionGroup(kind: k, items: list.sorted(by: order))
        }
    }

    /// Only recordings an edge (or the entity row) types as live. No live performance is ever guessed from a title here.
    static func liveItems(_ items: [MusicSongVersionItem], excluding self_: MusicEntityID? = nil) -> [MusicSongVersionItem] {
        dedupe(items, excluding: self_).filter { $0.kind == .live }.sorted(by: order)
    }

    static func dedupe(_ items: [MusicSongVersionItem], excluding self_: MusicEntityID? = nil) -> [MusicSongVersionItem] {
        var best: [MusicEntityID: MusicSongVersionItem] = [:]
        for i in items where i.id != self_ {
            if let cur = best[i.id] {
                if i.relation.rawValue < cur.relation.rawValue || (i.relation == cur.relation && i.confidence > cur.confidence) { best[i.id] = i }
            } else { best[i.id] = i }
        }
        return Array(best.values)
    }

    static func order(_ a: MusicSongVersionItem, _ b: MusicSongVersionItem) -> Bool {
        switch (a.year, b.year) {
        case let (x?, y?) where x != y: return x < y
        case (nil, _?): return false
        case (_?, nil): return true
        default: break
        }
        if a.name != b.name { return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending }
        return a.id.rawValue < b.id.rawValue
    }

    /// The English words of a kind's badge; the page translates them through `Localized` using these as the keys.
    static func badgeKey(_ kind: MusicVersionKind, inferred: Bool) -> String? {
        let base: String
        switch kind {
        case .original, .unknown: return nil
        case .cover: base = "Cover"
        case .remix: base = "Remix"
        case .live: base = "Live"
        case .reRecording: base = "Re-recording"
        case .karaoke: base = "Karaoke"
        case .instrumental: base = "Instrumental"
        case .reprise: base = "Reprise"
        case .dub: base = "Dubbed version"
        case .translatedLyrics: base = "Translated lyrics"
        case .otherLanguage: base = "Other language"
        case .translatedSoundtrack: base = "Translated soundtrack"
        case .acoustic: base = "Acoustic"
        }
        return inferred ? "Possibly " + base.lowercased() : base
    }

    /// The key of the line that links to the original ("Cover of ..."), nil when there is no original to link to.
    static func originalLineKey(_ v: MusicSongVersion) -> String? {
        guard v.linksToOriginal else { return nil }
        switch v.kind {
        case .cover: return "Cover of %1$@"
        case .remix: return "Remix of %1$@"
        case .live: return "Live version of %1$@"
        case .reRecording: return "Re-recording of %1$@"
        case .karaoke: return "Karaoke version of %1$@"
        case .instrumental: return "Instrumental of %1$@"
        case .reprise: return "Reprise of %1$@"
        case .dub: return "Dubbed version of %1$@"
        case .translatedLyrics: return "Translated lyrics of %1$@"
        case .otherLanguage: return "Other-language version of %1$@"
        case .translatedSoundtrack: return "Translated soundtrack of %1$@"
        case .acoustic: return "Acoustic version of %1$@"
        case .original, .unknown: return nil
        }
    }

    /// Title of a group heading.
    static func groupTitleKey(_ kind: MusicVersionKind) -> String {
        switch kind {
        case .original: "Original recording"
        case .cover: "Covers"
        case .remix: "Remixes"
        case .reRecording: "Re-recordings"
        case .acoustic: "Acoustic versions"
        case .reprise: "Reprises"
        case .instrumental: "Instrumentals"
        case .karaoke: "Karaoke"
        case .dub: "Dubbed versions"
        case .translatedLyrics: "Translated lyrics"
        case .otherLanguage: "Other-language versions"
        case .translatedSoundtrack: "Translated soundtracks"
        case .live: "Live performances"
        case .unknown: "Other recordings"
        }
    }
}
