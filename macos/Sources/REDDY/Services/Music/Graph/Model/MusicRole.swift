import Foundation

/// The role a person or group has on an edge. The raw value is the edge's `qualifier`, so the same person can be both composer and singer of one song.
enum MusicRole: String, Codable, Sendable, CaseIterable, Hashable {
    case singer, performer, instrumentalist, composer, musicDirector, arranger, lyricist, writer,
         actor, director, producer, screenwriter, cinematographer, editor, featured, conductor, remixer, label

    /// Roles a person can be credited for on a recording or album (the music side).
    var isMusical: Bool {
        switch self { case .singer, .performer, .instrumentalist, .composer, .musicDirector, .arranger, .lyricist, .writer, .featured, .conductor, .remixer, .producer: true; default: false }
    }
    /// Roles that come from a film's crew or cast.
    var isCinema: Bool { switch self { case .actor, .director, .screenwriter, .cinematographer, .editor, .producer, .musicDirector, .composer: true; default: false } }
}

enum EdgeStatus: UInt8, Codable, Sendable, Hashable { case verified = 0, inferred, conflicted }

/// How specific a claim is: a credit on the song itself, on the album, only on the film, or unknown.
enum CreditLevel: UInt8, Codable, Sendable, Hashable { case song = 0, album, film, unknown }

/// The kind of version one recording is of another (`alternateOf`).
enum MusicVersionKind: String, Codable, Sendable, CaseIterable, Hashable {
    case original, cover, remix, live, reRecording, karaoke, instrumental, reprise, dub, acoustic, unknown
    /// The lyrics of a work translated into another language (a work-level "translated" link in MusicBrainz). It says nothing about a film's dubbed edition.
    case translatedLyrics
    /// A recording or release in another language that a source states, without calling it a dub (a language word in a title, for example).
    case otherLanguage
    /// A soundtrack release that MusicBrainz links as a translated version of another release group.
    case translatedSoundtrack
}

/// Which way to follow an edge from an entity.
enum MusicEdgeDirection: Sendable, Hashable { case outgoing, incoming, both }
