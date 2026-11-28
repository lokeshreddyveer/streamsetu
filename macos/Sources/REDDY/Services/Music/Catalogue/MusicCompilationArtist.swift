import Foundation

/// "Various Artists", "Soundtrack", "Original Cast" and their translations name a compilation, not a person. They are never an artist identity:
/// no "More by", no "Related by artist", no artist link, no artist radio may be built from them. Where such a credit sits on a song, the real
/// contributors (singers, composers, music director) from the credits stand in for it, or the section is hidden.
enum MusicCompilationArtist {
    /// Whole-name phrases (written plainly; they are folded with `MusicText.normalize`, which also drops combining marks, before comparing).
    private static let phrases: [String] = [
        "various artists", "various artist", "various", "va", "v a", "v.a.", "multiple artists", "assorted artists", "mixed artists", "unknown artist",
        "soundtrack", "original soundtrack", "original motion picture soundtrack", "original score", "ost", "film soundtrack", "movie soundtrack",
        "original cast", "original cast recording", "original broadway cast", "cast recording", "original cast album",
        "varios artistas", "varios", "artistas varios", "artistes divers", "divers", "verschiedene interpreten", "diverse artisti", "artisti vari", "varios interpretes",
        "विभिन्न कलाकार", "अलग अलग कलाकार", "वेरियस आर्टिस्ट्स", "वेरियस आर्टिस्ट", "विविध कलाकार",
        "వివిధ కళాకారులు", "వివిధ గాయకులు", "వివిధ కళాకారుల", "వేరియస్ ఆర్టిస్ట్స్",
        "பல்வேறு கலைஞர்கள்", "பலர்", "வேரியஸ் ஆர்ட்டிஸ்ட்ஸ்",
        "ವಿವಿಧ ಕಲಾವಿದರು", "വിവിധ കലാകാരന്മാർ", "বিভিন্ন শিল্পী", "ਵੱਖ ਵੱਖ ਕਲਾਕਾਰ", "વિવિધ કલાકારો",
        "オムニバス", "ヴァリアス アーティスト", "ヴァリアス・アーティスト", "다양한 아티스트", "群星", "合辑", "羣星", "разные исполнители", "various interpreters"
    ]

    /// Words that may follow the compilation name ("Various Artists - Telugu", "Various Artists Hits").
    private static let trailing: Set<String> = [
        "telugu", "hindi", "tamil", "kannada", "malayalam", "punjabi", "bengali", "marathi", "gujarati", "bhojpuri", "urdu", "english",
        "songs", "hits", "collection", "compilation", "music", "film", "movie", "album", "2024", "2025", "2026"
    ]

    private static let folded: Set<String> = Set(phrases.map { MusicText.normalize($0) }.filter { !$0.isEmpty })

    /// True when the credit is a compilation label rather than a person or group.
    static func isCompilation(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if matches(trimmed) { return true }
        // "Various Artists - Telugu", "Various Artists (Hindi)", "Soundtrack: Jailer": the part before the separator decides.
        for sep in [" - ", " – ", " — ", " | ", " : ", ":", "(", "["] {
            if let r = trimmed.range(of: sep), r.lowerBound > trimmed.startIndex {
                let head = String(trimmed[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                if !head.isEmpty, matches(head) { return true }
            }
        }
        return false
    }

    private static func matches(_ s: String) -> Bool {
        var words = MusicText.normalize(s).split(separator: " ").map(String.init)
        if words.isEmpty { return false }
        if folded.contains(words.joined(separator: " ")) { return true }
        while words.count > 1, let last = words.last, trailing.contains(last) { words.removeLast() }
        return folded.contains(words.joined(separator: " "))
    }

    /// The names that are real artists, in order, each once.
    static func meaningful(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { !isCompilation($0) && seen.insert(MusicText.normalize($0)).inserted && !MusicText.normalize($0).isEmpty }
    }

    /// The artists a "More by" or "Related" section may be built from: the credited artists without compilation labels; when nothing is left,
    /// the real contributors (in the order the caller lists them: singers, then composers, then music director). Empty means hide the section.
    static func usableArtists(credited: [String], contributors: [String]) -> [String] {
        let real = meaningful(credited)
        return real.isEmpty ? meaningful(contributors) : real
    }

    static func isUsableArtist(_ ref: MusicArtistRef) -> Bool { !isCompilation(ref.name) }

    /// The credit a "Go to artist" or "Block artist" action acts on: the first one that is a real artist (not "Various Artists") and has an id of its own. An id-less
    /// credit is only a name and would be matched by name (a namesake), and a block is keyed by id, so neither action may use it. Nil hides the action.
    static func primary(in refs: [MusicArtistRef]) -> MusicArtistRef? { refs.first { isUsableArtist($0) && !$0.id.isEmpty } }
}
