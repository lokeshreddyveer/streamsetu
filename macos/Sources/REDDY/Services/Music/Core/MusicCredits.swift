import Foundation

// Credits a provider returned with an item, kept next to the item so the connected-universe graph can read them. Every field is optional on the
// item and every mapper fills it only from fields the provider actually sent: nothing here is inferred.

/// The role a provider gave a credited name. `primary` and `featured` are the provider's own billing; the rest are the people roles it names.
enum MusicCreditRole: String, Codable, Hashable, Sendable, CaseIterable {
    case primary, featured, singer, performer, music, composer, lyricist, writer, starring, producer, conductor, arranger, remixer, albumArtist, other

    /// A role is decoded leniently so an older build never fails on a newer role.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MusicCreditRole(rawValue: raw) ?? .other
    }
}

/// How specific a credit is: on the song, on the album, or only on the film the music belongs to.
enum MusicCreditLevel: String, Codable, Hashable, Sendable { case track, album, film }

/// One credited name exactly as a provider sent it.
struct MusicCredit: Codable, Hashable, Sendable {
    var name: String
    /// The provider's own id for the person, when it sent one (stored unprefixed, as the provider sent it).
    var providerArtistID: String? = nil
    var role: MusicCreditRole
    var level: MusicCreditLevel = .track
    /// For a performer: the instrument the provider named.
    var instrument: String? = nil
    /// For a film-level cast credit: the character, when the provider named one.
    var character: String? = nil
    /// The people inside a credited duo or group, only when a source listed them.
    var members: [MusicCredit]? = nil

    init(name: String, role: MusicCreditRole, providerArtistID: String? = nil, level: MusicCreditLevel = .track, instrument: String? = nil,
         character: String? = nil, members: [MusicCredit]? = nil) {
        self.name = name; self.role = role; self.providerArtistID = providerArtistID; self.level = level
        self.instrument = instrument; self.character = character; self.members = members
    }
}

/// Facts a provider sent that are not people: film, year, language, genre and the version it says the item is.
struct MusicProviderHints: Codable, Hashable, Sendable {
    var film: String? = nil
    var year: Int? = nil
    var language: String? = nil
    var genre: String? = nil
    /// `remix`, `cover` and so on, only when the provider's own fields said so (Audius remix and cover fields).
    var version: String? = nil
    /// The title (and artist) a cover or remix names as its source, when the provider sent them.
    var versionOf: String? = nil
    /// The classical work (or grouping) the file's tags name.
    var work: String? = nil

    var isEmpty: Bool { film == nil && year == nil && language == nil && genre == nil && version == nil && versionOf == nil && work == nil }
}

/// The credits and hints of one track or album. It compares equal to every other bundle and hashes to nothing, so adding credits to an item never
/// changes whether two copies of that item are the same (dedupe, queue and set logic keep working as before).
struct MusicCreditBundle: Codable, Hashable, Sendable {
    var credits: [MusicCredit] = []
    var hints: MusicProviderHints? = nil

    init(credits: [MusicCredit] = [], hints: MusicProviderHints? = nil) { self.credits = credits; self.hints = hints }

    var isEmpty: Bool { credits.isEmpty && (hints?.isEmpty ?? true) }

    static func == (a: MusicCreditBundle, b: MusicCreditBundle) -> Bool { true }
    func hash(into hasher: inout Hasher) {}
}

extension MusicTrack {
    var credits: [MusicCredit]? {
        get { creditBundle?.credits }
        set { updateBundle { $0.credits = newValue ?? [] } }
    }
    var hints: MusicProviderHints? {
        get { creditBundle?.hints }
        set { updateBundle { $0.hints = newValue } }
    }
    private mutating func updateBundle(_ change: (inout MusicCreditBundle) -> Void) {
        var b = creditBundle ?? MusicCreditBundle()
        change(&b)
        creditBundle = b.isEmpty ? nil : b
    }
}

extension MusicAlbum {
    var credits: [MusicCredit]? {
        get { creditBundle?.credits }
        set { updateBundle { $0.credits = newValue ?? [] } }
    }
    var hints: MusicProviderHints? {
        get { creditBundle?.hints }
        set { updateBundle { $0.hints = newValue } }
    }
    private mutating func updateBundle(_ change: (inout MusicCreditBundle) -> Void) {
        var b = creditBundle ?? MusicCreditBundle()
        change(&b)
        creditBundle = b.isEmpty ? nil : b
    }
}
