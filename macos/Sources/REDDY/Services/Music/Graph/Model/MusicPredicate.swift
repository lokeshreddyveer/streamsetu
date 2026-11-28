import Foundation

/// The typed relations of the graph, stored subject to object (section 1.5). Raw values are stored in the database: never renumber.
/// Owner-facing names such as "acts-in" and "film-has-soundtrack" are the inverse labels of stored predicates and come from `label` / `inverseLabel`.
enum MusicPredicate: Int, Codable, Sendable, CaseIterable, Hashable {
    case trackOn = 0          // recording to release           (track-on-album)
    case editionOf            // release to album
    case recordingOf          // recording to work              (recording-of-work)
    case alternateOf          // recording to recording         (alternate-recording-of)
    case soundtrackOf         // album/release to film/series   (album-soundtrack-of-film)
    case featuredIn           // recording to film/series       (song-in-film)
    case performedBy          // recording/album to person/group
    case composedBy           // work/recording/album/film to person/group
    case musicDirectedBy      // album/film to person/group
    case writtenBy            // work/recording to person       (written-by)
    case producedBy           // recording/album/film to person/group
    case directedBy           // film/series to person
    case hasCast              // film/series to person          (acts-in, inverse)
    case memberOf             // person to group
    case collaboratedWith     // person to person               (derived, rarely stored)
    case playlistContains     // playlist to recording
    case relatedAlbum         // album to album
    case inLanguage, fromRegion, ofEra, hasGenre   // content entity to facet
    case sameAs               // resolver only: becomes a merge or an alias
    case influencedBy         // person/group to person/group  (a source states the influence)
    case samples              // recording to the recording or release it samples (A contains material from B); never a remix, cover or influence
    case samplesArtist        // recording to the artist it samples, when the original recording is not known
    case inFranchise          // film/series to the franchise (a series entity) a source says it is part of

    /// The owner-facing name of the stored direction.
    var label: String {
        switch self {
        case .trackOn: "track-on-album"
        case .editionOf: "edition-of"
        case .recordingOf: "recording-of-work"
        case .alternateOf: "alternate-recording-of"
        case .soundtrackOf: "album-soundtrack-of-film"
        case .featuredIn: "song-in-film"
        case .performedBy: "performed-by"
        case .composedBy: "composed-by"
        case .musicDirectedBy: "music-directed"
        case .writtenBy: "written-by"
        case .producedBy: "produced"
        case .directedBy: "directed"
        case .hasCast: "has-cast"
        case .memberOf: "member-of"
        case .collaboratedWith: "collaborated-with"
        case .influencedBy: "influenced-by"
        case .samples: "samples"
        case .samplesArtist: "samples-artist"
        case .inFranchise: "in-franchise"
        case .playlistContains: "playlist-contains"
        case .relatedAlbum: "related-album"
        case .inLanguage: "in-language"
        case .fromRegion: "from-region"
        case .ofEra: "of-era"
        case .hasGenre: "has-genre"
        case .sameAs: "same-as"
        }
    }

    /// The label read from the object's side ("acts-in": person to film), or nil when the predicate has none of note.
    var inverseLabel: String? {
        switch self {
        case .hasCast: "acts-in"
        case .directedBy: "directed"
        case .soundtrackOf: "film-has-soundtrack"
        case .featuredIn: "film-has-song"
        case .performedBy: "performed"
        case .composedBy: "composed"
        case .musicDirectedBy: "music-directed-film"
        case .writtenBy: "wrote"
        case .producedBy: "produced-work"
        case .trackOn: "release-has-track"
        case .recordingOf: "work-has-recording"
        case .playlistContains: "in-playlist"
        default: nil
        }
    }

    /// True when the same two entities can carry this predicate once per role (the role is the edge qualifier).
    var isRoleQualified: Bool {
        switch self { case .performedBy, .composedBy, .musicDirectedBy, .writtenBy, .producedBy, .directedBy, .hasCast: true; default: false }
    }

    /// Only a source that STATES the link may make these `verified`; a matcher or a provider's text can only make them `inferred`.
    /// A soundtrack album is never assumed to belong to a film, and a song is never assumed to be in a film, without a statement.
    var requiresStatement: Bool { self == .soundtrackOf || self == .featuredIn }

    /// Kinds allowed on each end. Permissive on purpose (a provider album is a `release` until an `album` is known), strict enough to refuse nonsense.
    func accepts(subject s: MusicEntityKind, object o: MusicEntityKind) -> Bool {
        let content: Set<MusicEntityKind> = [.recording, .work, .track, .album, .release, .film, .series]
        let audio: Set<MusicEntityKind> = [.recording, .work, .track, .album, .release]
        let agent: Set<MusicEntityKind> = [.person, .group]
        let facet: Set<MusicEntityKind> = [.genre, .language, .region, .era]
        switch self {
        case .trackOn: return [.recording, .track].contains(s) && [.release, .album].contains(o)
        case .editionOf: return s == .release && o == .album
        case .recordingOf: return [.recording, .track].contains(s) && o == .work
        case .alternateOf: return [.recording, .track, .work].contains(s) && s == o
        case .soundtrackOf: return [.album, .release].contains(s) && [.film, .series].contains(o)
        case .featuredIn: return [.recording, .track, .work].contains(s) && [.film, .series].contains(o)
        case .performedBy, .writtenBy: return audio.contains(s) && agent.contains(o)
        case .composedBy, .musicDirectedBy, .producedBy: return content.contains(s) && agent.contains(o)
        case .directedBy, .hasCast: return [.film, .series].contains(s) && agent.contains(o)
        case .memberOf: return s == .person && o == .group
        case .collaboratedWith: return agent.contains(s) && agent.contains(o)
        case .influencedBy: return agent.contains(s) && agent.contains(o)
        case .samples: return [.recording, .track].contains(s) && [.recording, .track, .release, .album].contains(o)
        case .samplesArtist: return [.recording, .track].contains(s) && agent.contains(o)
        case .inFranchise: return [.film, .series].contains(s) && o == .series && s != o || s == .film && o == .series
        case .playlistContains: return s == .playlist && [.recording, .track].contains(o)
        case .relatedAlbum: return [.album, .release].contains(s) && [.album, .release].contains(o)
        case .inLanguage: return o == .language && s != o
        case .fromRegion: return o == .region && (content.contains(s) || agent.contains(s) || s == .station)
        case .ofEra: return o == .era && s != o
        case .hasGenre: return o == .genre && (content.contains(s) || agent.contains(s) || s == .station)
        case .sameAs: return s == o && !facet.contains(s)
        }
    }
}
