import Foundation

/// Lyrics in the wrong language are worse than none: a Telugu song must not show the Hindi-dub words that share its title and length. The expected language comes from what the
/// song says about itself (its source's stated language, its title and album, "(Telugu)" tags); the lyric's own writing system is counted. A lyric in another non-Latin script
/// is turned away unless the expected script is a real part of it. Latin-script lyrics always pass (a romanised song is fine), and a song whose language is unknown accepts anything.
/// Applies to every language and every source, not to one song.
enum MusicLyricsLanguageGuard {
    /// The language the song is expected in. Only enforced when every signal that names a non-Latin language agrees: the source's stated language, and the title and album (their
    /// script or a plain "(Telugu)" tag). When they disagree (a source filing a Telugu song under Hindi) nothing is enforced, so correct lyrics are never turned away on a doubt.
    /// The artist is not a signal: where an artist comes from is not what language a song is in.
    static func expected(track: MusicTrack, locale _: MusicLyricsLocale) -> MusicLanguage? {
        let text = MusicLyricsLocale.detect(title: track.title, artists: "", album: track.album?.title).language
        let signals = Set([MusicLanguageDetector.stated(track), text].compactMap { $0 }.filter { $0 != .latin })
        return signals.count == 1 ? signals.first : nil
    }

    /// The text that is counted: the synced lines or the plain text, a bounded sample.
    static func sample(_ l: MusicLyrics) -> String {
        if let s = l.synced, !s.isEmpty { return s.prefix(60).map(\.text).joined(separator: " ") }
        return String((l.plain ?? "").prefix(4000))
    }

    static func accepts(_ l: MusicLyrics, expected: MusicLanguage?) -> Bool {
        guard let expected, !l.instrumental else { return true }
        let counts = MusicLanguageDetector.scriptCounts(sample(l)).filter { $0.key != .latin }
        let total = counts.values.reduce(0, +)
        guard total >= 12 else { return true }                       // too little non-Latin text to judge
        // Scripts a language is also written in: Hindi and Urdu songs are printed in Devanagari or in Arabic script, so either passes.
        let accepted: Set<MusicLanguage> = expected == .hindi ? [.hindi, .arabic] : expected == .arabic ? [.arabic, .hindi] : [expected]
        let mine = accepted.reduce(0) { $0 + (counts[$1] ?? 0) }
        return Double(mine) / Double(total) >= 0.25                  // the expected script is a real part of it (mixed songs pass)
    }
}
