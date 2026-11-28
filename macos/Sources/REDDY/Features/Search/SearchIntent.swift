import Foundation

/// What the top search box should do with text when Return is pressed and no result row is highlighted: look it up (`.search`) or hand it to Setu (`.ask`).
///
/// The rule, in one place so the box, the results page and the tests agree:
/// - Classification only chooses the DEFAULT for a bare Return when no row has been highlighted with the arrow keys or the pointer. It never overrides a row the person picked: a song called
///   "How Deep Is Your Love" still opens when its row is highlighted and Return is pressed (see `returnAction`).
/// - A question or request is recognised by its shape: a question or request frame ("how do I", "why is my", "where is the", "turn on", "open") followed by something that is about the app
///   (a feature, a setting, a screen) or by an action verb; a complaint about a feature ("subtitles not working"); a question mark after something about the app; a natural-language play request ("play something
///   relaxing"); or the Hinglish and Telugu-in-Latin-letters equivalents ("subtitles kaise on kare", "song play ela").
/// - Anything that merely STARTS like a question but names nothing about the app is a title: "How Deep Is Your Love", "Where Is My Mind", "Who Framed Roger Rabbit?", "Kaise Hua", "How To Train Your Dragon".
/// - Shift+Return forces `.ask`; Option+Return forces `.search`. Command+Return also asks (kept from before).
/// The function is pure: no I/O, no app state. The words it knows are the app's own feature names, not a catalogue of titles.
enum SearchIntent: Equatable, Sendable {
    case search, ask

    static func classify(_ query: String) -> SearchIntent {
        let words = tokens(query)
        guard !words.isEmpty else { return .search }
        let mark = query.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
        let padded = " " + words.joined(separator: " ") + " "
        let aboutApp = mentionsApp(words, padded)
        func starts(_ phrases: [String]) -> String? { phrases.first { padded.hasPrefix(" \($0) ") || padded == " \($0) " } }

        // Talking to Setu directly, or asking for help.
        if starts(["setu", "hey setu", "hi setu", "ok setu", "ask setu"]) != nil { return .ask }
        if words == ["help"] || words == ["help", "me"] || words == ["help", "please"] { return .ask }

        // A question or request frame followed by something about the app or an action verb.
        if let frame = starts(questionFrames) {
            let rest = Array(words.dropFirst(frame.split(separator: " ").count))
            if !rest.isEmpty, mentionsApp(rest, " " + rest.joined(separator: " ") + " ") || verbs.contains(rest[0]) { return .ask }
        }
        // An imperative that names something in the app: "open settings", "turn on subtitles".
        if let verb = starts(imperatives) {
            let rest = Array(words.dropFirst(verb.split(separator: " ").count))
            if !rest.isEmpty, mentionsApp(rest, " " + rest.joined(separator: " ") + " ") { return .ask }
        }
        // "play something relaxing", "play my favourites".
        if words.first == "play", words.count >= 2, naturalPlay.contains(words[1]) || starts(["play the latest", "play the last", "play the next", "play a random", "play some", "play me"]) != nil { return .ask }
        // A complaint about a feature: "my guide is empty", "subtitles not working", "login error 401".
        if words.count >= 2, aboutApp, complaints.contains(where: { padded.contains(" \($0) ") }) { return .ask }
        // A question mark after something about the app: "is my backup running?".
        if mark, aboutApp, words.count >= 3 { return .ask }
        // Hinglish and Telugu in Latin letters.
        if words.count >= 2, words.contains(where: { hinglishCues.contains($0) }) {
            if aboutApp || words.contains(where: { hinglishObjects.contains($0) }) { return .ask }
        }
        if words.count >= 3, words.contains("nahi") || words.contains("nahin") || words.contains("ledu"), aboutApp || words.contains(where: { hinglishObjects.contains($0) }) { return .ask }
        return .search
    }

    /// What a Return press does. `hasHighlightedRow` means the person moved to a result with the arrow keys or the pointer; the row that is only "first by default" does not count.
    enum ReturnMode: Equatable, Sendable { case automatic, forceAsk, forceSearch }
    enum ReturnAction: Equatable, Sendable { case openHighlighted, ask, search, nothing }

