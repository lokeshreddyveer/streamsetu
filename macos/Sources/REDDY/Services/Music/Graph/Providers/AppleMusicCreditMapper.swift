import Foundation

/// iTunes Search and Lookup rows. The reply names the song's artist (with id), the album's artist, a genre and a release date; `composerName` is read
/// when a reply carries it (the probed song reply did not), never guessed.
enum AppleMusicCreditMapper: MusicProviderCreditSource {
    static let sourceID = "itunes"

    static func trackBundle(_ d: [String: Any]) -> MusicCreditBundle? {
        var c = MusicCreditCollector()
        c.add(d.str("artistName"), role: .primary, id: d.str("artistId"), level: .track)
        c.addNames(d.str("composerName"), role: .composer)
        if let album = d.str("collectionArtistName"), album.lowercased() != "various artists", album != d.str("artistName") {
            c.add(album, role: .albumArtist, id: d.str("collectionArtistId"), level: .album)
        }
        return c.bundle(hints: hints(d))
    }

    static func albumBundle(_ d: [String: Any]) -> MusicCreditBundle? {
        var c = MusicCreditCollector()
        if let a = d.str("artistName"), a.lowercased() != "various artists" { c.add(a, role: .primary, id: d.str("artistId"), level: .album) }
        return c.bundle(hints: hints(d))
    }

    /// The genre is the store's wording (`Soundtrack`, `Bollywood`); the year is the release date's, not necessarily the film's.
    static func hints(_ d: [String: Any]) -> MusicProviderHints? {
        var h = MusicProviderHints()
        h.genre = d.str("primaryGenreName")
        h.year = MusicProviderHints.year(d.str("releaseDate"))
        return h.isEmpty ? nil : h
    }
}
