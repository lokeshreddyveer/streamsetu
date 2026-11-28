import Foundation

// The values the film page shows. A section loader reads the graph and hands these back; the views only draw them. Every type is a plain
// Sendable value (sections hold them as AnyHashable), and nothing here reads the player or the network.

/// The section keys of the film page (one `MusicEntitySectionLoader` each).
enum MusicFilmSectionKey {
    static let cast = "film.cast"
    static let crew = "film.crew"
    static let overview = "film.overview"
    static let soundtracks = "film.soundtracks"
    static let songs = "film.songs"
    static let versions = "film.versions"
    static let related = "film.related"
    static let castMusic = "film.castMusic"
    static let directorFilms = "film.directorFilms"
    static let composerMusic = "film.composerMusic"

    /// Loaded as soon as the page opens: everything above the fold and the music of the film itself.
    /// Derived from the loaders the model really starts, so the two cannot drift.
    static let core: [String] = MusicFilmLoaders.core.map(\.key)
}

/// One credited person or group on the film: an actor with a character, or crew with a job.
struct MusicFilmPersonItem: Hashable, Sendable, Identifiable {
    var person: MusicEntityID
    var name: String
    var imageRef: String?
    var role: MusicRole
    var character: String?
    var order: Int?
    var status: EdgeStatus
    var creditLevel: CreditLevel
    /// Known by name only (no id from any source): shown, never merged and never linked as an authority.
    var nameOnly: Bool
    var attribution: String?
    /// Tells two people of one name apart (shown as "b. 1924").
    var birthYear: Int?
    /// The job TMDB states for a credit of a crew department ("Director of Photography"); nil for the roles the graph names itself.
    var job: String? = nil
    var id: String { person.rawValue + "|" + role.rawValue + "|" + (character ?? "") + "|" + (job ?? "") }
    var isGroup: Bool { person.kind == .group }
}

/// A crew role with its people (director, producer, music director, composer, and writer, cinematographer, editor where the graph has them).
struct MusicFilmCrewItem: Hashable, Sendable, Identifiable {
    var role: MusicRole
    var people: [MusicFilmPersonItem]
    /// Set for a department read from TMDB's crew list (camera, sound, costume...); `role` is then only a placeholder and never opens a person page.
    var department: MusicFilmDepartment? = nil
    var id: String { department.map { "dept:" + $0.rawValue } ?? role.rawValue }
}

/// The header facts of the film beyond the snapshot: languages, a short description, a synopsis when one is stored, and where each came from.
struct MusicFilmOverview: Hashable, Sendable {
    var title: String
    var year: Int?
    var languages: [String]
    var description: String?
    var synopsis: String?
    var synopsisSource: String?
    var seasons: Int?
    var imageRef: String?
    var isSeries: Bool
    /// Sources whose text must be credited on the page (TMDB, Wikipedia...).
    var attributions: [String]
    /// The film's own facts from its source (all optional; a field the source lacks is nil, never guessed).
    var originalTitle: String? = nil
    var releaseDate: String? = nil
    var runtimeMinutes: Int? = nil
    var tagline: String? = nil
    var genres: [String] = []
    var rating: String? = nil
    var ratingVotes: Int? = nil
    var certification: String? = nil
    var certificationRegion: String? = nil
    var trailerKey: String? = nil
    /// The About facts of the same TMDB reply: production companies and countries, spoken languages, release status, and budget and box office (only when above 0).
    var companies: [String] = []
    var productionCountries: [String] = []
    var spokenLanguages: [String] = []
    var status: String? = nil
    var budget: Int? = nil
    var revenue: Int? = nil
    /// The film's official videos (trailers, teasers, clips, featurettes, behind the scenes) as links that open outside the app.
    var videos: [MusicFilmVideo] = []
    /// A wide still of the film (TMDB's own backdrop from the same reply), drawn dimmed behind the header.
    var backdropURL: String? = nil
    /// The film's pictures (picture-only backdrops, then posters), shown in the Gallery tab.
    var gallery: [MusicFilmGalleryImage] = []
}

/// One soundtrack album of the film, as a card.
struct MusicFilmAlbumItem: Hashable, Sendable, Identifiable {
    var album: MusicEntityID
    var name: String
    var year: Int?
    var imageRef: String?
    var lang: String?
    /// Set when the album is a dubbed edition of the film's music (the language of the dub).
    var dubLanguage: String?
    var status: EdgeStatus
    var confidence: Float
    /// The evidence tokens of an inferred match (`title`, `composer`, `year`, `dub-language`...); empty when a source states the link. The views
    /// turn them into a sentence ("Matched by title and music director").
    var matchEvidence: [String]
    /// For shelves about other people's work: who connects it ("Raj Kapoor").
    var via: String?
    /// The film the album belongs to when it is not this page's film (shelves of other films' music).
    var film: MusicEntityID?
    var filmName: String?
    var id: String { album.rawValue + "|" + (via ?? "") }
}

/// One recording on the film's soundtrack releases.
struct MusicFilmSongItem: Hashable, Sendable, Identifiable {
    var recording: MusicEntityID
    var title: String
    var durationMs: Int?
    var imageRef: String?
    var album: MusicEntityID
    var albumName: String
    var dubLanguage: String?
    var disc: Int?
    var position: Int?
    var singers: [MusicFilmSingerRef]
    /// The existing `providerID:id` uid of a playable copy, when the graph holds one. Nil: playable only after a catalogue match.
    var providerUID: String?
    /// The provider id of the release the song sits on, for the player's album link.
    var releaseProviderUID: String?
    var status: EdgeStatus
    var id: String { recording.rawValue + "|" + album.rawValue }
    var playsDirectly: Bool { providerUID != nil }
}

struct MusicFilmSingerRef: Hashable, Sendable {
    var person: MusicEntityID
    var name: String
    var imageRef: String?
    /// False for a person minted from provider text alone (no id from any source yet).
    var established = true
}

/// A singer of the film with the number of its songs they sing.
struct MusicFilmSingerItem: Hashable, Sendable, Identifiable {
    var person: MusicEntityID
    var name: String
    var imageRef: String?
    var songCount: Int
    var id: String { person.rawValue }
}

/// Why a film is related: the connection, in words the views localise.
enum MusicFilmRelationReason: Hashable, Sendable {
    case director(String)
    case composer(String)
    case cast([String])
    case sameLanguage(String)
    case sameEra(Int)
    case soundtrack
}

/// A film (or series) as a card: related films, more films by the director.
struct MusicFilmRelatedItem: Hashable, Sendable, Identifiable {
    var film: MusicEntityID
    var name: String
    var year: Int?
    var imageRef: String?
    var lang: String?
    var reasons: [MusicFilmRelationReason]
    var score: Double
    var isSeries: Bool { film.kind == .series }
    var id: String { film.rawValue }
}

/// A real alternative form of the film: a dubbed edition (from a `soundtrackOf` edge that names the dub language) or another name of the film
/// (from the aliases of the film itself). Never a merge of two films.
struct MusicFilmVersionItem: Hashable, Sendable, Identifiable {
    enum Kind: String, Hashable, Sendable { case dubbedAlbum, alias }
    var kind: Kind
    var text: String
    var language: String?
    /// The soundtrack album of a dub: opens its album page.
    var album: MusicEntityID?
    var id: String { kind.rawValue + "|" + (album?.rawValue ?? "") + "|" + text }
}
