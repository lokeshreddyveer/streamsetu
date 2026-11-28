import Foundation

// Editing what the library shows for local files. The change is kept in StreamSetu's own index (the files and their tags are never touched), and a
// field left as `nil` in the patch is left alone, so one patch can change a single song or give a whole album the same artist.

struct LocalEntryPatch: Equatable, Sendable {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var genre: String?
    var year: Int?
    var trackNumber: Int?
    var discNumber: Int?

    var isEmpty: Bool { self == LocalEntryPatch() }

    private static func clean(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// The entry with the patch applied. Blank text never replaces a value.
    func applied(to e: LocalEntry) -> LocalEntry {
        var out = e
        if let v = Self.clean(title) { out.title = v }
        if let v = Self.clean(artist) { out.artist = v }
        if let v = Self.clean(album) { out.album = v; out.albumTagged = true }
        if let v = Self.clean(albumArtist) { out.albumArtist = v }
        if let v = Self.clean(genre) { out.genre = v }
        if let v = year, (1000...2999).contains(v) { out.year = v }
        if let v = trackNumber, v > 0 { out.trackNumber = v }
        if let v = discNumber, v > 0 { out.discNumber = v }
        return out
    }
}

extension LocalLibraryIndex {
    /// Applies `patch` to the entries with these ids. Returns how many changed.
    @discardableResult
    mutating func edit(ids: Set<String>, patch: LocalEntryPatch) -> Int {
        var changed = 0
        for i in entries.indices where ids.contains(entries[i].id) {
            let next = patch.applied(to: entries[i])
            if next != entries[i] { entries[i] = next; changed += 1 }
        }
        return changed
    }
}
