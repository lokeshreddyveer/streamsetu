import Foundation

// The plain values the album / soundtrack page is made of (sections A-K of the graph design, section 6.1). Everything here is a Sendable, Hashable
// value with no view and no database handle, so a section loader can hand it to the entity model (`MusicSectionResult.items`) and a test can compare
// it. Words the person reads are NOT stored here: a row carries a `MusicSoundtrackReason` (what is true) and the view words it, so every line is
// localisable and a test checks the meaning, not the wording.

/// The section keys the page registers on the shared entity model (one load per key however many views hold the lease).
enum MusicSoundtrackKey {
    static let header = "soundtrack.header"
    static let credits = "soundtrack.credits"
    static let cast = "soundtrack.cast"
    static let moreFilms = "soundtrack.moreFilms"
    static let soundtracksOfCast = "soundtrack.soundtracksOfCast"
    static let moreByComposers = "soundtrack.moreByComposers"
    static let moreBySingers = "soundtrack.moreBySingers"
    static let related = "soundtrack.related"
    static let classic = "soundtrack.classic"
    static let explore = "soundtrack.explore"
    static let all = [header, credits, cast, moreFilms, soundtracksOfCast, moreByComposers, moreBySingers, related, classic, explore]
}

/// Caps that keep the page bounded (the design's request fan-out rule: 4 cast, 8 films, 2 provider searches in flight).
enum MusicSoundtrackLimits {
    static let castShown = 12
    static let castForFilmography = 4
    static let filmsPerActor = 12
    static let filmsShown = 16
    static let filmsForSoundtracks = 8
    static let providerSearchesInFlight = 2
    static let enrichmentInFlight = 2
    static let composersUsed = 3
    static let singersUsed = 3
    static let albumsPerShelf = 16
    static let songsPerShelf = 20
    static let relatedShown = 12
    static let classicShown = 12
    static let tracksForCredits = 60
    static let readConcurrency = 6
    /// A film link below this confidence is not shown at all (provisional, plain text only).
    static let minFilmLinkConfidence: Float = 0.6
    /// An inferred relationship below this reads "Possibly related".
    static let plainWordingConfidence: Float = 0.75
    /// The window of "similar era" in years, each side.
    static let eraYears = 10
}

// MARK: - People and films

struct MusicSoundtrackPerson: Hashable, Sendable {
    var id: MusicEntityID
    var name: String
    var imageRef: String?
    /// Tells two people of one name apart ("b. 1923", "Hindi singer"); nil while the name is unique on the page.
    var detail: String?
    init(id: MusicEntityID, name: String, imageRef: String? = nil, detail: String? = nil) {
        self.id = id; self.name = name; self.imageRef = imageRef; self.detail = detail
    }
}

/// The film an album is the soundtrack of, with how sure the graph is.
struct MusicSoundtrackFilm: Hashable, Sendable {
    var id: MusicEntityID
    var title: String
    var year: Int?
    var language: String?
    var imageRef: String?
    var linkStatus: EdgeStatus
    var linkConfidence: Float
    /// An inferred link (a matcher or provider wording, not a source that states it) carries the small "inferred film link" tag.
    var isInferredLink: Bool { linkStatus != .verified }
    var isSeries: Bool { id.kind == .series }
    init(id: MusicEntityID, title: String, year: Int? = nil, language: String? = nil, imageRef: String? = nil, linkStatus: EdgeStatus = .verified, linkConfidence: Float = 1) {
        self.id = id; self.title = title; self.year = year; self.language = language; self.imageRef = imageRef
        self.linkStatus = linkStatus; self.linkConfidence = linkConfidence
    }
}

// MARK: - A: header

struct MusicSoundtrackHeaderFacts: Hashable, Sendable {
    var title: String
    var year: Int?
    var languageName: String?
    /// soundtrack, score, album, ep, single, compilation (the album's subkind, nil when unknown).
    var subkind: String?
    var imageRef: String?
    var film: MusicSoundtrackFilm?
    var languageID: MusicEntityID?
    var eraID: MusicEntityID?
    var eraName: String?
    /// "(From "Film")" wording of a provider: plain text only, never a link, never a cast.
    var filmHint: String?
    /// The people shown under the title: music directors first, then composers (at most three), each with their role.
    var makers: [MusicSoundtrackCredit]
    var isFilm: Bool { film != nil }
    var isSoundtrackType: Bool { subkind == MusicAlbumSubkind.soundtrack.rawValue || subkind == MusicAlbumSubkind.score.rawValue }
    init(title: String, year: Int? = nil, languageName: String? = nil, subkind: String? = nil, imageRef: String? = nil, film: MusicSoundtrackFilm? = nil,
         filmHint: String? = nil, makers: [MusicSoundtrackCredit] = []) {
        self.title = title; self.year = year; self.languageName = languageName; self.subkind = subkind; self.imageRef = imageRef
        self.film = film; self.filmHint = filmHint; self.makers = makers
    }
}

