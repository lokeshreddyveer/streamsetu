import Foundation

/// Settings and screens of the guide hub (Settings > Guide): several guide sources, matching channels to a guide, guide health, and the optional public channel database.
/// Declared ahead of the screens so the assistant never describes a control that does not exist yet: every entry is unreviewed and stays out of the live reach until the page ships.
enum AtlasGuide {
    /// Checked against Settings > Library > Guide sources (GuideSourcesGroup). The rest have no control in the app yet and stay unreviewed.
    private static let checked: Set<String> = ["screen.settings.guide", "setting.guide.sources", "setting.guide.addXMLTV", "setting.guide.publicDatabase", "setting.guide.enrichLogos", "setting.guide.freshness", "setting.guide.timeZoneMode", "control.guide.diagnostics", "screen.ios.settings.guide"]

    /// The guide settings and the Refresh button are on iPhone and iPad too (GuideSourcesSection), so settings and controls are for every platform.
    private static func e(_ kind: AtlasKind, _ id: String, _ title: String, _ summary: String, _ path: [String], aliases: [String] = [], detail: String? = nil, related: [String] = [], safety: AtlasSafety = .read) -> AtlasEntry {
        .make(id, kind, title, summary, path: path, reach: AtlasReach.none, aliases: aliases, detail: detail, platforms: id.hasPrefix("screen.ios") ? [.iPhone, .iPad] : (kind == .setting || kind == .control ? .all : .mac), related: related, safety: safety, reviewed: checked.contains(id))
    }

    /// Help articles whose imported text (AppGuide) no longer matched the app. Same id, so they replace the imported ones.
    private static func article(_ slug: String, _ title: String, _ keys: [String], _ summary: String, _ detail: String?, related: [String] = []) -> AtlasEntry {
        .make("guide." + slug, .recipe, title, summary, path: ["Help", title], reach: AtlasReach.none, aliases: keys, detail: detail, platforms: .all, related: related, safety: .read, reviewed: true)
    }

    static let articles: [AtlasEntry] = [
        article("addingAPlaylistOrSource", "Adding a playlist or source", ["add", "playlist", "source", "setup", "connect", "type"],
                "Choose File, then Add Playlist… (Command N), or press Add playlist in the playlist menu at the bottom of the sidebar.",
                "Paste a playlist link, server address or stream into the box at the top, or choose how you connect from the tiles, fill in the fields and press Connect. Settings, Library, Manage, Playlists… lists the sources you have. StreamSetu provides no channels or subscriptions: you add sources you are entitled to use, and everything stays on this device."),
        article("addingXtream", "Adding Xtream", ["xtream", "xtream codes", "username", "server"],
                "Adding Xtream: choose the Xtream Codes tile, then fill in Server (like http://host:port), Username and Password, as your provider gave them.",
                "The name is optional. Press Connect; the channels, movies and series load and the guide address is picked up automatically."),
        article("addingAnM3uLink", "Adding an M3U link", ["m3u", "link", "url", "json"],
                "Adding an M3U link: choose the Playlist link tile and paste the Playlist address (https://example.com/playlist.m3u).",
                "For a file on this device choose the Playlist file tile and press Choose File…, then Connect. A guide (XMLTV) address can be added to the playlist afterwards, with Edit in Playlists."),
        article("addingJellyfinOrEmby", "Adding Jellyfin or Emby", ["jellyfin", "emby", "media server"],
                "Adding Jellyfin or Emby: choose the Media server tile, pick Jellyfin or Emby, then fill in the Server address, your Username and Password for that server.",
                "Press Connect. Your library of movies and series appears under Movies and Series."),
        article("addingPlex", "Adding Plex", ["plex", "token"],
                "Adding Plex: choose the Media server tile, pick Plex, then enter the Server address (like http://host:32400) and your Access token (the X-Plex-Token).",
                "Press Connect. The token is kept with your other logins, encrypted on this device."),
        article("traktDebridAndAi", "Trakt, Debrid and AI", ["trakt", "debrid", "real-debrid", "alldebrid", "premiumize", "ai", "gemini", "openai", "claude", "ollama", "api key", "key", "scrobble"],
                "In Settings, Library, the Trakt, Debrid and AI assistant groups connect your own accounts and keys.",
                "Trakt marks things watched and can import your watchlist into Watch Later (your own Trakt app keys); Debrid services resolve hoster links; the AI assistant uses your own key from Apple Intelligence (on device), Gemini, OpenRouter, Claude, OpenAI, Groq, NVIDIA, Ollama Cloud or your own Ollama. Free tiers exist for several; limits and prices are shown next to each. On iPhone and iPad it is under More, Trakt, Debrid and AI."),
        article("privacyAndSafety", "Privacy and safety", ["privacy", "private", "secure", "lock", "pin", "kids", "parental", "profile"],
                "Playlist logins and API keys live in the Keychain.",
                "The app can be locked with Touch ID or the Mac password. Folders can be locked behind a PIN and a kids profile hides them. An AI you connect is sent the words you type, and, if you allow it with the eye button, the screen name, what is playing and library counts. To pick the best match it can also be sent the titles and short plots of a few matches. It never gets logins, playlist addresses or watch history."),
        article("keyboard", "Keyboard", ["keyboard", "shortcut", "key", "hotkey"],
                "⌘K focuses search; Esc clears it; ↑↓ choose a result and Return opens it.",
                "Return plays a selected channel. ⌘/ opens the full list of shortcuts (Help, Keyboard Shortcuts)."),
    ]

