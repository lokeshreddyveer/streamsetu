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

        if has(["what is on my screen", "what's on my screen", "whats on my screen", "what is on screen", "what's on screen", "what am i looking at", "which screen", "what screen", "where am i", "what page am i", "what can you see", "what do you see", "can you see my screen"]) { return .screen }
        if has(["how much did i watch", "how much have i watched", "how long did i watch", "how many hours", "watch time", "viewing time", "my viewing", "my watching", "my stats", "watch statistics", "what did i watch the most", "most watched", "top channel", "favourite channel", "favorite channel"]) { return .stats }
        if has(["free iptv", "iptv subscription", "give me channels", "where can i get iptv", "where can i buy iptv", "cheap iptv", "provide channels", "m3u list for me", "give me a playlist", "pirate", "crack", "free playlist"]) { return .unsupported }
        if has(["guide"]) && has(["empty", "blank", "missing", "no data", "not showing", "not loading", "wrong", "hours off", "out of date", "outdated", "no programme", "no program", "epg"]) { return .diagnoseGuide }
        if has(["epg", "xmltv"]) && has(["why", "fix", "problem", "not working", "wrong", "empty", "blank", "missing", "hours", "out of date", "outdated", "no data"]) { return .diagnoseGuide }
        if has(["which engine", "what engine", "avplayer or mpv", "mpv or avplayer", "best engine", "recommend engine", "switch engine", "player engine should"]) { return .engineAdvice }
        if has(["buffer", "stutter", "freez", "lagging", "keeps stopping", "not playing", "won't play", "wont play", "doesn't play", "doesnt play", "can't play", "cant play", "black screen", "no picture", "no video", "no sound", "error", "failed", "not working", "why is this channel", "why is this stream", "playback problem", "diagnose"]) && !has(["settings for", "turn on", "turn off"]) { return .diagnosePlayback }
        if has(["source", "playlist", "provider", "server"]) && has(["working", "reachable", "down", "health", "check", "test", "connect", "loading", "refresh", "failing", "slow", "status"]) && !has(["how do i add", "how to add"]) { return .sourceHealth }
        if has(["add"]) && has(["m3u", "xtream", "jellyfin", "plex", "emby", "playlist", "source", "stalker", "hdhomerun", "local file", "tuner"]) { return .addSource }
        if has(["how do i add", "how to add", "set up a", "setup a", "connect my"]) && has(["m3u", "xtream", "jellyfin", "plex", "emby", "playlist", "source", "iptv"]) { return .addSource }
        if has(["privacy", "private", "where is my data", "stored", "local storage", "do you collect", "tracking", "send my", "who can see", "uploaded", "keychain", "password safe"]) { return .privacy }
        if SearchCommands.parse(raw).contains(where: { if case .go = $0.kind { return false } else { return true } }) { return .playbackControl }
        if has(["setting", "option", "what does", "where is", "where do i", "how do i turn", "how to turn", "turn on", "turn off", "enable", "disable", "subtitle", "audio language", "theme", "buffering mode", "deinterlac", "hardware decoding"]) { return .explainSettings }
        return .general
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
