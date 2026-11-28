import Foundation

/// The one place the person's first-run choices (languages, genres liked, loved or not for them, artists) become inputs. Recently Added asks here; Radio and autoplay read the not-for-me
/// genres (`MusicTastePrefs.dislikesGenre`). Listen Now (listening only) and Explore (the same for everyone) deliberately never ask: tests guard that.
@MainActor
enum MusicTasteBias {
    static func languages(_ p: MusicTastePrefs = MusicTastePreferences.shared.prefs) -> [MusicLanguage] {
        p.languages.sorted().compactMap(MusicLanguage.init(rawValue:))
    }

    /// Genres to lean toward, loved first, then liked (each in a stable order).
    static func genres(_ p: MusicTastePrefs = MusicTastePreferences.shared.prefs) -> [(name: String, loved: Bool)] {
        p.lovedGenres.subtracting(p.dislikedGenres).sorted().map { ($0, true) } + p.genres.subtracting(p.lovedGenres).subtracting(p.dislikedGenres).sorted().map { ($0, false) }
    }

    /// A search phrase for songs in one picked genre, in the person's first language when they chose one.
    static func genreQuery(_ genre: String, prefs p: MusicTastePrefs = MusicTastePreferences.shared.prefs) -> String {
        [languages(p).first?.englishName, genre, "songs"].compactMap { $0 }.joined(separator: " ")
    }
}
