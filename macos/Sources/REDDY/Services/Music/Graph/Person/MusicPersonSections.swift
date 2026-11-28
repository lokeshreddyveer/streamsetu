import Foundation

// The data a person page shows, as plain values. A builder (MusicPersonReader) reads the graph and fills these; the views only draw them.
// Entries hold names and numbers, never localized sentences: the views word them ("3 songs together") so the strings live in one place.

enum MusicPersonSectionID: String, Sendable, Hashable, CaseIterable {
    // singer
    case topSongs, albums, singles, filmSongs, playbackSongs, collaborations, composersWorkedWith, languages, relatedArtists, playlists, radio
    // composer and music director
    case popularCompositions, soundtracks, films, singersWorkedWith, lyricistsWorkedWith, relatedComposers
    // lyricist
    case songsWritten, composers, singers, frequentCollaborators
    // actor
    case filmography, popularMovies, movieSoundtracks, songsFromMovies, coStars, directorsWorkedWith, relatedCinema
    // director
    case filmSoundtracks, composersCollaborated, frequentCast, relatedFilms
    // producer, instrumentalist, conductor, label
    case producedSongs, instrumentSongs, conductedSongs, labelCatalogue
    // people and groups
    case memberOf, members, soloCareers, influencedBy, influenced

    /// Which sections a view has, in the order the owner listed them.
    static func order(for view: MusicPersonView) -> [MusicPersonSectionID] {
        switch view {
        case .singer: [.topSongs, .albums, .singles, .filmSongs, .playbackSongs, .collaborations, .composersWorkedWith, .languages, .relatedArtists, .playlists, .radio]
        case .composer: [.popularCompositions, .soundtracks, .albums, .films, .singersWorkedWith, .lyricistsWorkedWith, .relatedComposers]
        case .lyricist: [.songsWritten, .albums, .films, .composers, .singers, .frequentCollaborators, .relatedArtists]
        case .actor: [.filmography, .popularMovies, .movieSoundtracks, .songsFromMovies, .coStars, .directorsWorkedWith, .relatedCinema]
        case .director: [.filmography, .filmSoundtracks, .composersCollaborated, .frequentCast, .relatedFilms]
        case .producer: [.producedSongs, .albums, .films, .composers, .singers, .frequentCollaborators, .relatedArtists]
        case .instrumentalist: [.instrumentSongs, .albums, .films, .singers, .composers, .frequentCollaborators, .relatedArtists]
        case .conductor: [.conductedSongs, .albums, .films, .singers, .composers, .frequentCollaborators, .relatedArtists]
        case .label: [.labelCatalogue, .albums, .films, .singers, .composers, .frequentCollaborators, .relatedArtists]
        }
    }
}

/// Why an entry is on the page: one short, true reason. Inferred links are worded as possible.
enum MusicPersonReason: Hashable, Sendable {
    case sharedWorks(Int)
    case sharedFilms(Int)
    case fromFilm(String)
    case sameMusicDirector(String)
    case sameDirector(String)
    /// Related artists: songs of theirs by the composers this singer worked with most.
    case sharedComposers(Int)
    /// Related composers: songs they wrote for the singers this composer worked with most.
    case sharedSingers(Int)
    case possibleFilmLink(String)
    case storedSimilar(String)
    case sharedCast(String)
    /// Related people of a role without a page of its own: songs they share with the people this person worked with most.
    case sharedCollaborators(Int)
}

struct MusicPersonEntry: Hashable, Sendable, Identifiable {
    var id: MusicEntityID
    var name: String
    var kind: MusicEntityKind
    var subkind: String?
    var year: Int?
    var lang: String?
    var imageRef: String?
    /// A second line of plain data: the character an actor played, the singers of a song.
    var detail: String?
    var count: Int?
    /// 0 is the lead; nil when the source gave no billing.
    var billing: Int?
    var reason: MusicPersonReason?
    var roles: [MusicRole] = []
    var status: EdgeStatus?
    var confidence: Float?
    /// For a song: the film it belongs to (the page shows it as "from the film", not as "picturised on").
    var filmID: MusicEntityID?
    var filmTitle: String?
    /// The film's own year, when the graph states it (the song's year can differ).
    var filmYear: Int?
    var durationMs: Int?
    /// For a recording: the kind of version the graph states (live, acoustic, remix, instrumental), when it does. Never worked out from a live title.
    var versionKind: String?
    /// False for entries that are only a label with a number (a language).
    var navigable = true

