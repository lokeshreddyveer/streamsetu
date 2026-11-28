import Foundation

/// Which stored picture address is the better one. The first picture an entity is ever given used to stay for good, so a provider's small
/// thumbnail blocked the film poster or portrait that arrived later. A picture now replaces the stored one only when its source ranks higher
/// for that kind of thing; an equal or lower source never replaces it. Pure: it looks at the address only.
enum MusicImageRank {
    static func rank(_ address: String?, kind: MusicEntityKind) -> Int {
        guard let address, let host = URL(string: address)?.host?.lowercased() else { return address == nil ? 0 : 1 }
        func on(_ suffixes: String...) -> Bool { suffixes.contains { host == $0 || host.hasSuffix("." + $0) } }
        switch kind {
        case .film, .series, .person, .group:
            // The film database's own posters and portraits, and the encyclopaedia's files, are made for exactly this picture.
            if on("image.tmdb.org", "wikimedia.org", "wikipedia.org") { return 3 }
            if on("media-amazon.com", "mzstatic.com") { return 2 }
            return 1
        case .album, .release, .recording, .track:
            // A release's own cover from the archive or the store beats a streaming provider's resized thumbnail.
            if on("coverartarchive.org", "archive.org", "mzstatic.com") { return 3 }
            if on("dzcdn.net", "deezer.com") { return 2 }
            return 1
        default:
            return 1
        }
    }

    /// The address to keep: the stored one, unless the new one ranks strictly higher.
    static func better(stored: String?, new: String?, kind: MusicEntityKind) -> String? {
        guard let new, !new.isEmpty else { return stored }
        guard let stored, !stored.isEmpty else { return new }
        return rank(new, kind: kind) > rank(stored, kind: kind) ? new : stored
    }
}
