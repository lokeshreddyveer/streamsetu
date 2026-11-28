import Foundation

// What the song page is made of (the owner's 18 items) and the pure rules that decide what each block shows: which blocks exist, in which order, when a
// block is a skeleton, content, one quiet line or nothing, why a related song is listed, and how provider suggestions join the graph's own.
// Foundation-only. Nothing here reads the network or the player.

/// The graph-backed sections the model loads one by one. Each key is also the section key inside `MusicEntityModel`.
enum MusicSongSectionKey: String, CaseIterable, Sendable {
    case context, credits, versions, samples, related, moreBySinger, moreByComposer, films, playlists, similar
    var loaderKey: String { "song." + rawValue }
}

/// The blocks of the page in reading order (the 18 items grouped the way they are drawn).
enum MusicSongBlock: String, CaseIterable, Sendable {
    /// Items 1 to 4: artwork and play, title and version, album, film.
    case header
    /// Items 5 to 8.
    case credits
    /// Item 9.
    case lyrics
    /// Item 10.
    case versions
    /// Samples this song contains, and the songs that sample it.
    case samples
    /// Item 11.
    case live
    /// Item 12.
    case related
    /// Item 13.
    case moreBySinger
    /// Item 14.
    case moreByComposer
    /// Item 15.
    case films
    /// Item 16.
    case playlists
    /// Item 17.
    case similar
    /// Item 18.
    case sources

    /// What the page draws, in order. Four blocks are not drawn because another block already says the same thing: "live" is one kind of version
    /// (Versions lists it), the film is in the header (title line and View film), "similar" is a second Related list, and "in playlists" is a fact
    /// about the person's own library, not about the song.
    static let notDrawn: Set<MusicSongBlock> = [.live, .films, .similar, .playlists]
    static let order: [MusicSongBlock] = allCases.filter { !notDrawn.contains($0) }
}

enum MusicSongBlockState: Equatable, Sendable {
    /// A placeholder of the final height (no shift when the content lands).
    case skeleton
    case content
    /// One quiet line ("Not credited in the sources we checked"); only blocks that say so ask for it.
    case quietEmpty
    case hidden
}

enum MusicSongVisibility {
    /// What one block draws for the state of its section. A failure never shows an error banner (these sections are enrichment, not the page): with
    /// items they stay on screen, without they disappear.
    static func state(phase: MusicSectionPhase, itemCount: Int, quietWhenEmpty: Bool = false) -> MusicSongBlockState {
        switch phase {
        case .idle: return .skeleton
        case .loading, .partial: return itemCount > 0 ? .content : .skeleton
        case .loaded: return itemCount > 0 ? .content : (quietWhenEmpty ? .quietEmpty : .hidden)
        case .empty: return quietWhenEmpty ? .quietEmpty : .hidden
        case .failed: return itemCount > 0 ? .content : .hidden
        }
    }

    /// The block that is drawn nothing at all (so the page can skip its heading and spacing).
    static func isHidden(_ s: MusicSongBlockState) -> Bool { s == .hidden }

    /// Whether a block asks for the quiet "not credited" line when it has no data.
    static func quietWhenEmpty(_ b: MusicSongBlock) -> Bool { b == .credits }
}

// MARK: header context (items 3 and 4)

struct MusicSongLink: Hashable, Sendable, Identifiable {
    var id: MusicEntityID
    var name: String
    var year: Int?
    var subkind: String?
    var imageRef: String?
    /// "Awaara (1951)": two films of one title are told apart by year everywhere they are named.
    var displayName: String { year.map { name + " (" + String($0) + ")" } ?? name }
}