    init(id: MusicEntityID, name: String, kind: MusicEntityKind) { self.id = id; self.name = name; self.kind = kind }

    init(snapshot s: MusicEntitySnapshot) {
        self.init(id: s.id, name: s.name, kind: s.kind)
        subkind = s.subkind; year = s.year; lang = s.lang; imageRef = s.imageRef; durationMs = s.durationMs
        versionKind = MusicSongPerformance.trustedVersionKind(s.attrs)
    }
}

extension MusicPersonEntry {
    /// The role a card opens the person's page on. A person credited in several roles (the merge of the collaboration shelves keeps the union, in the roles' own
    /// order) opens on the page's default view: the first role of the union is not the one they are mainly known for.
    var openRole: MusicRole? { roles.count == 1 ? roles.first : nil }
}

struct MusicPersonSection: Hashable, Sendable, Identifiable {
    var id: MusicPersonSectionID
    var entries: [MusicPersonEntry]
    /// How many there were before the section was cut to its display size (the page says "Show all 48").
    var total: Int
    init(_ id: MusicPersonSectionID, _ entries: [MusicPersonEntry], total: Int? = nil) { self.id = id; self.entries = entries; self.total = total ?? entries.count }
}

/// One view's sections. `complete` is false while stages are still loading (the page shows what is here and a quiet progress line); `truncated` says a
/// bound cut the reading short.
struct MusicPersonViewData: Hashable, Sendable {
    var person: MusicEntityID
    var view: MusicPersonView
    var sections: [MusicPersonSection]
    var complete: Bool
    var truncated: Bool

    func section(_ id: MusicPersonSectionID) -> MusicPersonSection? { sections.first { $0.id == id } }
    /// Only the sections that hold something, in the owner's order. A section with nothing in it never shows a heading.
    var visible: [MusicPersonSection] {
        let order = MusicPersonSectionID.order(for: view)
        return Self.condensed(sections.filter { !$0.entries.isEmpty }).sorted { (order.firstIndex(of: $0.id) ?? 99) < (order.firstIndex(of: $1.id) ?? 99) }
    }

    /// Sections that say the same thing in different words become one: soundtracks, singles and albums are all "Albums" (each card keeps its own caption),
    /// and every list of people the person worked with is one "Collaborations". A page with ten shelves of near-identical cards reads as noise.
    static let albumGroup: Set<MusicPersonSectionID> = [.albums, .singles, .soundtracks, .movieSoundtracks, .filmSoundtracks]
    static let peopleGroup: Set<MusicPersonSectionID> = [.collaborations, .singersWorkedWith, .lyricistsWorkedWith, .composersWorkedWith, .composersCollaborated,
                                                          .frequentCollaborators, .coStars, .directorsWorkedWith, .frequentCast, .composers, .singers]

    static func condensed(_ list: [MusicPersonSection]) -> [MusicPersonSection] {
        func merge(_ group: Set<MusicPersonSectionID>, into target: MusicPersonSectionID, sort: (MusicPersonEntry, MusicPersonEntry) -> Bool) -> [MusicPersonSection] {
            let parts = list.filter { group.contains($0.id) }
            guard !parts.isEmpty else { return [] }
            // One row per person: the roles of every section they appear in are kept (in the roles' own order) and the count is the largest the sections gave.
            var index: [MusicEntityID: Int] = [:], entries: [MusicPersonEntry] = []
            for e in parts.flatMap(\.entries) {
                guard let i = index[e.id] else { index[e.id] = entries.count; entries.append(e); continue }
                var have = entries[i]
                let roles = Set(have.roles).union(e.roles)
                have.roles = MusicRole.allCases.filter { roles.contains($0) }
                if let c = e.count { have.count = max(have.count ?? 0, c) }
                entries[i] = have
            }
            return [MusicPersonSection(target, entries.sorted(by: sort), total: max(entries.count, parts.map(\.total).max() ?? 0))]
        }
        let rest = list.filter { !albumGroup.contains($0.id) && !peopleGroup.contains($0.id) }
        let albums = merge(albumGroup, into: .albums) { ($0.year ?? 0) != ($1.year ?? 0) ? ($0.year ?? 0) > ($1.year ?? 0) : $0.name < $1.name }
        let people = merge(peopleGroup, into: .collaborations) { ($0.count ?? 0) != ($1.count ?? 0) ? ($0.count ?? 0) > ($1.count ?? 0) : $0.name < $1.name }
        return rest + albums + people
    }
    var isEmpty: Bool { visible.isEmpty }
}
