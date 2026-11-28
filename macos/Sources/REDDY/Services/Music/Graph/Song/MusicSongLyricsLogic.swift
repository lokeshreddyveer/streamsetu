import Foundation

// What the lyrics block of the song page shows (item 9). Pure: the view maps the lyric service's load state onto these inputs. The lyric service,
// the translation service and the romaniser stay the only sources; this only decides what is on screen.

enum MusicSongLyricsLogic {
    enum Display: Equatable, Sendable {
        /// Looking: a placeholder of the final height.
        case skeleton
        case instrumental
        /// The first `shown` lines of `total`, and whether they are time-synced lyrics.
        case lines(shown: [String], total: Int, synced: Bool)
        /// Nothing found (`missed` true) or not looked up yet (false: the page shows a "Find lyrics" button, never a fetch on load).
        case none(missed: Bool)
    }

    /// `loading`: a lookup is running. `finished`: the lookup ended (found or not).
    static func display(lyrics: MusicLyrics?, loading: Bool, finished: Bool, limit: Int = 12) -> Display {
        if let l = lyrics {
            if l.instrumental { return .instrumental }
            let all = lines(of: l)
            if all.isEmpty { return .none(missed: true) }
            return .lines(shown: Array(all.prefix(max(1, limit))), total: all.count, synced: !(l.synced ?? []).isEmpty)
        }
        if loading { return .skeleton }
        return .none(missed: finished)
    }

    /// The lead text of each line, without the empty ones and without bracketed section markers such as "[Chorus]".
    static func lines(of l: MusicLyrics) -> [String] {
        if let synced = l.synced, !synced.isEmpty {
            return synced.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return (l.plain ?? "").components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !($0.hasPrefix("[") && $0.hasSuffix("]")) }
    }

    /// Romanisation is offered only when some line is not already in Latin letters.
    static func needsRomanisation(_ lines: [String]) -> Bool {
        lines.contains { line in line.unicodeScalars.contains { $0.properties.isAlphabetic && $0.value > 0x24F } }
    }

    /// Translation of lyrics that belong to the playing song goes through the app's shared translation service, so the panel and this page stay in step.
    /// Another song's lyrics use the page's own service: nothing is ever changed under the player's lyrics.
    static func usesSharedTranslation(pageTrackUID: String, playingUID: String?) -> Bool { pageTrackUID == playingUID }
}
