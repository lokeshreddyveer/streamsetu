import Foundation

/// Every sentence of the person page, in one place. The data layer stores typed reasons and labels; these turn them into words (and into the
/// Hindi and Telugu tables through `Localized`). Nothing here reads the graph.
enum MusicPersonWording {
    static func roleLabel(_ l: MusicPersonRoleLabel) -> String {
        switch l {
        case .singer: Localized.string("Singer")
        case .artist: Localized.string("Artist")
        case .composer: Localized.string("Composer")
        case .musicDirector: Localized.string("Music director")
        case .lyricist: Localized.string("Lyricist")
        case .writer: Localized.string("Writer")
        case .actor: Localized.string("Actor")
        case .director: Localized.string("Director")
        case .producer: Localized.string("Producer")
        case .screenwriter: Localized.string("Screenwriter")
        case .cinematographer: Localized.string("Cinematographer")
        case .editor: Localized.string("Editor")
        case .label: Localized.string("Label")
        case .instrumentalist: Localized.string("Instrumentalist")
        case .conductor: Localized.string("Conductor")
        }
    }

    /// The caption under a person card: the role the credit gave them ("Composer", "Singer").
    static func roleCaption(_ roles: [MusicRole]) -> String? {
        guard let r = roles.first else { return nil }
        switch r {
        case .singer: return roleLabel(.singer)
        case .performer, .featured, .remixer: return roleLabel(.artist)
        case .instrumentalist: return roleLabel(.instrumentalist)
        case .conductor: return roleLabel(.conductor)
        case .composer, .arranger: return roleLabel(.composer)
        case .musicDirector: return roleLabel(.musicDirector)
        case .lyricist: return roleLabel(.lyricist)
        case .writer: return roleLabel(.writer)
        case .actor: return roleLabel(.actor)
        case .director: return roleLabel(.director)
        case .producer: return roleLabel(.producer)
        default: return nil
        }
    }

    static func kindLabel(isGroup: Bool, groupKind: String?, summary: MusicPersonRoleSummary) -> String {
        if isGroup {
            switch groupKind {
            case "duo": return Localized.string("Duo")
            case "band": return Localized.string("Band")
            case "orchestra": return Localized.string("Orchestra")
            default: return Localized.string("Group")
            }
        }
        return Localized.string("Person")
    }

    static func life(_ l: MusicPersonLife) -> String {
        switch l.shape {
        case .span(let a, let b): "\(a)–\(b)"
        case .born(let a): Localized.string("Born %d", a)
        case .died(let b): Localized.string("Died %d", b)
        case .activeSpan(let a, let b): Localized.string("Active %1$@", "\(a)–\(b)")
        case .since(let a): Localized.string("Since %d", a)
        case .until(let b): Localized.string("Until %d", b)
        }
    }

    static func source(_ bio: MusicPersonBio) -> String {
        bio.licence.map { Localized.string("Source: %1$@ (%2$@)", bio.source, $0) } ?? Localized.string("Source: %1$@", bio.source)
    }

    static func reason(_ r: MusicPersonReason?) -> String? {
        guard let r else { return nil }
        switch r {
        case .sharedWorks(let n): return Localized.string("%d songs together", n)
        case .sharedFilms(let n): return Localized.string("%d films together", n)
        case .fromFilm(let t): return Localized.string("From the film %1$@", t)
        case .possibleFilmLink(let t): return Localized.string("Possibly from the film %1$@", t)
        case .sameMusicDirector(let n): return Localized.string("Same music director: %1$@", n)
        case .sameDirector(let n): return Localized.string("Same director: %1$@", n)
        case .sharedComposers(let n): return Localized.string("%d songs by the same composers", n)
        case .sharedSingers(let n): return Localized.string("%d songs for the same singers", n)
        case .storedSimilar: return Localized.string("Similar artist")
        case .sharedCast(let n): return Localized.string("Same cast: %1$@", n)
        case .sharedCollaborators(let n): return Localized.string("%d songs with the same collaborators", n)
        }
    }

