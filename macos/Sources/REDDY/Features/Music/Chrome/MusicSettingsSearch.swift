import Foundation

/// The tabs of the Music settings, in the order of the rail.
enum MusicSettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general, playback, lyrics, plugins, data, devices, privacy
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"; case .playback: "Playback"; case .lyrics: "Lyrics"; case .plugins: "Sources & Plugins"
        case .data: "Library & Storage"; case .devices: "Devices & Rooms"; case .privacy: "Privacy & About"
        }
    }
    /// One line under the pane's title: what lives here.
    var blurb: String {
        switch self {
        case .general: "How Music looks, and the choices that make it easier to use."
        case .playback: "Sound, queue, crossfade, equalizer, output and what the player shows."
        case .lyrics: "Where lyrics come from and how they are shown."
        case .plugins: "Where music comes from: sources, plugins, accounts and scrobbling."
        case .data: "Local folders, the audio cache, tools and backups."
        case .devices: "Control Music from another device, or listen together."
        case .privacy: "What Music learns, what it keeps, and how to clear it."
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"; case .playback: "play.circle"; case .lyrics: "quote.bubble"; case .plugins: "puzzlepiece.extension"
        case .data: "internaldrive"; case .devices: "airplayaudio"; case .privacy: "hand.raised"
        }
    }
}

/// A request to open Settings on a tab, optionally scrolled to one block.
struct MusicSettingsRoute: Equatable, Sendable {
    var tab: MusicSettingsTab = .general
    var anchor: String?
}

/// One searchable thing in the settings: a block (a card with its rows) and the words that should find it.
struct MusicSettingsEntry: Identifiable, Equatable, Sendable {
    var id: String
    var tab: MusicSettingsTab
    var title: String
    var detail: String = ""
    var section: String = ""
    var keywords: [String] = []
    /// The block that holds the row, scrolled to and flashed.
    var anchor: String
}

enum MusicSettingsSearch {
    struct Group: Equatable, Sendable { var tab: MusicSettingsTab; var entries: [MusicSettingsEntry] }

    static func terms(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// 0 equals the title, 1 starts with it, 2 contains it, 3 matches the description, section or keywords only. Nil when a term is missing everywhere.
    static func rank(_ e: MusicSettingsEntry, terms: [String]) -> Int? {
        guard !terms.isEmpty else { return nil }
        let title = e.title.lowercased()
        let hay = ([e.title, e.detail, e.section] + e.keywords).joined(separator: " ").lowercased()
        guard terms.allSatisfy({ hay.contains($0) }) else { return nil }
        let q = terms.joined(separator: " ")
        if title == q { return 0 }
        if title.hasPrefix(q) { return 1 }
        if terms.allSatisfy({ title.contains($0) }) { return 2 }
        return 3
    }

    /// Results grouped by tab; groups ordered by their best hit, entries inside a group by rank (then by their order in the index).
    static func search(_ query: String, in entries: [MusicSettingsEntry]) -> [Group] {
        let t = terms(query)
        let ranked = entries.enumerated().compactMap { i, e in rank(e, terms: t).map { (i, e, $0) } }
        var byTab: [MusicSettingsTab: [(Int, MusicSettingsEntry, Int)]] = [:]
        for r in ranked { byTab[r.1.tab, default: []].append(r) }
        let groups = byTab.map { tab, rows -> (MusicSettingsTab, Int, [MusicSettingsEntry]) in
            let sorted = rows.sorted { $0.2 != $1.2 ? $0.2 < $1.2 : $0.0 < $1.0 }
            return (tab, sorted.first?.2 ?? 3, sorted.map(\.1))
        }
        return groups.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : (MusicSettingsTab.allCases.firstIndex(of: $0.0) ?? 0) < (MusicSettingsTab.allCases.firstIndex(of: $1.0) ?? 0) }
            .map { Group(tab: $0.0, entries: $0.2) }
    }