struct MusicSongFilmLink: Hashable, Sendable {
    enum Origin: String, Sendable { case direct, viaSoundtrack, titleHint }
    var film: MusicSongLink
    var status: EdgeStatus
    var confidence: Float
    var evidence: [String]
    var origin: Origin
    /// Not verified by a source that states it: the chip says "Inferred".
    var isInferred: Bool { status != .verified }
    /// A low-confidence hint (a "(From "Film")" title) is text, not a link: nothing about the film is claimed.
    var isPlainText: Bool { confidence < MusicSongContextRules.linkThreshold || origin == .titleHint }
}

struct MusicSongContext: Hashable, Sendable {
    var album: MusicSongLink?
    var film: MusicSongFilmLink?
    var version: MusicSongVersion
    /// The recording this one is a version of, when an edge names it (the header links to it).
    var original: MusicSongLink? = nil
    var year: Int?
    var language: String?
    var durationMs: Int?
    var explicit: Bool
    var isProvisional: Bool
}

enum MusicSongContextRules {
    /// Below this an edge to a film is shown as plain text only (section "incomplete metadata" of the design).
    static let linkThreshold: Float = 0.6

    /// The film for a song: its own `featuredIn` edge (best first), else the film of the album it is on through `soundtrackOf`. A link through the
    /// album is always inferred (a song is never assumed to be in a film without a statement), whatever the album edge says.
    static func pickFilm(direct: [MusicEdge], viaAlbum: [MusicEdge]) -> (edge: MusicEdge, origin: MusicSongFilmLink.Origin)? {
        let d = direct.filter { $0.predicate == .featuredIn && !$0.tombstone }.sorted(by: MusicSongVersioning.better)
        if let top = d.first {
            let hintOnly = top.status != .verified && top.confidence < linkThreshold
            return (top, hintOnly ? .titleHint : .direct)
        }
        let v = viaAlbum.filter { $0.predicate == .soundtrackOf && !$0.tombstone }.sorted(by: MusicSongVersioning.better)
        if var top = v.first { top.status = top.status == .conflicted ? .conflicted : .inferred; return (top, .viaSoundtrack) }
        return nil
    }

    /// The album a song is on: an `album` when the graph has one, else the release it is on; the best placement edge wins.
    static func pickAlbum(placements: [MusicEdge], kinds: (MusicEntityID) -> MusicEntityKind = { $0.kind }) -> MusicEdge? {
        let live = placements.filter { $0.predicate == .trackOn && !$0.tombstone }
        let albums = live.filter { kinds($0.object) == .album }.sorted(by: MusicSongVersioning.better)
        if let a = albums.first { return a }
        return live.sorted(by: MusicSongVersioning.better).first
    }
}

// MARK: related songs and reasons (items 12, 13, 14, 15, 17)

enum MusicSongReasonKind: String, Sendable, Hashable {
    case sameWork, sameAlbum, sameComposer, sameMusicDirector, sameWriter, sameFilm, samePerformer, sharedFacets, providerSuggestion, sharedContributor
}

struct MusicSongReason: Hashable, Sendable {
    var kind: MusicSongReasonKind
    var subject: String?
    /// Below 0.75 and not verified: the card says "Possibly related" (section 5.2 of the design).
    var possibly: Bool = false

    /// The English words with their one placeholder; the page passes the subject through `Localized.string(key, subject)`.
    var key: String {
        switch kind {
        case .sameWork: return "Another recording of this song"
        case .sameAlbum: return "Same album: %1$@"
        case .sameComposer: return "Same composer: %1$@"
        case .sameMusicDirector: return "Same music director: %1$@"
        case .sameWriter: return "Same writer: %1$@"
        case .sameFilm: return "From the film %1$@"
        case .samePerformer: return "Also performed by %1$@"
        case .sharedFacets: return "Shares %1$@"
        case .providerSuggestion: return "Suggested for this song"   // no source name on a Music page: the line says why, not where it came from
        case .sharedContributor: return "With %1$@"
        }
    }

