import Foundation

/// What a hero says about its album, as plain text rules (no view, so they can be checked on their own and are not tied to the main thread).
enum MusicHeroText {
    /// The artists as one line, without the placeholders a source writes when it does not know (so a real album never reads "Unknown artist").
    static func credit(_ artists: [MusicArtistRef]) -> String {
        artists.filter { MusicCompilationArtist.isUsableArtist($0) && !isPlaceholder($0.name) }.map(\.name).joined(separator: ", ")
    }

    /// A name a source writes when it does not know the artist. Unlike `isPlaceholder`, "Various Artists" is not in it: that is a real credit.
    static func isUnknown(_ name: String) -> Bool { MusicArtistFiller.isFiller(name) }

    /// The artists as one line for a card or a subtitle: the names a source gave, without its "Unknown artist" filler.
    static func cardCredit(_ artists: [MusicArtistRef]) -> String { artists.filter { !isUnknown($0.name) }.map { MusicNativeNames.shared.artist(MusicArtistRef(id: "", name: $0.name), provider: "") ?? $0.name }.joined(separator: ", ") }

    static func isPlaceholder(_ name: String) -> Bool {
        ["unknown artist", "unknown", "various artists", "n/a", ""].contains(MusicText.normalize(name))
    }

    /// "Single · 2026 · 1 song": what the album is, from the facts the source gave, in that order; a fact that is missing is simply not said.
    static func meta(for a: MusicAlbum) -> String {
        var parts: [String] = []
        switch MusicReleaseKind.classify(a) {
        case .single: parts.append(Localized.string("Single"))
        case .ep: parts.append(Localized.string("EP"))
        case .album: parts.append(Localized.string("Album"))
        case .appearsOn: break
        }
        if let d = a.releaseDate, d.count >= 4, Int(d.prefix(4)) != nil { parts.append(String(d.prefix(4))) }
        if let n = a.totalTracks, n > 0 { parts.append(Localized.plural(n, one: "%@ song", other: "%@ songs")) }
        return parts.joined(separator: " · ")
    }
}
