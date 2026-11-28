import Foundation

enum MusicEntityState: Int, Codable, Sendable, Hashable { case live = 0, merged = 1, hidden = 2 }

/// A plain, immutable copy of one entity row. Pages and view models hold these, never a database handle.
struct MusicEntitySnapshot: Hashable, Codable, Sendable, Identifiable {
    var id: MusicEntityID
    var subkind: String?
    var name: String
    /// The folded Latin skeleton of `name` (same across spellings and scripts).
    var nameLatin: String
    var lang: String?
    var year: Int?
    var yearEnd: Int?
    var country: String?
    var durationMs: Int?
    var imageRef: String?
    /// Kind-specific fields as short strings.
    var attrs: [String: String]
    /// Minted from provider text or a name alone; a strong id has not arrived yet.
    var provisional: Bool
    var state: MusicEntityState
    /// Referenced by the library (likes, history, playlists...): never evicted.
    var pinned: Bool
    var mergedInto: MusicEntityID?
    var createdAt: Date
    var updatedAt: Date

    var kind: MusicEntityKind { id.kind }
}

/// What a writer hands the store to create or enrich an entity. Fields that are nil or empty never overwrite what the store already knows.
struct MusicEntityDraft: Sendable {
    var kind: MusicEntityKind
    var subkind: String?
    var name: String
    var lang: String?
    var year: Int?
    var yearEnd: Int?
    var country: String?
    var durationMs: Int?
    var imageRef: String?
    var attrs: [String: String]
    /// In order of authority: the FIRST id fixes the entity's stable id if it is new.
    var externalIDs: [ExternalID]
    var aliases: [NameAlias]
    var provisional: Bool
    var pinned: Bool

    init(kind: MusicEntityKind, name: String, subkind: String? = nil, lang: String? = nil, year: Int? = nil, yearEnd: Int? = nil, country: String? = nil,
         durationMs: Int? = nil, imageRef: String? = nil, attrs: [String: String] = [:], externalIDs: [ExternalID] = [], aliases: [NameAlias] = [],
         provisional: Bool = false, pinned: Bool = false) {
        self.kind = kind; self.name = name; self.subkind = subkind; self.lang = lang; self.year = year; self.yearEnd = yearEnd; self.country = country
        self.durationMs = durationMs; self.imageRef = imageRef; self.attrs = attrs; self.externalIDs = externalIDs; self.aliases = aliases
        self.provisional = provisional; self.pinned = pinned
    }

    /// The id the entity gets if it is new: from the first external id, else from the folded name (and year).
    var derivedID: MusicEntityID {
        if let first = externalIDs.first { return .provisional(kind: kind, externalID: first) }
        return .provisional(kind: kind, name: name, year: year)
    }
}

struct MusicUpsertResult: Sendable, Equatable {
    var id: MusicEntityID
    var created: Bool
    /// Strong ids the draft carried that already belong to a DIFFERENT entity. They were not attached; the resolver decides merge or conflict.
    var conflicts: [ExternalID]
}

// MARK: typed entity values

/// A typed view of a snapshot. Pure value types; building one checks the kind.
protocol MusicEntityNode: Hashable, Sendable {
    static var kind: MusicEntityKind { get }
    var snapshot: MusicEntitySnapshot { get }
    init?(snapshot: MusicEntitySnapshot)
}

extension MusicEntityNode {
    var id: MusicEntityID { snapshot.id }
    var name: String { snapshot.name }
}

private func checked(_ s: MusicEntitySnapshot, _ k: MusicEntityKind) -> MusicEntitySnapshot? { s.kind == k ? s : nil }

struct MusicPersonNode: MusicEntityNode {
    static let kind = MusicEntityKind.person
    var snapshot: MusicEntitySnapshot
    init?(snapshot: MusicEntitySnapshot) { guard let s = checked(snapshot, Self.kind) else { return nil }; self.snapshot = s }
    var birthYear: Int? { snapshot.year }
    var deathYear: Int? { snapshot.yearEnd }
    var country: String? { snapshot.country }
}

struct MusicGroupNode: MusicEntityNode {
    static let kind = MusicEntityKind.group
    var snapshot: MusicEntitySnapshot
    init?(snapshot: MusicEntitySnapshot) { guard let s = checked(snapshot, Self.kind) else { return nil }; self.snapshot = s }
    /// duo, band, orchestra, composerPair...
    var groupKind: String? { snapshot.subkind }
}

struct MusicFilmNode: MusicEntityNode {
    static let kind = MusicEntityKind.film
    var snapshot: MusicEntitySnapshot
    init?(snapshot: MusicEntitySnapshot) { guard let s = checked(snapshot, Self.kind) else { return nil }; self.snapshot = s }
    var year: Int? { snapshot.year }
    var originalLanguage: String? { snapshot.lang }
}

struct MusicSeriesNode: MusicEntityNode {
    static let kind = MusicEntityKind.series
    var snapshot: MusicEntitySnapshot
    init?(snapshot: MusicEntitySnapshot) { guard let s = checked(snapshot, Self.kind) else { return nil }; self.snapshot = s }
}

