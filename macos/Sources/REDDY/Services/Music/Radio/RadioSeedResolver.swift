import Foundation

// Turns words the person typed into a seed: a language they named, an artist or a song the active source finds, else the words themselves as a
// mood or genre. The decision is by what the source answers and by the language names the app already knows, never by a fixed list of genres.

enum RadioSeedWords {
    /// A language named by the words ("telugu", "Telugu songs", "hindi radio"), matched against the app's own language names.
    static func language(in text: String) -> MusicLanguage? {
        var t = MusicCategory.normalise(text)
        for tail in [" songs", " music", " radio", " hits"] where t.hasSuffix(tail) { t = String(t.dropLast(tail.count)) }
        return MusicLanguage.allCases.first {
            $0 != .latin && (MusicCategory.normalise($0.englishName) == t || MusicCategory.normalise($0.displayName) == t)
        }
    }

    /// True when the artist's name is what was typed (ignoring case, accents and punctuation), or starts with it when at least four letters were typed.
    static func matches(artist name: String, typed: String) -> Bool {
        let a = MusicCategory.normalise(name), t = MusicCategory.normalise(typed)
        return !t.isEmpty && (a == t || (t.count >= 4 && a.hasPrefix(t)))
    }

    static func display(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.prefix(1).uppercased() + t.dropFirst()
    }
}

@MainActor
enum RadioSeedResolver {
    static func resolve(_ typed: String, hub: MusicHub) async -> RadioSeed? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let l = RadioSeedWords.language(in: text) {
            MusicDebugLog.log("radio", "typed \"\(text)\" is the language \(l.englishName)")
            return .language(key: l.rawValue, name: l.englishName)
        }
        if let p = hub.registry.activeMetadata {
            if let a = (try? await p.searchArtists(text, page: nil))?.items.first(where: { RadioSeedWords.matches(artist: $0.name, typed: text) && !MusicCompilationArtist.isCompilation($0.name) }) {
                MusicDebugLog.log("radio", "typed \"\(text)\" is the artist \(a.name)")
                return .artist(a)
            }
            let t = MusicCategory.normalise(text)
            if let song = (try? await p.searchTracks(text, page: nil))?.items.first(where: { MusicCategory.normalise($0.title) == t && $0.isPodcast != true }) {
                MusicDebugLog.log("radio", "typed \"\(text)\" is the song \(song.title)")
                return .song(song)
            }
        }
        MusicDebugLog.log("radio", "typed \"\(text)\" used as words")
        return .mood(RadioSeedWords.display(text))
    }
}