    /// The band of the architecture's priority table (1 strongest, 9 weakest).
    var band: Int {
        switch kind {
        case .sameWork, .sameAlbum: 1
        case .sameComposer, .sameMusicDirector, .sameWriter: 2
        case .sameFilm: 3
        case .sharedContributor: 4
        case .samePerformer: 5
        case .sharedFacets: 6
        case .providerSuggestion: 8
        }
    }

    static let bandBase: [Int: Float] = [1: 1000, 2: 850, 3: 750, 4: 650, 5: 550, 6: 400, 7: 300, 8: 200, 9: 100]
    var base: Float { Self.bandBase[band] ?? 100 }
}

struct MusicSongRelatedItem: Hashable, Sendable, Identifiable {
    var id: MusicEntityID
    var name: String
    var year: Int?
    var imageRef: String?
    var artistLine: String?
    var reason: MusicSongReason
    /// Other reasons that also bring this song here (shown as "+2" in the tooltip, not as cards).
    var alsoCount: Int = 0
    var score: Float
    /// Set for a provider suggestion: the row to play and to show the cover of.
    var track: MusicTrack?
}

enum MusicSongRelated {
    /// The reason a neighbour at the far end of `(parent, predicate, direction)` is listed, or nil when that relation says nothing worth showing.
    /// `direction` is from the parent's side, as `MusicNeighbour` reports it: `.incoming` means the candidate points to the parent.
    static func reasonKind(parent: MusicEntityKind, predicate: MusicPredicate, direction: MusicEdgeDirection) -> MusicSongReasonKind? {
        guard direction == .incoming else { return nil }
        switch (parent, predicate) {
        case (.release, .trackOn), (.album, .trackOn): return .sameAlbum
        case (.film, .featuredIn), (.series, .featuredIn): return .sameFilm
        case (.work, .recordingOf): return .sameWork
        case (.person, .performedBy), (.group, .performedBy): return .samePerformer
        case (.person, .composedBy), (.group, .composedBy): return .sameComposer
        case (.person, .musicDirectedBy), (.group, .musicDirectedBy): return .sameMusicDirector
        case (.person, .writtenBy), (.group, .writtenBy): return .sameWriter
        default: return nil
        }
    }

    static func makeReason(_ kind: MusicSongReasonKind, subject: String?, confidence: Float, status: EdgeStatus) -> MusicSongReason {
        MusicSongReason(kind: kind, subject: subject, possibly: status != .verified && confidence < 0.75 && kind != .sameWork)
    }