    /// The index. Every block shown in the settings has at least one entry here; a test keeps it that way.
    static let index: [MusicSettingsEntry] = {
        func e(_ anchor: String, _ tab: MusicSettingsTab, _ title: String, _ detail: String = "", _ section: String = "", _ keywords: [String] = []) -> MusicSettingsEntry {
            MusicSettingsEntry(id: anchor + "." + title, tab: tab, title: title, detail: detail, section: section, keywords: keywords, anchor: anchor)
        }
        var out: [MusicSettingsEntry] = MusicSettingsTab.allCases.map {
            MusicSettingsEntry(id: "tab." + $0.rawValue, tab: $0, title: $0.title, detail: "", section: "", keywords: [], anchor: "tab." + $0.rawValue)
        }
        out += [
            e("general.appearance", .general, "Adapt colours to artwork", "Take colours from the song that is playing.", "Appearance", ["theme", "adaptive", "accent", "ambient", "cover"]),
            e("general.appearance", .general, "Palette", "Material You palette from the cover, a colour or the system.", "Appearance", ["colour", "color", "seed", "material"]),
            e("general.appearance", .general, "Light around music videos", "Soft light taken from the video.", "Appearance", ["ambient", "glow", "video"]),
            e("general.appearance", .general, "Text size", "Make text in Music larger or smaller.", "Appearance", ["font", "bigger", "accessibility", "zoom", "dynamic type"]),
            e("general.appearance", .general, "Reduce motion", "Follows System Settings, Accessibility, Display.", "Appearance", ["animation", "accessibility", "motion"]),
            e("devices.rooms", .devices, "Devices", "Control Music from a phone or another computer.", "Devices and rooms", ["remote", "pair", "airplay", "cast", "allow other devices", "pairing code"]),
            e("devices.rooms", .devices, "Listen together", "Share a queue with friends in a room.", "Devices and rooms", ["room", "party", "sync"]),
            e("general.accessibility", .general, "Accessibility", "Simplified player, large controls, sound and trackpad feedback, stronger text over pictures, no visualizers, a volume limit.", "Accessibility", ["simplified player", "large controls", "haptic", "voiceover", "contrast", "volume limit", "loudest allowed", "visualizer", "switch control"]),
            e("playback.quality", .playback, "Audio quality", "Low saves data; lossless is used when a source has it.", "Audio", ["bitrate", "data saver", "lossless"]),
            e("playback.quality", .playback, "Skip non-music parts", "Skip intros, sponsor reads and silence in YouTube tracks.", "Audio", ["sponsorblock", "segments"]),
            e("playback.quality", .playback, "Write song details into downloads", "Save title, artist, album and cover inside each file.", "Audio", ["tags", "metadata", "id3"]),
            e("playback.quality", .playback, "Never Play List", "Songs and artists you blocked.", "Audio", ["block", "blacklist", "hide artist"]),
            e("playback.player", .playback, "Global hotkeys", "Keys that work when the app is in the background.", "Hotkeys", ["keyboard", "media keys", "shortcut"]),
            e("playback.player", .playback, "Normalise volume", "Even out loudness between songs.", "Player", ["loudness", "replaygain", "volume"]),
            e("playback.player", .playback, "Crossfade", "Blend the end of a song into the next.", "Player", ["gapless", "fade", "transition"]),
            e("playback.player", .playback, "Autoplay", "Keep similar music coming when the queue runs low.", "Queue", ["endless", "radio", "similar"]),
            e("playback.player", .playback, "Skip back and forward", "How many seconds the skip buttons jump.", "Player", ["seconds", "jump", "rewind"]),
            e("playback.player", .playback, "Remember my place", "Long songs and podcasts resume where you stopped.", "Player", ["resume", "bookmark", "position"]),
            e("playback.player", .playback, "Pause when headphones disconnect", "Stop playing when the output is removed.", "Player", ["unplug", "bluetooth", "output removed"]),
            e("playback.player", .playback, "Start playing when the app opens", "Pick up where the last session ended.", "Player", ["launch", "startup", "resume"]),
            e("playback.player", .playback, "Queue behaviour", "Move instead of duplicating, keep shuffle on, shuffle the whole queue, shuffle style.", "Queue", ["duplicate", "sticky shuffle", "shuffle"]),
            e("playback.player", .playback, "Notifications and window title", "Notify when the song changes; show the song in the window title.", "Windows", ["notify", "title"]),
            e("playback.player", .playback, "Menu bar item", "The playing song and controls in the menu bar.", "Windows", ["notification", "window title"]),
            e("playback.player", .playback, "Theatre mode", "Lyrics, queue and a clock in the large view.", "Theatre", ["clock", "full screen"]),
            e("playback.display", .playback, "Wavy seek bar", "Draw the seek bar as a moving wave.", "Player look", ["progress", "scrubber", "slider"]),
            e("playback.display", .playback, "Show music videos", "Show the video in the full-window player.", "Player look", ["video", "clip", "picture"]),
            e("playback.karaoke", .playback, "Karaoke", "Remove the vocals on this Mac. Needs a model you download.", "Karaoke", ["vocals", "instrumental", "sing along", "model", "stems"]),
            e("playback.automix", .playback, "Automix", "Blend songs on the beat. Off by default.", "Automix", ["beat", "dj", "transition", "mix", "bpm", "tempo match", "analysis"]),
            e("playback.automix", .playback, "Automix style and strength", "Fade only, smooth or club, and how long it runs.", "Automix", ["overlap", "bass swap", "stretch"]),
            e("playback.automix", .playback, "Clear analysis cache", "Forget the beats and keys Automix learned.", "Automix", ["cache", "delete"]),
            e("playback.automix", .playback, "Equalizer", "Seven bands, bass and treble, sixteen presets.", "Equalizer", ["eq", "bass", "treble", "tone", "preset", "sound"]),
            e("playback.automix", .playback, "Stereo widening", "Make stereo music feel wider.", "Equalizer", ["spatial", "surround", "width"]),
            e("playback.output", .playback, "Output device", "Choose where Music plays on this Mac.", "Output device", ["speaker", "headphones", "dac", "audio device", "airplay", "bluetooth", "route"]),
            e("playback.motion", .playback, "Animated album art", "Looping artwork clips and a slow drift on covers.", "Animated artwork", ["motion", "cover", "apple music", "clips", "cellular", "drift"]),
            e("playback.catalog", .playback, "Catalogue information", "Use catalogue sources behind the scenes to improve matches.", "Catalogue", ["matching", "covers", "jiosaavn", "spotify", "apple", "charts", "remembered matches"]),
            e("lyrics.options", .lyrics, "Lyrics sources", "Looked up in this order; each says what it is sent.", "Sources", ["order", "priority", "providers", "unofficial", "paxsenix", "privacy"]),
            e("lyrics.options", .lyrics, "PaxSenix key", "Optional key, kept in the Keychain.", "Sources", ["api key", "keychain"]),
            e("lyrics.options", .lyrics, "Lyrics timing", "Shift every song's lyrics earlier or later.", "Display", ["offset", "delay", "sync"]),
                        e("lyrics.options", .lyrics, "Prefer word-by-word lyrics", "Wait for a source with word timing.", "Display", ["karaoke", "word by word"]),
            e("lyrics.options", .lyrics, "Soft blur and glow on lyrics", "Blur the lines that are not current.", "Display", ["blur", "glow", "focus"]),
            e("lyrics.options", .lyrics, "Translate lyrics into", "Show a translation under each line.", "Display", ["translation", "romanisation", "language", "blur", "glow"]),
            e("plugins.roles", .plugins, "Metadata source", "The source that answers search and browse.", "Roles", ["main source", "search", "browse", "role"]),
            e("plugins.roles", .plugins, "Audio source order", "The player tries these from the top until one has the song.", "Roles", ["priority", "providers", "fallback", "first wins"]),
            e("plugins.roles", .plugins, "Lyrics role", "Where lyrics come from, in order.", "Roles", ["order", "lyrics sources"]),
            e("plugins.roles", .plugins, "Scrobbling role", "The services plays are sent to.", "Roles", ["last.fm", "listenbrainz", "services"]),
            e("plugins.installed", .plugins, "Installed sources", "Built-in sources and plugins, each with its own switch.", "Installed", ["spotify", "youtube", "audius", "jiosaavn", "itunes", "sign in", "token", "client id", "built-in", "on by default", "contacted"]),
            e("plugins.installed", .plugins, "Add plugin", "Install a plugin from a file, a folder or an https address.", "Installed", ["install", "script", "extension", "sbplugin", "permissions", "remove", "update", "logs"]),
            e("plugins.installed", .plugins, "How plugins work", "What a plugin can do and how it is sandboxed.", "Installed", ["sandbox", "permissions", "javascript"]),
            e("plugins.installed", .plugins, "Run source setup again", "Open the first-run choice of sources again.", "Installed", ["consent", "first run", "onboarding"]),
            e("plugins.addons", .plugins, "Added sources", "Addons are web servers you add yourself.", "Addons", ["addon", "server", "url", "token", "stremio", "quality swap"]),
            e("plugins.ownserver", .plugins, "Your own server", "Your own Piped or Invidious server.", "Own server", ["piped", "invidious", "self hosted", "instance", "address"]),
            e("plugins.subsonic", .plugins, "Your music server", "Your own Subsonic or Navidrome server.", "Music server", ["subsonic", "navidrome", "airsonic", "self hosted", "nas", "library"]),
            e("plugins.metadata", .plugins, "Metadata sources", "Open sources for credits, cast and links, each with its own switch.", "Metadata", ["musicbrainz", "wikidata", "wikipedia", "imdb", "tmdb", "listenbrainz", "discogs", "omdb", "last.fm", "credits", "cast", "privacy", "what is sent", "film", "lyricist", "composer"]),
            e("data.local", .data, "Local music folders", "Folders of music files on this Mac.", "Local files", ["files", "mp3", "flac", "watch folders", "rescan", "acoustid", "sonic", "audio tools", "library health", "listening mode", "automation", "repeated songs", "missing files"]),
            e("plugins.updates", .plugins, "Plugin updates", "Check for newer versions of your plugins, and decide each one.", "Updates", ["update", "weekly", "version"]),
            e("plugins.accounts", .plugins, "YouTube Music account", "Sign in, switch channel, choose where new things go.", "Accounts", ["google", "channel", "login"]),
            e("plugins.scrobbling", .plugins, "Scrobble plays", "Send plays to Last.fm or ListenBrainz.", "Scrobbling", ["last.fm", "lastfm", "listenbrainz", "history"]),
            e("data.cache", .data, "Artwork cache", "Covers kept on this device.", "Storage", ["pictures", "images", "clear"]),
            e("data.cache", .data, "Audio cache", "Keep played songs for instant and offline play.", "Storage", ["disk", "clear cache", "offline", "size limit"]),
            e("data.backup", .data, "Export library", "Save likes, playlists and history as a file.", "Backup", ["backup", "import", "restore", "json"]),
            e("privacy.taste", .privacy, "Private listening", "Stop counting, scrobbling and recommending from what you play, until the app restarts.", "Listening and recommendations", ["incognito", "history", "pause history"]),
            e("privacy.data", .privacy, "Hidden Recommendations", "Songs and artists hidden from Home, Radio and autoplay.", "Your data", ["hide", "not interested"]),
            e("privacy.taste", .privacy, "Reset recommendations", "Start Home, Radio and autoplay fresh. Nothing you saved is deleted.", "Listening and recommendations", ["clear", "forget", "taste", "learned"]),
            e("privacy.taste", .privacy, "Languages, genres and artists you like", "Lean recommendations toward them.", "Listening and recommendations", ["preferences", "favourite", "language"]),
            e("privacy.data", .privacy, "Delete all music data", "Remove likes, playlists, history, downloads and caches.", "Your data", ["wipe", "erase", "reset", "clear history", "telemetry", "tracking", "network", "contacted", "what is sent", "analytics"]),
            e("privacy.changes", .privacy, "Recent source changes", "When a source was switched on or off, and why.", "Your data", ["log", "history", "enabled"]),
            e("privacy.problems", .privacy, "Playback problems", "Why a song did not start.", "Your data", ["error", "log", "failed", "diagnose"]),
            e("privacy.about", .privacy, "Version", "The version of StreamSetu Music.", "About", ["build", "release"])
        ]
        return out
    }()

    /// Every block id the settings screen renders. Each must be reachable from the index.
    static let blockAnchors: [String] = [
        "general.appearance", "general.accessibility",
        "playback.quality", "playback.player", "playback.display", "playback.karaoke", "playback.automix", "playback.output", "playback.motion", "playback.catalog",
        "lyrics.options",
        "plugins.roles", "plugins.installed", "plugins.addons", "plugins.ownserver", "plugins.subsonic", "plugins.metadata", "plugins.updates", "plugins.accounts", "plugins.scrobbling",
        "data.cache", "data.local", "data.backup",
        "devices.rooms",
        "privacy.taste", "privacy.data", "privacy.changes", "privacy.problems", "privacy.about"
    ]
}
