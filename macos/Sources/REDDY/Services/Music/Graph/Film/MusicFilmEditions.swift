import Foundation

/// What kind of release a film's soundtrack album is. A dub comes only from the documented dub-language relationship. A background score needs two agreeing signals: the album's own
/// words (as whole words, so "Scoreboard" is not a score) and its songs, where a score has no credited singers; an album whose songs are mostly sung stays a soundtrack even when
/// its title says "score" (songs and score on one album). Extended and remastered editions come from the title's whole words only, because no relationship states them. Nothing is
/// inferred from track count, so a single or an EP is not guessed.
enum MusicFilmEdition: Sendable, Equatable { case original, extended, remastered, score, dubbed }

enum MusicFilmEditionRules {
    static let scoreWords = ["background score", "bgm", "score", "instrumental", "themes", "theme music", "film score"]
    static let extendedWords = ["extended", "deluxe", "expanded"]
    static let remasterWords = ["remastered", "remaster", "re-release", "rerelease"]

    static func hasWord(_ text: String, in list: [String]) -> Bool {
        let t = " " + text.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : " " }.joined() + " "
        return list.contains { t.contains(" " + $0 + " ") }
    }

    /// `songs`: the songs of this album as the page holds them (empty while they are loading or unknown).
    static func classify(name: String, dubLanguage: String?, songs: [MusicFilmSongItem]) -> MusicFilmEdition {
        if dubLanguage != nil { return .dubbed }
        if hasWord(name, in: scoreWords) {
            if songs.isEmpty { return .original }   // two signals are needed; until the songs are known the album is not called a score
            let sung = songs.filter { !$0.singers.isEmpty }.count
            return Double(sung) / Double(songs.count) >= 0.5 ? .original : .score
        }
        if hasWord(name, in: remasterWords) { return .remastered }
        if hasWord(name, in: extendedWords) { return .extended }
        return .original
    }
}