// MARK: - C: credits

struct MusicSoundtrackCredit: Hashable, Sendable {
    var person: MusicSoundtrackPerson
    var role: MusicRole
    /// How many songs of this release the person is credited on (0 when the credit is on the album or film only).
    var songCount: Int
    /// The most specific level any claim of this person and role had: song, album or film. Film-level credits carry the "film credit" tag.
    var level: CreditLevel
    var status: EdgeStatus
    var order: Int
    var isFilmCredit: Bool { level == .film }
    init(person: MusicSoundtrackPerson, role: MusicRole, songCount: Int = 0, level: CreditLevel = .unknown, status: EdgeStatus = .inferred, order: Int = 0) {
        self.person = person; self.role = role; self.songCount = songCount; self.level = level; self.status = status; self.order = order
    }
}

enum MusicSoundtrackCreditKind: Int, Hashable, Sendable, CaseIterable {
    case musicDirector = 0, composer, lyricist, singer, artist, other
    /// The role a tap opens the person page on.
    var routeRole: MusicRole {
        switch self {
        case .musicDirector: .musicDirector
        case .composer: .composer
        case .lyricist: .lyricist
        case .singer: .singer
        case .artist: .performer
        case .other: .performer
        }
    }
}

struct MusicSoundtrackCreditGroup: Hashable, Sendable {
    var kind: MusicSoundtrackCreditKind
    var credits: [MusicSoundtrackCredit]
}

// MARK: - D: cast

struct MusicSoundtrackCast: Hashable, Sendable {
    var person: MusicSoundtrackPerson
    var character: String?
    /// Billing order, 0 first.
    var billing: Int
    var status: EdgeStatus
    init(person: MusicSoundtrackPerson, character: String? = nil, billing: Int = 0, status: EdgeStatus = .verified) {
        self.person = person; self.character = character; self.billing = billing; self.status = status
    }
}

// MARK: - Albums, films and songs offered by the shelves

struct MusicSoundtrackAlbum: Hashable, Sendable {
    var id: MusicEntityID
    var title: String
    var year: Int?
    var imageRef: String?
    var subkind: String?
    /// The film this album is the soundtrack of, when a link exists (never guessed from the title).
    var film: MusicSoundtrackFilm?
    var reason: MusicSoundtrackReason
    var band: Int
    var score: Double
    /// Two albums with one cluster key are the same thing (language editions of one soundtrack): the shelf shows the first.
    var cluster: String
    var isInferredFilmLink: Bool { film?.isInferredLink ?? false }
}

struct MusicSoundtrackFilmItem: Hashable, Sendable {
    var film: MusicSoundtrackFilm
    /// The people of this page's cast who are also in this film, in billing order of this page's cast.
    var actors: [MusicSoundtrackPerson]
    var reason: MusicSoundtrackReason
    var score: Double
}

struct MusicSoundtrackSong: Hashable, Sendable {
    var id: MusicEntityID
    var title: String
    var year: Int?
    var imageRef: String?
    var singers: [String]
    var albumID: MusicEntityID?
    var albumTitle: String?
    var reason: MusicSoundtrackReason
    var score: Double
}

/// One entry of a shelf that mixes albums and songs (section G: compositions and soundtracks by the same composers).
enum MusicSoundtrackEntry: Hashable, Sendable {
    case album(MusicSoundtrackAlbum)
    case song(MusicSoundtrackSong)
}

// MARK: - K: continue exploring

struct MusicSoundtrackLink: Hashable, Sendable {
    enum Target: Hashable, Sendable {
        case person(MusicEntityID, MusicRole)
        case film(MusicEntityID)
        case language(MusicEntityID)
        case era(MusicEntityID)
        /// "Start radio from this album": an action, not a page.
        case radio
    }
    var target: Target
    var title: String
    var reason: MusicSoundtrackReason
}

// MARK: - Reasons

