import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

/// What a typed request is about. Decided by plain rules before any model is asked, so the same words always lead to the same tools, and the app still answers when no AI is available.
enum AssistantIntent: String, Sendable, CaseIterable {
    case diagnosePlayback, diagnoseGuide, sourceHealth, engineAdvice, addSource, explainSettings, privacy, playbackControl, searchLibrary, unsupported, screen, stats, general
}

enum AssistantRouter {
    static func route(_ raw: String) -> AssistantIntent {
        let t = raw.lowercased().replacingOccurrences(of: "’", with: "'")
        func has(_ words: [String]) -> Bool { words.contains { t.contains($0) } }
        let toks = Set(SearchIntent.tokens(raw))
        let howTo = ["how do i", "how can i", "how to", "how does", "how do you"].contains { t.hasPrefix($0) }   // a how-to about the guide is a knowledge question, not a live guide check

        // Not for sale here: matched as whole words, so "firecracker" is not "crack".
        if has(["free iptv", "iptv subscription", "give me channels", "where can i get iptv", "where can i buy iptv", "cheap iptv", "provide channels", "m3u list for me", "give me a playlist", "free playlist"]) || toks.contains("pirate") || toks.contains("pirated") || toks.contains("cracked") { return .unsupported }
        // What is on screen right now (the live state), not a question about a screen.
        if has(["what is on my screen", "what's on my screen", "whats on my screen", "what is on screen", "what's on screen", "what am i looking at", "where am i", "what page am i", "what can you see", "what do you see", "can you see my screen", "which screen am i", "what screen am i", "which screen is this", "what screen is this"]) { return .screen }
        if !howTo, has(["guide"]) && has(["empty", "blank", "missing", "no data", "not showing", "not loading", "wrong", "hours off", "out of date", "outdated", "no programme", "no program", "epg"]) { return .diagnoseGuide }
        if !howTo, has(["epg", "xmltv"]) && has(["why", "fix", "problem", "not working", "wrong", "empty", "blank", "missing", "hours", "out of date", "outdated", "no data"]) { return .diagnoseGuide }
        if has(["how do i add", "how to add", "set up a", "setup a", "connect my"]) && has(["m3u", "xtream", "jellyfin", "plex", "emby", "playlist", "source", "iptv"]) { return .addSource }
        if toks.contains("add") && has(["m3u", "xtream", "jellyfin", "plex", "emby", "playlist", "source", "stalker", "hdhomerun", "local file", "tuner"]) { return .addSource }
        // A question about the app itself ("how do I", "why", "error", "failed", "not working" about a feature, Hinglish and Telugu cues) goes to Setu's knowledge before any playback, media-search or tool intent.
        if isAppHelp(raw) { return .explainSettings }
        if has(["how much did i watch", "how much have i watched", "how long did i watch", "how many hours", "watch time", "viewing time", "my viewing", "my watching", "my stats", "watch statistics", "what did i watch the most", "most watched", "top channel", "favourite channel", "favorite channel"]) { return .stats }
        if has(["which engine", "what engine", "avplayer or mpv", "mpv or avplayer", "best engine", "recommend engine", "switch engine", "player engine should"]) { return .engineAdvice }
        if has(["buffer", "stutter", "freez", "lagging", "keeps stopping", "not playing", "won't play", "wont play", "doesn't play", "doesnt play", "can't play", "cant play", "black screen", "no picture", "no video", "no sound", "error", "failed", "not working", "why is this channel", "why is this stream", "playback problem", "diagnose"]) && !has(["settings for", "turn on", "turn off"]) { return .diagnosePlayback }
        if has(["source", "playlist", "provider", "server"]) && has(["working", "reachable", "down", "health", "check", "test", "connect", "loading", "refresh", "failing", "slow", "status"]) && !has(["how do i add", "how to add"]) { return .sourceHealth }
        if has(["privacy", "private", "where is my data", "stored", "local storage", "do you collect", "tracking", "send my", "who can see", "uploaded", "keychain", "password safe"]) { return .privacy }
        if SearchCommands.parse(raw).contains(where: { if case .go = $0.kind { return false } else { return true } }) { return .playbackControl }
        if has(["setting", "option", "what does", "where is", "where do i", "how do i turn", "how to turn", "turn on", "turn off", "enable", "disable", "subtitle", "audio language", "theme", "buffering mode", "deinterlac", "hardware decoding"]) { return .explainSettings }
        return .general
    }


