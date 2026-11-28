import Foundation

// Filling in what a local file's own tags left blank, from a permitted source's answer for the same recording. Only blank fields are filled, and only when
// the answer is clearly the same song: the title matches, the artist matches (or the file names none) and the lengths agree.

enum MusicMetadataFill {
    static let lengthToleranceMs: Int64 = 6_000

    static func isBlank(_ s: String?) -> Bool {
        guard let s else { return true }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || MusicArtistFiller.isFiller(t)
    }

    /// The candidate that is the same recording as the file, or nil.
    static func best(for e: LocalEntry, in candidates: [MusicTrack]) -> MusicTrack? {
        let title = MusicText.normalize(e.title)
        guard !title.isEmpty else { return nil }
        let artist = MusicText.normalize(LocalLibraryIndex.primaryArtist(of: e))
        return candidates.first { c in
            guard MusicText.normalize(c.title) == title else { return false }
            if !isBlank(e.artist), !artist.isEmpty {
                let names = c.artists.map { MusicText.normalize($0.name) }
                guard names.contains(where: { $0 == artist || $0.contains(artist) || artist.contains($0) }) else { return false }
            }
            if e.durationMs > 0, c.durationMs > 0, abs(e.durationMs - c.durationMs) > lengthToleranceMs { return false }
            return true
        }
    }

    /// What the answer can add: each field only where the file has none.
    static func patch(for e: LocalEntry, from c: MusicTrack) -> LocalEntryPatch {
        var p = LocalEntryPatch()
        if isBlank(e.artist), let a = c.artists.first?.name { p.artist = a }
        if e.albumTagged != true || isBlank(e.album), let al = c.album?.title, !al.isEmpty { p.album = al }
        if isBlank(e.albumArtist), let a = c.album?.artists.first?.name ?? c.artists.first?.name { p.albumArtist = a }
        if isBlank(e.genre), let g = c.creditBundle?.hints?.genre { p.genre = g }
        if e.year == nil, let y = c.creditBundle?.hints?.year ?? c.album?.releaseDate.flatMap({ Int($0.prefix(4)) }) { p.year = y }
        if e.trackNumber == nil, let n = c.trackNumber { p.trackNumber = n }
        if e.discNumber == nil, let n = c.discNumber { p.discNumber = n }
        return p
    }
}