    /// One item per candidate: the strongest reason wins (lower band, then higher confidence), the others are counted. Ordered by score, then name.
    static func rank(_ candidates: [(item: MusicSongRelatedItem, confidence: Float)]) -> [MusicSongRelatedItem] {
        var best: [MusicEntityID: MusicSongRelatedItem] = [:]
        for (c, conf) in candidates {
            var item = c
            item.score = item.reason.base + 100 * min(1, max(0, conf))
            if var cur = best[item.id] {
                if item.score > cur.score { item.alsoCount = cur.alsoCount + 1; best[item.id] = item } else { cur.alsoCount += 1; best[item.id] = cur }
            } else { best[item.id] = item }
        }
        return best.values.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.name != b.name { return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending }
            return a.id.rawValue < b.id.rawValue
        }
    }

    /// The graph's related songs plus the provider's own suggestions, deduplicated, graph first (a provider's idea never outranks a verified link).
    static func merge(graph: [MusicSongRelatedItem], provider: [MusicTrack], providerName: String, excluding: Set<MusicEntityID>,
                      selfName: String, limit: Int = 20) -> [MusicSongRelatedItem] {
        func key(_ title: String, _ artist: String?) -> String { MusicGraphText.latin(title) + "|" + MusicGraphText.latin(artist ?? "") }
        let selfKey = MusicGraphText.latin(selfName)
        var seenIDs = Set(graph.map(\.id)).union(excluding)
        var seenNames = Set(graph.map { key($0.name, $0.artistLine?.components(separatedBy: ", ").first) })
        var out = Array(graph.prefix(limit))
        var rank: Float = 0
        for t in provider where out.count < limit {
            let id = MusicEntityID.provisional(kind: .recording, providerUID: t.uid)
            let k = key(t.title, t.artists.first?.name)
            guard !seenIDs.contains(id), !seenNames.contains(k), MusicGraphText.latin(t.title) != selfKey else { continue }
            seenIDs.insert(id); seenNames.insert(k)
            rank += 1
            out.append(MusicSongRelatedItem(id: id, name: t.title, year: nil, imageRef: t.thumbnails.best(minSide: 300), artistLine: t.artistLine.isEmpty ? nil : t.artistLine,
                                            reason: MusicSongReason(kind: .providerSuggestion, subject: providerName), score: max(0, 200 - rank), track: t))
        }
        return out
    }

    // MARK: similar recordings (item 17)

    struct Facets: Sendable, Equatable {
        var language: Set<MusicEntityID> = [], era: Set<MusicEntityID> = [], genre: Set<MusicEntityID> = []
        var isEmpty: Bool { language.isEmpty && era.isEmpty && genre.isEmpty }
    }

    /// How many of the three facet kinds two recordings share, and which facet entities those are. A candidate needs at least two kinds in common.
    static func sharedFacets(_ a: Facets, _ b: Facets) -> (kinds: Int, shared: [MusicEntityID]) {
        let l = a.language.intersection(b.language), e = a.era.intersection(b.era), g = a.genre.intersection(b.genre)
        let kinds = [l, e, g].filter { !$0.isEmpty }.count
        return (kinds, (l.sorted() + e.sorted() + g.sorted()))
    }
    static let minimumSharedFacetKinds = 2

    // MARK: films of the credited people (item 15)

    /// Predicates that put a credited contributor in another film: they made its music, wrote for it, directed it or are in its cast.
    static func filmReasonKind(_ p: MusicPredicate) -> MusicSongReasonKind? {
        switch p {
        case .composedBy: .sameComposer
        case .musicDirectedBy: .sameMusicDirector
        case .writtenBy: .sameWriter
        case .hasCast, .directedBy, .producedBy, .performedBy: .sharedContributor
        default: nil
        }
    }
}

// MARK: playlists (item 16)

struct MusicSongPlaylistItem: Hashable, Sendable, Identifiable {
    enum Source: String, Sendable { case local, provider }
    var id: String
    var name: String
    var source: Source
    var entityID: MusicEntityID?
    var localID: UUID?
    var imageRef: String?
}

enum MusicSongPlaylists {
    struct LocalSummary: Sendable {
        var id: UUID
        var name: String
        var trackUIDs: [String]
        var created: Date
        init(id: UUID, name: String, trackUIDs: [String], created: Date = Date(timeIntervalSince1970: 0)) { self.id = id; self.name = name; self.trackUIDs = trackUIDs; self.created = created }
    }

    /// The person's own playlists that really contain this song (by any of its provider ids). Newest first. Nothing is guessed from names.
    static func local(containing uids: Set<String>, in playlists: [LocalSummary]) -> [MusicSongPlaylistItem] {
        guard !uids.isEmpty else { return [] }
        return playlists.filter { p in p.trackUIDs.contains(where: uids.contains) }
            .sorted { $0.created != $1.created ? $0.created > $1.created : $0.name < $1.name }
            .map { MusicSongPlaylistItem(id: "local:" + $0.id.uuidString, name: $0.name, source: .local, entityID: nil, localID: $0.id, imageRef: nil) }
    }

    /// Local first, then the graph's provider playlists by name; one entry per id.
    static func combine(local: [MusicSongPlaylistItem], provider: [MusicSongPlaylistItem]) -> [MusicSongPlaylistItem] {
        var seen = Set<String>(), out: [MusicSongPlaylistItem] = []
        for p in local + provider.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) where seen.insert(p.id).inserted { out.append(p) }
        return out
    }
}