/// Why something is on the page: what is true, in a form a test can compare. `text(_:)` words it from the app's tables.
indirect enum MusicSoundtrackReason: Hashable, Sendable {
    case sameMusicDirector(String)
    case sameComposer(String)
    case sameCreatorsAndSinger(composer: String, singer: String)
    case sungBy(String)
    case sungOnThisSoundtrack(String)
    case sharedCast([String])
    case withActors([String])
    case soundtrackOfFilmWith(film: String, actors: [String])
    case soundtrackOfFilm(String)
    case otherEdition
    case relatedAlbum
    case eraAndLanguage(era: String, language: String)
    case sameGenre(String)
    case classicCinema(language: String, from: Int, to: Int)
    case classicCinemaEra(from: Int, to: Int)
    case sameArtist(String)
    case possibly(MusicSoundtrackReason)
    case fromThisAlbum
    case radioFromAlbum
    case creditsOfThisAlbum(role: MusicRole, songs: Int)
    case actorInFilm(String)
    case filmOfThisAlbum
    case languageOfThisAlbum
    case eraOfThisAlbum

    /// Wraps a reason as "possibly related" when the evidence is an inferred, low-confidence link.
    static func qualified(_ r: MusicSoundtrackReason, status: EdgeStatus, confidence: Float) -> MusicSoundtrackReason {
        if case .possibly = r { return r }
        return status != .verified && confidence < MusicSoundtrackLimits.plainWordingConfidence ? .possibly(r) : r
    }

    /// The reason's wording. `format` maps an English template with `%@` placeholders to the person's language (the app passes `Localized.string`
    /// without arguments, so it returns the translated format), and the placeholders are filled here.
    func text(_ format: (String) -> String) -> String {
        func fill(_ key: String, _ args: [String]) -> String {
            var out = format(key)
            for (i, a) in args.enumerated() { if let r = out.range(of: "%\(i + 1)$@") ?? out.range(of: "%@") { out.replaceSubrange(r, with: a) } }
            return out
        }
        func list(_ names: [String]) -> String {
            switch names.count {
            case 0: return ""
            case 1: return names[0]
            case 2: return fill("%1$@ and %2$@", names)
            default: return fill("%1$@ and %2$@", [names.dropLast().joined(separator: ", "), names[names.count - 1]])
            }
        }
        switch self {
        case .sameMusicDirector(let n): return fill("Same music director: %@", [n])
        case .sameComposer(let n): return fill("Same composer: %@", [n])
        case .sameCreatorsAndSinger(let c, let s): return fill("Same music by %1$@, sung by %2$@", [c, s])
        case .sungBy(let n): return fill("Sung by %@", [n])
        case .sungOnThisSoundtrack(let n): return fill("Sung by %@, who sings on this soundtrack", [n])
        case .sharedCast(let n): return fill("Shares cast: %@", [list(n)])
        case .withActors(let n): return fill("With %@", [list(n)])
        case .soundtrackOfFilmWith(let f, let a): return a.isEmpty ? fill("Soundtrack of %@", [f]) : fill("Soundtrack of %1$@, with %2$@", [f, list(a)])
        case .soundtrackOfFilm(let f): return fill("Soundtrack of %@", [f])
        case .otherEdition: return format("Another edition of this soundtrack")
        case .relatedAlbum: return format("Related album")
        case .eraAndLanguage(let e, let l): return fill("Same era and language: %1$@ %2$@", [e, l])
        case .sameGenre(let g): return fill("Same genre: %@", [g])
        case .classicCinema(let l, let a, let b): return fill("%1$@ film music, %2$@ to %3$@", [l, String(a), String(b)])
        case .classicCinemaEra(let a, let b): return fill("Film music, %1$@ to %2$@", [String(a), String(b)])
        case .sameArtist(let n): return fill("More from %@", [n])
        case .possibly(let inner): return inner.text(format)
        case .fromThisAlbum: return format("From this album")
        case .radioFromAlbum: return format("Radio from this album")
        case .creditsOfThisAlbum(let role, let n): return fill("%1$@ on %2$@ songs here", [MusicSoundtrackText.roleName(role, format), String(n)])
        case .actorInFilm(let f): return fill("In %@", [f])
        case .filmOfThisAlbum: return format("The film of this soundtrack")
        case .languageOfThisAlbum: return format("Music in this language")
        case .eraOfThisAlbum: return format("Music from this era")
        }
    }
}

/// English wording used by tests and by builds without a language table (`Localized.string` is the app's own).
enum MusicSoundtrackText {
    static let english: @Sendable (String) -> String = { $0 }

    static func roleName(_ role: MusicRole, _ format: (String) -> String) -> String {
        switch role {
        case .singer: format("Singer")
        case .performer: format("Artist")
        case .composer: format("Composer")
        case .musicDirector: format("Music director")
        case .lyricist: format("Lyricist")
        case .writer: format("Writer")
        case .actor: format("Actor")
        case .director: format("Director")
        case .producer: format("Producer")
        case .arranger: format("Arranger")
        case .conductor: format("Conductor")
        case .instrumentalist: format("Instrumentalist")
        case .remixer: format("Remixer")
        case .featured: format("Featured artist")
        case .screenwriter: format("Screenwriter")
        case .cinematographer: format("Cinematographer")
        case .editor: format("Editor")
        case .label: format("Label")
        }
    }
}