struct MusicReleaseNode: MusicEntityNode {
    static let kind = MusicEntityKind.release
    var snapshot: MusicEntitySnapshot
    init?(snapshot: MusicEntitySnapshot) { guard let s = checked(snapshot, Self.kind) else { return nil }; self.snapshot = s }
    /// Wording of the provider or source, never proof of a film link (that is a `soundtrackOf` edge with its own status).
    var isSoundtrack: Bool { snapshot.subkind == MusicAlbumSubkind.soundtrack.rawValue }
}

struct MusicAlbumNode: MusicEntityNode {
    static let kind = MusicEntityKind.album
    var snapshot: MusicEntitySnapshot
    init?(snapshot: MusicEntitySnapshot) { guard let s = checked(snapshot, Self.kind) else { return nil }; self.snapshot = s }
    var isSoundtrack: Bool { snapshot.subkind == MusicAlbumSubkind.soundtrack.rawValue }
    var albumSubkind: MusicAlbumSubkind? { snapshot.subkind.flatMap(MusicAlbumSubkind.init(rawValue:)) }
}

enum MusicAlbumSubkind: String, Codable, Sendable, CaseIterable { case album, ep, single, compilation, soundtrack, score }

struct MusicRecordingNode: MusicEntityNode {
    static let kind = MusicEntityKind.recording
    var snapshot: MusicEntitySnapshot
    init?(snapshot: MusicEntitySnapshot) { guard let s = checked(snapshot, Self.kind) else { return nil }; self.snapshot = s }
    var durationMs: Int? { snapshot.durationMs }
    var versionKind: MusicVersionKind? { snapshot.attrs["versionKind"].flatMap(MusicVersionKind.init(rawValue:)) }
}

struct MusicWorkNode: MusicEntityNode {
    static let kind = MusicEntityKind.work
    var snapshot: MusicEntitySnapshot
    init?(snapshot: MusicEntitySnapshot) { guard let s = checked(snapshot, Self.kind) else { return nil }; self.snapshot = s }
}

struct MusicTrackNode: MusicEntityNode {
    static let kind = MusicEntityKind.track
    var snapshot: MusicEntitySnapshot
    init?(snapshot: MusicEntitySnapshot) { guard let s = checked(snapshot, Self.kind) else { return nil }; self.snapshot = s }
}

struct MusicPlaylistNode: MusicEntityNode {
    static let kind = MusicEntityKind.playlist
    var snapshot: MusicEntitySnapshot
    init?(snapshot: MusicEntitySnapshot) { guard let s = checked(snapshot, Self.kind) else { return nil }; self.snapshot = s }
}

struct MusicGenreNode: MusicEntityNode {
    static let kind = MusicEntityKind.genre
    var snapshot: MusicEntitySnapshot
    init?(snapshot: MusicEntitySnapshot) { guard let s = checked(snapshot, Self.kind) else { return nil }; self.snapshot = s }
    /// The controlled slug (about 150 of them).
    var slug: String { snapshot.attrs["slug"] ?? snapshot.nameLatin }
}

struct MusicLanguageNode: MusicEntityNode {
    static let kind = MusicEntityKind.language
    var snapshot: MusicEntitySnapshot
    init?(snapshot: MusicEntitySnapshot) { guard let s = checked(snapshot, Self.kind) else { return nil }; self.snapshot = s }
    /// ISO 639-3 key: hin, tel, tam, mal, kan, kor, eng.
    var iso639: String { snapshot.attrs["iso639"] ?? snapshot.lang ?? "" }
}

struct MusicRegionNode: MusicEntityNode {
    static let kind = MusicEntityKind.region
    var snapshot: MusicEntitySnapshot
    init?(snapshot: MusicEntitySnapshot) { guard let s = checked(snapshot, Self.kind) else { return nil }; self.snapshot = s }
    /// ISO 3166-1 alpha-2 (IN), or an own sub-region key (IN-S).
    var code: String { snapshot.attrs["code"] ?? snapshot.country ?? "" }
}

struct MusicEraNode: MusicEntityNode {
    static let kind = MusicEntityKind.era
    var snapshot: MusicEntitySnapshot
    init?(snapshot: MusicEntitySnapshot) { guard let s = checked(snapshot, Self.kind) else { return nil }; self.snapshot = s }
    var decadeKey: String { snapshot.attrs["decade"] ?? "" }
}

struct MusicStationNode: MusicEntityNode {
    static let kind = MusicEntityKind.station
    var snapshot: MusicEntitySnapshot
    init?(snapshot: MusicEntitySnapshot) { guard let s = checked(snapshot, Self.kind) else { return nil }; self.snapshot = s }
    var isLive: Bool { snapshot.subkind == "live" }
}

// MARK: role-qualified credits

/// A person's or group's edges grouped by role (the role switcher of a person page): each role holds its edges in display order.
struct MusicRoleCredits: Sendable, Hashable {
    var byRole: [MusicRole: [MusicEdge]]
    init(edges: [MusicEdge]) {
        var out: [MusicRole: [MusicEdge]] = [:]
        for e in edges { if let r = e.role { out[r, default: []].append(e) } }
        byRole = out
    }
    var roles: [MusicRole] { MusicRole.allCases.filter { !(byRole[$0] ?? []).isEmpty } }
    func edges(for role: MusicRole) -> [MusicEdge] { byRole[role] ?? [] }
}
