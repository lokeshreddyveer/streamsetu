import Foundation

/// Names of the services Music gets its content from. Music pages never print a source as passive text (a caption under a card, a line in a header): the owner asked for that
/// again and again. Providers fill a playlist's "summary" or "owner" with their own name (a YouTube playlist is "by YouTube Music"), so every place that shows those goes through
/// `clean`, which drops text that only names a source. A source can still be shown inside a control the person opens on purpose (Settings, the lyrics source picker).
enum MusicSourceText {
    private static let names: [String] = [
        "youtube music", "youtube", "yt music", "jiosaavn", "jio saavn", "saavn", "audius", "soundcloud", "spotify", "apple music", "apple", "itunes", "deezer", "gaana", "wynk",
        "wynk music", "tidal", "amazon music", "bandcamp", "piped", "invidious", "lrclib", "musixmatch", "genius", "musicbrainz", "last.fm", "lastfm", "listenbrainz",
        "subsonic", "navidrome", "jellyfin", "plex", "local files", "radio browser", "internet archive", "napster", "qobuz", "hungama", "resso",
    ]

    /// True when the whole text is only a source's name (optionally with "by", "from", a bracket note such as "(basic)", or a trailing "Music").
    static func isSource(_ text: String) -> Bool {
        var t = MusicText.normalize(text.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression))
        guard !t.isEmpty else { return false }
        for prefix in ["by ", "from ", "on ", "via ", "source "] where t.hasPrefix(prefix) { t = String(t.dropFirst(prefix.count)) }
        if let r = t.range(of: " (") { t = String(t[..<r.lowerBound]) }
        t = t.trimmingCharacters(in: .whitespaces)
        return names.contains(t)
    }

    /// The text, or nil when it only names a source.
    static func clean(_ text: String?) -> String? {
        guard let s = text?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, !isSource(s) else { return nil }
        return s
    }
}