    static func returnAction(query: String, mode: ReturnMode, hasHighlightedRow: Bool) -> ReturnAction {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .nothing }
        switch mode {
        case .forceAsk: return .ask
        case .forceSearch: return hasHighlightedRow ? .openHighlighted : .search
        case .automatic:
            if hasHighlightedRow { return .openHighlighted }
            return classify(query) == .ask ? .ask : .search
        }
    }

    // MARK: vocabulary

    static func tokens(_ raw: String) -> [String] {
        let s = raw.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "'", with: "")
        return String(s.map { $0.isLetter || $0.isNumber ? $0 : " " }).split(separator: " ").map(String.init)
    }

    static func mentionsApp(_ words: [String], _ padded: String) -> Bool {
        for w in words where appWords.contains(w) || (w.hasSuffix("s") && appWords.contains(String(w.dropLast()))) { return true }
        return appPhrases.contains { padded.contains(" \($0) ") }
    }

    private static let questionFrames: [String] = [
        "how do i", "how can i", "how do you", "how would i", "how should i", "how to", "can i", "can you", "could you", "could i", "should i", "is there a way", "is it possible", "do you support",
        "does it support", "does streamsetu", "does setu", "what does", "what is the", "what are the", "what happens", "why is my", "why does my", "why is the", "why does the", "why are my", "why do my",
        "why cant", "why wont", "why isnt", "why doesnt", "why dont", "why do i", "why did", "why is", "where is my", "where is the", "where are my", "where are the", "where can i", "where do i",
        "where to", "which setting", "which screen", "is my", "are my", "is the", "are the", "is there", "will it", "will my", "tell me", "explain", "show me", "take me", "let me", "i want to",
        "i need to", "i cant", "i can not", "i wont", "i am unable", "i dont know how", "what is my", "what is a", "what is an", "whats the", "how come", "how much", "how many",
    ]

    private static let imperatives: [String] = [
        "open", "go to", "take me to", "turn on", "turn off", "turn up", "turn down", "switch to", "switch off", "switch on", "enable", "disable", "change", "set", "add", "remove", "delete", "clear",
        "stop", "start", "fix", "reset", "mute", "unmute", "pause", "skip", "connect", "sign in", "sign out", "import", "export", "download", "hide", "rename", "show", "find", "increase", "decrease",
    ]

    private static let naturalPlay: Set<String> = ["something", "anything", "whatever", "my", "random", "latest", "newest", "last", "next", "songs", "music", "movies", "any", "some", "me"]

    private static let verbs: Set<String> = [
        "add", "remove", "delete", "change", "turn", "switch", "set", "enable", "disable", "fix", "find", "open", "stop", "start", "pause", "skip", "clear", "reset", "create", "connect", "sign",
        "import", "export", "download", "record", "share", "hide", "check", "update", "refresh", "restore", "pair", "block", "mute", "unmute", "rename", "sort", "filter", "save", "install",
        "increase", "decrease", "raise", "lower", "sync", "backup", "cast", "scrobble",
    ]

    static let complaints: [String] = [
        "not working", "doesnt work", "dont work", "isnt working", "arent working", "stopped working", "wont work", "wont play", "wont load", "wont open", "cant play", "cant open", "cant find",
        "cannot", "failed", "failing", "error", "broken", "stuck", "missing", "empty", "blank", "keeps stopping", "keeps freezing", "freezing", "crashing", "no sound", "out of sync", "not showing",
        "not loading", "not syncing", "too loud", "too quiet", "too slow",
    ]

    static let appWords: Set<String> = [
        "setting", "preference", "subtitle", "subs", "caption", "audio", "playlist", "source", "guide", "epg", "xmltv", "channel", "favourite", "favorite", "history", "profile", "kids", "parental", "lock",
        "backup", "icloud", "sync", "download", "recording", "record", "reminder", "notification", "theme", "language", "quality", "engine", "player", "buffering", "buffer", "volume", "sound", "queue",
        "lyrics", "lyric", "equalizer", "crossfade", "shuffle", "repeat", "library", "streamsetu", "app", "playback", "stream", "proxy", "vpn", "dns", "pin", "password", "login", "account", "xtream",
        "m3u", "plex", "jellyfin", "emby", "stalker", "multiview", "shortcut", "keyboard", "cache", "storage", "version", "tmdb", "artwork", "poster", "statistic", "scrobbling", "lastfm", "airplay",
        "chromecast", "podcast", "offline", "autoplay", "playlists", "sidebar", "tab", "screen", "menu", "button", "widget", "siri", "scrobble", "cast", "collection", "watchlist", "radio",
        "explore", "devices", "room", "equaliser", "karaoke", "automix", "wallpaper", "zoom", "fullscreen", "pip", "tuner", "hdhomerun", "webdav", "trakt", "debrid", "mpv", "avplayer", "hdr", "mkv", "hevc",
        "bitrate", "resolution", "aspect", "deinterlace", "bufferingmode", "sleep", "timer", "speed", "mini", "theatre", "theater", "stats", "hotkey", "hotkeys", "notifications", "settings",
    ]

    static let appPhrases: [String] = [
        "live tv", "watch later", "continue watching", "sleep timer", "app lock", "tv guide", "multi view", "audio language", "smart mix", "listen now", "listen together", "menu bar", "side panel",
        "top bar", "dark mode", "light mode", "picture in picture", "mini player", "play next", "up next", "recently added", "watch history", "now playing", "search bar", "go back", "full screen",
    ]

    static let hinglishCues: Set<String> = [
        "kaise", "kaisey", "kese", "kaisay", "kyun", "kyu", "kyon", "kahan", "kahaan", "kidhar", "ela", "ekkada", "enduku", "endhuku", "cheyali", "cheyyali", "cheppu", "cheppandi", "batao", "bataiye",
        "dikhao", "dikhaiye", "karna", "karu", "karun", "karein", "kare", "chalao", "lagao", "hatao", "kholo", "khole", "badlo", "badle", "badlu", "chalu", "chupinchu", "kavali", "cheyyandi",
    ]

    private static let hinglishObjects: Set<String> = [
        "play", "song", "songs", "gaana", "gane", "video", "movie", "film", "sound", "awaaz", "on", "off", "bada", "chota", "bigger", "smaller", "pause", "volume", "next", "previous",
    ]
}
