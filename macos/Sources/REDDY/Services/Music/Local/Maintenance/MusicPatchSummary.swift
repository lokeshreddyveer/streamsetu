import Foundation

enum MusicPatchSummary {
    /// "title, artist, year": which fields a change touched (the values are in the file's own tags, not repeated here).
    static func line(_ p: LocalEntryPatch) -> String {
        var f: [String] = []
        if p.title != nil { f.append("title") }
        if p.artist != nil { f.append("artist") }
        if p.album != nil { f.append("album") }
        if p.albumArtist != nil { f.append("album artist") }
        if p.genre != nil { f.append("genre") }
        if p.year != nil { f.append("year") }
        if p.trackNumber != nil { f.append("track number") }
        if p.discNumber != nil { f.append("disc number") }
        return f.joined(separator: ", ")
    }
}