    static func sectionTitle(_ id: MusicPersonSectionID, name: String) -> String {
        switch id {
        case .topSongs: Localized.string("Top songs")
        case .albums: Localized.string("Albums")
        case .singles: Localized.string("Singles & EPs")
        case .filmSongs: Localized.string("Film songs")
        case .playbackSongs: Localized.string("Sung as a playback singer")
        case .collaborations: Localized.string("Collaborations")
        case .composersWorkedWith: Localized.string("Composers worked with")
        case .languages: Localized.string("Languages")
        case .relatedArtists: Localized.string("Related artists")
        case .playlists: Localized.string("In playlists")
        case .radio: Localized.string("Radio")
        case .popularCompositions: Localized.string("Popular compositions")
        case .soundtracks: Localized.string("Soundtracks")
        case .films: Localized.string("Films")
        case .singersWorkedWith: Localized.string("Singers worked with")
        case .lyricistsWorkedWith: Localized.string("Lyricists worked with")
        case .relatedComposers: Localized.string("Related composers")
        case .songsWritten: Localized.string("Songs written")
        case .composers: Localized.string("Composers")
        case .singers: Localized.string("Singers")
        case .frequentCollaborators: Localized.string("Frequent collaborators")
        case .filmography: Localized.string("Filmography")
        case .popularMovies: Localized.string("Popular movies")
        case .movieSoundtracks: Localized.string("Movie soundtracks")
        case .songsFromMovies: Localized.string("Popular songs from their movies")
        case .coStars: Localized.string("Co-stars")
        case .directorsWorkedWith: Localized.string("Directors worked with")
        case .relatedCinema: Localized.string("Related cinema")
        case .filmSoundtracks: Localized.string("Film soundtracks")
        case .composersCollaborated: Localized.string("Composers collaborated with")
        case .frequentCast: Localized.string("Frequent cast")
        case .relatedFilms: Localized.string("Related films")
        case .memberOf: Localized.string("Member of")
        case .members: Localized.string("Members")
        case .influencedBy: Localized.string("Influenced by")
        case .influenced: Localized.string("Influenced")
        case .soloCareers: Localized.string("Solo work of the members")
        case .producedSongs: Localized.string("Songs produced")
        case .instrumentSongs: Localized.string("Recordings featuring them")
        case .conductedSongs: Localized.string("Performances conducted")
        case .labelCatalogue: Localized.string("Catalogue")
        }
    }

    static func showAll(_ n: Int) -> String { Localized.string("Show all %d", n) }
    static var didYouMean: String { Localized.string("Did you mean") }
    static var loadingPerson: String { Localized.string("Loading this person") }
    static var unavailable: String { Localized.string("This person is not available right now.") }
    static var sparseTitle: String { Localized.string("Nothing more to show yet") }
    static var sparseMessage: String { Localized.string("Songs, films and collaborators appear here as music data for this person becomes available.") }
    static var nothingToPlay: String { Localized.string("Nothing to play here yet.") }
    static var play: String { Localized.string("Play") }
    static var shuffle: String { Localized.string("Shuffle") }
    static var startRadio: String { Localized.string("Start radio") }
    static var follow: String { Localized.string("Follow") }
    static var following: String { Localized.string("Following") }
    static var inYourLibrary: String { Localized.string("In your library") }
    static func startRadioFrom(_ s: String) -> String { Localized.string("Start radio from %1$@", s) }
    static func playLabel(_ name: String) -> String { Localized.string("Play %1$@", name) }
    static func shuffleLabel(_ name: String) -> String { Localized.string("Shuffle %1$@", name) }
    static func roleSwitcherLabel(_ name: String) -> String { Localized.string("Roles of %1$@", name) }
    static func chipLabel(_ role: String, count: Int) -> String { Localized.string("%1$@, %2$d credits", role, count) }
    static func filterDecade(_ d: Int) -> String { Localized.string("%ds", d) }
    static var filterAll: String { Localized.string("All") }
}