    static let all: [AtlasEntry] = articles + [
        e(.screen, "screen.settings.guide", "Guide settings", "Lists the guides your channels use, shows whether each one is fresh, and lets you add a guide address or switch on the public channel database.",
          ["Settings", "Library", "Guide sources"], aliases: ["guide sources", "epg settings", "add a guide", "xmltv", "guide health", "why is my guide empty"], related: ["diag.guide", "setting.guide.sources"]),
        e(.screen, "screen.ios.settings.guide", "Guide settings", "On iPhone and iPad the guide sources are in Settings, Subscriptions and Alerts, under Guide sources: how fresh each guide is, a guide address to Test and Add, Refresh all guides, and the switch that fills missing logos, genres and countries. A playlist's own guide address, guide file and time shift are on that playlist's page, and how often the guide refreshes is in Library and Guide.",
          ["Settings", "Subscriptions and Alerts", "Guide sources"], aliases: ["guide sources", "epg settings", "add a guide", "xmltv"], related: ["screen.settings.guide", "screen.ios.settings.alerts"]),
        e(.setting, "setting.guide.sources", "Guide sources", "The guides the app reads: each playlist's own guide, and any guide address you add. Each can be switched off.",
          ["Settings", "Library", "Guide sources"], aliases: ["epg sources", "several guides", "guide priority"], related: ["setting.guide.addXMLTV"], safety: .change),
        e(.setting, "setting.guide.addXMLTV", "Add a guide address", "Adds an XMLTV address you supply, tests it, and uses it for channels the playlist's own guide does not cover.",
          ["Settings", "Library", "Guide sources", "Add"], aliases: ["add xmltv url", "extra epg", "second guide", "add epg"], related: ["setting.guide.sources"], safety: .change),
        e(.setting, "setting.guide.publicDatabase", "Public channel database", "Downloads a public list of channels once a day to fill missing logos, countries and categories. Nothing from your library is sent.",
          ["Settings", "Library", "Guide sources", "Fill missing logos, genres and countries"], aliases: ["iptv-org", "fill missing logos", "channel logos", "channel database"], related: ["setting.guide.enrichLogos"], safety: .change),
        e(.setting, "setting.guide.enrichLogos", "Fill missing logos", "The same switch as the public channel database: it fills logos, genres and countries that a channel is missing. Locked, hidden and adult channels are never touched.",
          ["Settings", "Library", "Guide sources", "Fill missing logos, genres and countries"], aliases: ["logos missing", "channel icons"], related: ["setting.guide.publicDatabase"], safety: .change),
        e(.setting, "setting.guide.freshness", "Guide warnings", "Each guide in the list shows a check mark when it is fresh and a warning when it is out of date or about to run out.", ["Settings", "Library", "Guide sources"],
          aliases: ["guide out of date", "guide ends soon", "stale guide"], related: ["diag.guide"]),
        e(.setting, "setting.guide.timeZoneMode", "Guide time zone", "StreamSetu works out the time zone of each guide by itself and has no switch for it. When programme times are hours off, use the guide time shift on that playlist's page instead.",
          ["Settings", "Library", "Playlists"], aliases: ["guide hours off", "guide times wrong", "guide time shift"], related: ["setting.guideShift", "recipe.shiftGuideTimes"]),
        e(.setting, "setting.guide.enrichmentEnabled", "Use the public channel database", "Switches the daily download of the public channel list on or off. Switching it off removes what it filled in.",
          ["Settings", "Guide", "Public channel database"], aliases: ["turn off logo fill", "stop downloading channel list"], related: ["setting.guide.publicDatabase"], safety: .change),
        e(.setting, "setting.guide.reminderLeadMinutes", "Remind me before", "How many minutes before a programme starts its reminder appears: 1, 5, 10 or 15.",
          ["Settings", "Guide", "Reminders"], aliases: ["reminder lead time", "notify earlier"], related: ["setting.remindersEnabled"], safety: .change),
        e(.setting, "setting.storage.guideBannerDismissed", "Guide warning dismissed (guide.banner.dismissed)", "Remembers that you hid a guide warning, so it stays hidden for a day.",
          ["Settings", "Guide", "Warnings"], aliases: ["hide guide warning"], related: ["setting.guide.freshness"]),
        e(.control, "control.guide.diagnostics", "Refresh all guides", "Downloads every guide again now. Each guide row above it shows when it was last read, how fresh it is and any problem found, so this is also the way to check a guide after fixing its address.",
          ["Settings", "Library", "Guide sources", "Refresh all guides"], aliases: ["why guide empty", "refresh guides", "reload epg", "guide report"], related: ["diag.guide"]),
    ]
}
