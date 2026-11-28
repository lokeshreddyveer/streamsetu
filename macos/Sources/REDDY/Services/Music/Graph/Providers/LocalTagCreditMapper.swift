import Foundation

/// Credits from a local file's own tags (ID3 and MP4): artist, album artist, composer, lyricist, conductor and the work or grouping.
enum LocalTagCreditMapper {
    static let sourceID = "local"

    static func bundle(for e: LocalEntry) -> MusicCreditBundle? {
        var c = MusicCreditCollector()
        c.addNames(e.composer, role: .composer)
        c.addNames(e.lyricist, role: .lyricist)
        c.addNames(e.conductor, role: .conductor)
        if let aa = e.albumArtist { c.addNames(aa, role: .albumArtist, level: .album) }
        var h = MusicProviderHints()
        h.work = MusicCreditCollector.cleanName(e.work)
        // The tagged artist is already the item's artist; only the roles the tags add are credits.
        return c.bundle(hints: h.isEmpty ? nil : h)
    }
}
