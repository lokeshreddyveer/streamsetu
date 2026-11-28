import Foundation

// What the artwork resolver is asked about, and what it answers with. Pure values: no UI, no network, no database. Shared with iOS.

/// The jobs a person can have, as far as a picture lookup cares: they decide which description words make a candidate the right person.
enum MusicArtworkRole: String, Sendable, Hashable, CaseIterable {
    case singer, composer, lyricist, actor, director, group

    /// Words that, found in a source's one-line description of someone ("Indian actor and music director"), fit this job.
    var words: [String] {
        switch self {
        case .singer: ["singer", "playback", "vocalist", "musician", "recording artist", "rapper"]
        case .composer: ["composer", "music director", "music producer", "musician", "songwriter", "arranger", "record producer", "conductor", "score"]
        case .lyricist: ["lyricist", "songwriter", "poet", "writer"]
        case .actor: ["actor", "actress", "voice actor", "film actor", "television actor"]
        case .director: ["director", "filmmaker", "film producer", "screenwriter"]
        case .group: ["band", "duo", "group", "trio", "ensemble", "orchestra", "musical"]
        }
    }

    /// Any creative job, for a person whose own job is not known.
    static let anyWords: [String] = ["musician", "singer", "composer", "actor", "actress", "director", "songwriter", "lyricist", "filmmaker", "band", "producer",
                                     "poet", "screenwriter", "rapper", "vocalist", "music director", "conductor", "duo", "orchestra"]

    init?(role: MusicRole) {
        switch role {
        case .singer, .performer, .featured, .instrumentalist: self = .singer
        case .composer, .musicDirector, .arranger, .conductor, .remixer, .producer: self = .composer
        case .lyricist, .writer: self = .lyricist
        case .actor: self = .actor
        case .director, .screenwriter: self = .director
        default: return nil
        }
    }
}

/// One thing that needs a picture: a person, group, film, album, song, playlist, genre, language and so on. It carries what the resolver may
/// use to find the right one and to refuse a wrong one (names of works, jobs, ids the graph already knows).
struct MusicArtworkSubject: Hashable, Sendable {
    var kind: MusicEntityKind
    /// The graph id when there is one (a provisional id built from a provider uid counts).
    var id: MusicEntityID?
    var name: String
    var year: Int?
    var roles: [MusicArtworkRole]
    /// The main artist of a work (album, song, film's music director), as printed.
    var creator: String?
    /// Titles of works this subject made or is in (for a person: films and albums). Corroboration, at most four.
    var works: [String]
    var externalIDs: [ExternalID]
    /// The provider the card came from and its item id (`deezer`, `jiosaavn`...), when that is the only id there is.
    var providerID: String?
    var providerItemID: String?

    init(kind: MusicEntityKind, name: String, id: MusicEntityID? = nil, year: Int? = nil, roles: [MusicArtworkRole] = [], creator: String? = nil,
         works: [String] = [], externalIDs: [ExternalID] = [], providerID: String? = nil, providerItemID: String? = nil) {
        self.kind = kind; self.name = name; self.id = id; self.year = year; self.roles = roles; self.creator = creator
        self.works = Array(works.prefix(4)); self.externalIDs = externalIDs; self.providerID = providerID; self.providerItemID = providerItemID
    }

    /// The cache and single-flight key: the id when there is one, else kind, folded name, year and creator.
    var key: String {
        if let id { return id.rawValue }
        return [kind.slug, MusicArtworkMatch.key(name), year.map(String.init) ?? "", MusicArtworkMatch.key(creator ?? "")].joined(separator: "|")
    }

    var isPersonLike: Bool { kind.isAgent }
    var isFilmLike: Bool { kind == .film || kind == .series }
    var isAlbumLike: Bool { kind == .album || kind == .release }
    var isSongLike: Bool { kind == .recording || kind == .track || kind == .work }

    func externalID(_ scheme: ExternalID.Scheme) -> String? { externalIDs.first { $0.scheme == scheme }?.value }

    // MARK: convenience makers

    static func person(_ name: String, id: MusicEntityID? = nil, roles: [MusicArtworkRole] = [], works: [String] = []) -> MusicArtworkSubject {
        MusicArtworkSubject(kind: .person, name: name, id: id, roles: roles, works: works)
    }
    static func film(_ title: String, year: Int? = nil, id: MusicEntityID? = nil, creator: String? = nil) -> MusicArtworkSubject {
        MusicArtworkSubject(kind: .film, name: title, id: id, year: year, creator: creator)
    }
    static func album(_ title: String, creator: String? = nil, year: Int? = nil, id: MusicEntityID? = nil) -> MusicArtworkSubject {
        MusicArtworkSubject(kind: .album, name: title, id: id, year: year, creator: creator)
    }
    static func recording(_ title: String, creator: String? = nil, id: MusicEntityID? = nil) -> MusicArtworkSubject {
        MusicArtworkSubject(kind: .recording, name: title, id: id, creator: creator)
    }

    /// Letters for the circle or tile that stands in for a missing picture: initials for people, the first letter in its own script for a
    /// language, nothing for the rest (they get a glyph).
    var monogram: String? {
        switch kind {
        case .person, .group: return MusicArtworkMatch.initials(name)
        case .language: return name.first.map { String($0).uppercased() }
        default: return nil
        }
    }
}

// MARK: - answers

/// Which step of the chain gave a picture. A string, so a new source needs no change here.
struct MusicArtworkSourceID: Hashable, Codable, Sendable, RawRepresentable, ExpressibleByStringLiteral, CustomStringConvertible {
    var rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { rawValue = value }
    var description: String { rawValue }

    static let stored: MusicArtworkSourceID = "graph"
    static let relation: MusicArtworkSourceID = "relation"
    static let wikimedia: MusicArtworkSourceID = "wikimedia"
    static let coverArtArchive: MusicArtworkSourceID = "coverartarchive"
    static let tmdb: MusicArtworkSourceID = "tmdb"
    static let imdb: MusicArtworkSourceID = "imdb"
    static let deezer: MusicArtworkSourceID = "deezer"
    static let itunes: MusicArtworkSourceID = "itunes"
    static let jiosaavn: MusicArtworkSourceID = "jiosaavn"
}

/// A picture address a source offers, with how sure the source is that it is the right one and why.
struct MusicArtworkCandidate: Hashable, Sendable {
    var address: String
    var source: MusicArtworkSourceID
    /// 0...1. People need 0.75, works 0.70 (see `MusicArtworkMatch.minimumConfidence`).
    var confidence: Double
    /// Short tokens: "wikidata-id", "name+role", "title+year", "work:Master"...
    var evidence: [String]
    /// The line to show under a large picture when the licence asks for one.
    var credit: String?

    init(address: String, source: MusicArtworkSourceID, confidence: Double, evidence: [String] = [], credit: String? = nil) {
        self.address = address; self.source = source; self.confidence = confidence; self.evidence = evidence; self.credit = credit
    }
}

/// The chosen picture and where it came from. Kept on disk for 30 days.
struct MusicResolvedArtwork: Hashable, Codable, Sendable {
    var address: String
    var source: MusicArtworkSourceID
    var confidence: Double
    var evidence: [String]
    var credit: String?
    var resolvedAt: Date
    /// For a picture borrowed from a related thing (a film's soundtrack cover, a song's album cover): the name of that thing.
    var borrowedFrom: String?
}