    /// Words that mean the question is about what is playing or loading right now, so the live tools (player numbers, guide check, playlist probe) answer it.
    private static let livePhrases = ["this channel", "this stream", "this video", "this show", "this movie", "this episode", "this film", "right now", "currently playing", "now playing", "is playing", "just now", "this playlist", "this source", "this server"]
    /// Frames that make a question about the app on their own, because a person using Setu who says "how do I" means the app.
    private static let helpFrames = ["how do i", "how can i", "how to", "how does", "how do you", "how would i", "how should i", "why is my", "why does my", "why is the", "why does the", "why are my", "why do my", "why cant", "why wont", "why isnt", "why doesnt", "why dont", "why do i", "why did", "why is", "why are", "why does", "why do", "why", "which setting"]
    /// Frames that count only when the question names something in the app ("where is my backup"), so "where is Inception" stays a media question.
    private static let softFrames = ["where is", "where are", "where do i", "where can i", "where to", "what is", "what are", "what does", "what do", "whats", "can i", "can you", "is there", "is it possible", "does it", "do you", "will it", "which screen"]
    /// Features whose failure is an app question, not a playback problem: the words "error", "failed" and "not working" next to one of these are answered from what the app knows.
    private static let featureNouns: Set<String> = ["backup", "icloud", "sync", "lock", "touch", "id", "download", "downloads", "recording", "recordings", "reminder", "reminders", "notification", "notifications", "login", "401", "403", "429", "profile", "profiles", "pin", "parental", "lyrics", "queue", "scrobble", "scrobbling", "lastfm", "equalizer", "crossfade", "theme", "language", "shortcut", "shortcuts", "settings", "setting", "account", "password", "restore", "import", "export", "cache", "storage", "update", "trakt", "debrid", "tmdb", "artwork", "keyboard", "siri", "widget", "airplay", "chromecast", "cast", "proxy", "vpn", "dns", "subtitle", "subtitles", "collection", "collections", "favourites", "favorites", "watchlist", "playlist", "devices", "listen", "together", "pairing", "sidebar", "menu"]
    private static let hinglishHelp: Set<String> = ["kaise", "kese", "kaisay", "kaisey", "kahan", "kahaan", "kidhar", "ekkada", "ela", "enduku", "endhuku", "kyun", "kyu", "kyon", "cheyali", "cheyyali", "batao", "bataiye", "dikhao", "dikhaiye"]
    private static let hinglishFail: [String] = ["nahi aa", "nahi chal", "nahi ho", "nahin aa", "nahin chal", "nahi dikh", "nahi mil", "ledu", "raha nahi", "rahi nahi", "kaam nahi"]

    /// True when the words are a question or complaint about the app (what a setting is, where something lives, how to fix a feature), so no playback, media-search or live-tool intent may take it.
    /// A question about what is playing right now ("why is this channel buffering") stays with the live tools.
    static func isAppHelp(_ raw: String) -> Bool {
        let words = SearchIntent.tokens(raw)
        guard !words.isEmpty else { return false }
        let padded = " " + words.joined(separator: " ") + " "
        // "favourite kaise add kare" asks how to do it; it is not the command "add favourite". A how-word (English, Hinglish or Telugu in Latin letters) makes it a question.
        let asksHow = words.contains(where: { ["how", "kaise", "kese", "kaisay", "kaisey", "ela"].contains($0) })
        if !asksHow, SearchCommands.parse(raw).contains(where: { if case .go = $0.kind { return false } else { return true } }) { return false }
        if livePhrases.contains(where: { padded.contains(" \($0) ") }) { return false }
        // "is my playlist working?" is a live check of a source, answered by the playlist probe; "how do I check my playlist" is a how-to.
        if !padded.hasPrefix(" how "), words.contains(where: { ["source", "playlist", "provider", "server"].contains($0) }), words.contains(where: { ["working", "reachable", "down", "health", "status", "check", "test", "failing"].contains($0) }) { return false }
        if SearchIntent.classify(raw) == .ask { return true }
        if helpFrames.contains(where: { padded.hasPrefix(" \($0) ") }) { return true }
        let about = SearchIntent.mentionsApp(words, padded)
        if about, softFrames.contains(where: { padded.hasPrefix(" \($0) ") }) { return true }
        let complaint = SearchIntent.complaints.contains { padded.contains(" \($0) ") } || words.contains("error") || words.contains("failed") || words.contains("fails")
        if complaint, words.contains(where: { featureNouns.contains($0) }) { return true }
        if words.contains(where: { hinglishHelp.contains($0) }) { return true }
        if hinglishFail.contains(where: { padded.contains(" \($0) ") }), about || words.contains(where: { ["sound", "audio", "subtitle", "subtitles", "lyrics", "awaaz", "song", "video"].contains($0) }) { return true }
        return false
    }

    /// The source type named in a question, for setup help.
    static func sourceKind(in raw: String) -> String? {
        let t = raw.lowercased()
        for (k, name) in [("xtream", "Xtream"), ("jellyfin", "Jellyfin"), ("emby", "Emby"), ("plex", "Plex"), ("stalker", "Stalker"), ("mag", "Stalker"), ("hdhomerun", "HDHomeRun"), ("tuner", "HDHomeRun"), ("m3u file", "M3U file"), ("local file", "M3U file"), ("m3u", "M3U link")] where t.contains(k) { return name }
        return nil
    }
}

/// Lets any screen open the assistant with a question ("Diagnose this", from the player's error card, or from Settings).
@MainActor @Observable final class AssistantLauncher {
    static let shared = AssistantLauncher()
    private(set) var request: String?
    private(set) var opens = 0
    func ask(_ question: String?) { request = question; opens += 1 }
    func take() -> String? { defer { request = nil }; return request }

    /// Settings is its own window on the Mac: bring the main window to the front so the assistant can be seen.
    static func bringMainWindowForward() {
        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain && $0.isVisible && !$0.title.lowercased().contains("settings") }?.makeKeyAndOrderFront(nil)
        #endif
    }
}
