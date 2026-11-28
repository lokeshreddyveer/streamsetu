import Foundation

// Small pure rules the person page shares: which songs "Play" uses, how a provider uid splits, how an image reference becomes an address, and how
// the filmography grid filters (kept in page memory so Back returns to the same filter).

/// `providerID:itemID` (the app's existing uid). The provider id never contains a colon; an item id may.
enum MusicProviderUID {
    static func split(_ uid: String) -> (providerID: String, id: String)? {
        guard let i = uid.firstIndex(of: ":") else { return nil }
        let p = String(uid[..<i]), id = String(uid[uid.index(after: i)...])
        return p.isEmpty || id.isEmpty ? nil : (p, id)
    }

    /// The provider uids among an entity's external ids, in order.
    static func uids(in ids: [ExternalID]) -> [String] { ids.filter { $0.scheme == .provider }.map(\.value) }

    /// The first of the person's provider artists that the library already follows, so a person with two provider ids shows Follow state for the one followed.
    static func followedArtist(in uids: [String], followed: Set<String>) -> (providerID: String, id: String)? {
        uids.first { followed.contains($0) }.flatMap { split($0) }
    }
}

/// What an entry's `imageRef` means to a picture view: an https address, or nothing (the view shows initials or a placeholder).
enum MusicPersonImage {
    static func address(_ imageRef: String?, width: Int = 300) -> String? {
        MusicPortraitRef.resolve(imageRef: imageRef, width: width)?.url.absoluteString
    }
}

/// Which songs Play and Shuffle use for the active role (the owner's "top songs of the active role").
enum MusicPersonPlaySource: Hashable, Sendable {
    /// Recordings in order; resolved to playable tracks through their provider uids.
    case songs([MusicEntityID])
    /// No song list in this view: the first soundtrack or album, played from the provider's own tracklist.
    case albums([MusicEntityID])
    /// Nothing from the graph yet: the provider's own top tracks of this artist (so Play works at once).
    case providerArtist

    static let maxSongs = 25

    static func choose(_ data: MusicPersonViewData?) -> MusicPersonPlaySource {
        guard let data else { return .providerArtist }
        let songSections: [MusicPersonSectionID]
        switch data.view {
        case .singer: songSections = [.topSongs]
        case .composer: songSections = [.popularCompositions]
        case .lyricist: songSections = [.songsWritten]
        case .actor: songSections = [.songsFromMovies]
        case .director: songSections = []
        case .producer: songSections = [.producedSongs]
        case .instrumentalist: songSections = [.instrumentSongs]
        case .conductor: songSections = [.conductedSongs]
        case .label: songSections = [.labelCatalogue]
        }
        for id in songSections {
            let songs = data.section(id)?.entries.filter { MusicEntityKind.recording == $0.kind || $0.kind == .track || $0.kind == .work } ?? []
            if !songs.isEmpty { return .songs(songs.prefix(maxSongs).map(\.id)) }
        }
        let albumSections: [MusicPersonSectionID] = data.view == .director ? [.filmSoundtracks] : (data.view == .actor ? [.movieSoundtracks] : (data.view == .composer ? [.soundtracks, .albums] : [.albums]))
        for id in albumSections {
            let a = data.section(id)?.entries.filter { MusicPersonReader.albumKinds.contains($0.kind) } ?? []
            if !a.isEmpty { return .albums(a.prefix(2).map(\.id)) }
        }
        return .providerArtist
    }
}

/// The filmography grid's filters: a decade and a language, both optional. Stored in page memory as short text.
struct MusicFilmographyFilter: Hashable, Sendable {
    var decade: Int?
    var language: String?
    static let none = MusicFilmographyFilter()
    var isActive: Bool { decade != nil || language != nil }

    init(decade: Int? = nil, language: String? = nil) { self.decade = decade; self.language = language }

    init(memory filters: [String: String]) {
        decade = filters["decade"].flatMap(Int.init)
        language = filters["language"].flatMap { $0.isEmpty ? nil : $0 }
    }
    func write(to filters: inout [String: String]) {
        if let decade { filters["decade"] = String(decade) } else { filters["decade"] = nil }
        if let language { filters["language"] = language } else { filters["language"] = nil }
    }

    func apply(to entries: [MusicPersonEntry]) -> [MusicPersonEntry] {
        entries.filter { e in
            if let d = decade, (e.year.map { $0 / 10 * 10 }) != d { return false }
            if let l = language, MusicPersonReader.languageCode(e.lang) != l { return false }
            return true
        }
    }

    /// Decades present in the entries, newest first; only offered when there is more than one (a single choice filters nothing).
    static func decades(in entries: [MusicPersonEntry]) -> [Int] {
        let d = Set(entries.compactMap { $0.year.map { $0 / 10 * 10 } })
        return d.count > 1 ? d.sorted(by: >) : []
    }
    static func languages(in entries: [MusicPersonEntry]) -> [String] {
        let l = Set(entries.compactMap { MusicPersonReader.languageCode($0.lang) })
        return l.count > 1 ? l.sorted() : []
    }
}
