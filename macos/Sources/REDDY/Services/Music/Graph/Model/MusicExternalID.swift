import Foundation

/// An id some other system gave an entity. Strong ids belong to exactly one live entity; weak ids only index candidates and never merge alone.
struct ExternalID: Hashable, Codable, Sendable, CustomStringConvertible {
    enum Scheme: String, Codable, Sendable, CaseIterable {
        case mbid, mbWork, mbReleaseGroup, iswc, isrc, upc, wikidata, tmdbMovie, tmdbTV, tmdbPerson, tmdbCollection,
             imdbTitle, imdbName, discogs, appleID, spotifyID, ytVideo, ytChannel
        /// The value is the existing `providerID:id` uid of a saved item.
        case provider
        /// The value is a catalogue key (`phonetic title | first artist | version tags`); several recordings may share it.
        case canon
        /// The value is the UUID of a local playlist or other local object.
        case localUUID
    }
    enum Strength: String, Codable, Sendable { case strong, weak }

    var scheme: Scheme
    var value: String

    init(scheme: Scheme, value: String) { self.scheme = scheme; self.value = Self.canonical(scheme, value) }
    init(_ scheme: Scheme, _ value: String) { self.scheme = scheme; self.value = Self.canonical(scheme, value) }

    /// Providers that serve the same YouTube ids (channel, video, album, playlist). A provider uid is kept under one spelling ("ytmusic:") so an artist, album or song
    /// opened from any of them finds the one entity that holds the credits, instead of a second, empty copy.
    static let youTubeFamily = ["youtube-music", "youtube", "piped", "invidious"]
    static func canonical(_ scheme: Scheme, _ value: String) -> String {
        guard scheme == .provider else { return value }
        for p in youTubeFamily where value.hasPrefix(p + ":") { return "ytmusic:" + value.dropFirst(p.count + 1) }
        return value
    }

    var strength: Strength { Self.strength(of: scheme) }
    var isStrong: Bool { strength == .strong }

    static func strength(of scheme: Scheme) -> Strength {
        switch scheme {
        case .mbid, .mbWork, .mbReleaseGroup, .wikidata, .tmdbMovie, .tmdbTV, .tmdbPerson, .tmdbCollection, .imdbTitle, .imdbName, .provider, .ytChannel, .localUUID: .strong
        case .iswc, .isrc, .upc, .discogs, .appleID, .spotifyID, .ytVideo, .canon: .weak
        }
    }

    /// The text an id is derived from when this is the entity's first alias.
    var aliasKey: String { scheme == .provider ? value : scheme.rawValue + ":" + value }
    var description: String { scheme.rawValue + ":" + value }
}

/// One spelling of an entity's name: the original script, a romanised form, a translation. They feed search.
struct NameAlias: Hashable, Codable, Sendable {
    var text: String
    var lang: String?
    var script: String?
    var isPrimary: Bool
    var source: String?

    init(_ text: String, lang: String? = nil, script: String? = nil, isPrimary: Bool = false, source: String? = nil) {
        self.text = text; self.lang = lang; self.script = script; self.isPrimary = isPrimary; self.source = source
    }
    /// The folded Latin skeleton used for matching across scripts and spellings.
    var latin: String { MusicGraphText.latin(text) }
}
