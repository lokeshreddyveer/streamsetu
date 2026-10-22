import Foundation

/// Everything the assistant knows about the app's own options: each setting with what it does, its choices, its current value and where it lives. The assistant reads this through a lookup,
/// so it can answer "what does Deinterlacing do?" or "where do I turn off subtitles?" from facts, not from memory. It can change only the entries marked changeable; the rest it explains and
/// points to, because they concern security, accounts, networks or other people's data.
@MainActor struct AppSettingEntry {
    enum Kind { case toggle, choice, number }
    let id: String
    let title: String
    let detail: String
    /// Where it is in the app, e.g. "Settings → Playback → Subtitles".
    let path: String
    let kind: Kind
    let options: [String]
    let read: ((AppSettings) -> String)?
    let write: ((AppSettings, String) -> Bool)?
    /// Whether a value would be accepted, decided without storing anything (so checking never touches preferences).
    let accepts: (String) -> Bool
    var changeable: Bool { write != nil }
    var words: String { (id + " " + title + " " + detail + " " + path + " " + options.joined(separator: " ")).lowercased() }

    init(id: String, title: String, detail: String, path: String, kind: Kind, options: [String], read: ((AppSettings) -> String)?, write: ((AppSettings, String) -> Bool)?, accepts: ((String) -> Bool)? = nil) {
        self.id = id; self.title = title; self.detail = detail; self.path = path; self.kind = kind; self.options = options; self.read = read; self.write = write
        self.accepts = accepts ?? { v in
            guard write != nil else { return false }
            switch kind {
            case .toggle: return ["on", "off", "true", "false", "yes", "no"].contains(v.lowercased())
            case .choice: return options.contains { $0.caseInsensitiveCompare(v) == .orderedSame }
            case .number: return Double(v.trimmingCharacters(in: CharacterSet(charactersIn: "% "))).map { $0.isFinite } ?? false
            }
        }
    }
}

@MainActor enum AppSettingsCatalog {
    // MARK: builders

    private static func toggle(_ id: String, _ title: String, _ path: String, _ detail: String, _ kp: ReferenceWritableKeyPath<AppSettings, Bool>) -> AppSettingEntry {
        AppSettingEntry(id: id, title: title, detail: detail, path: path, kind: .toggle, options: ["on", "off"], read: { $0[keyPath: kp] ? "on" : "off" }, write: { s, v in
            guard let on = ["on": true, "off": false, "true": true, "false": false, "yes": true, "no": false][v.lowercased()] else { return false }
            s[keyPath: kp] = on; return true })
    }

    private static func choice<E: CaseIterable & RawRepresentable>(_ id: String, _ title: String, _ path: String, _ detail: String, _ kp: ReferenceWritableKeyPath<AppSettings, E>,
                                                                   label: @escaping (E) -> String = { "\($0.rawValue)" }, skip: [E] = []) -> AppSettingEntry where E.RawValue == String, E: Equatable {
        let cases = E.allCases.filter { c in !skip.contains(c) }
        return AppSettingEntry(id: id, title: title, detail: detail, path: path, kind: .choice, options: cases.map(label), read: { label($0[keyPath: kp]) }, write: { s, v in
            guard let m = cases.first(where: { label($0).caseInsensitiveCompare(v) == .orderedSame || $0.rawValue.caseInsensitiveCompare(v) == .orderedSame }) else { return false }
            s[keyPath: kp] = m; return true },
            accepts: { v in cases.contains { label($0).caseInsensitiveCompare(v) == .orderedSame || $0.rawValue.caseInsensitiveCompare(v) == .orderedSame } })
    }

    private static func number(_ id: String, _ title: String, _ path: String, _ detail: String, range: ClosedRange<Double>, step: Double? = nil, unit: String = "", _ kp: ReferenceWritableKeyPath<AppSettings, Double>) -> AppSettingEntry {
        AppSettingEntry(id: id, title: title, detail: detail + " Range \(Int(range.lowerBound))–\(Int(range.upperBound))\(unit).", path: path, kind: .number, options: [], read: { "\(Int($0[keyPath: kp]))\(unit)" }, write: { s, v in
            guard let x = Double(v.trimmingCharacters(in: CharacterSet(charactersIn: "% ")).replacingOccurrences(of: unit, with: "")), x.isFinite else { return false }
            s[keyPath: kp] = AppSettings.clamp(step.map { (x / $0).rounded() * $0 } ?? x, range); return true },
            accepts: { v in Double(v.trimmingCharacters(in: CharacterSet(charactersIn: "% ")).replacingOccurrences(of: unit, with: "")).map { $0.isFinite } ?? false })
    }

    /// An explanation of something this assistant must not change.
    private static func info(_ id: String, _ title: String, _ path: String, _ detail: String) -> AppSettingEntry {
        AppSettingEntry(id: id, title: title, detail: detail, path: path, kind: .toggle, options: [], read: nil, write: nil)
    }

    private static func languageChoice(_ id: String, _ title: String, _ path: String, _ detail: String, _ kp: ReferenceWritableKeyPath<AppSettings, String>) -> AppSettingEntry {
        let names = ["": "No preference", "en": "English", "hi": "Hindi", "te": "Telugu", "ta": "Tamil", "ml": "Malayalam", "kn": "Kannada", "bn": "Bengali", "mr": "Marathi", "pa": "Punjabi", "gu": "Gujarati", "ur": "Urdu",
                     "es": "Spanish", "fr": "French", "de": "German", "it": "Italian", "pt": "Portuguese", "ru": "Russian", "ar": "Arabic", "tr": "Turkish", "ja": "Japanese", "ko": "Korean", "zh": "Chinese"]
        return AppSettingEntry(id: id, title: title, detail: detail, path: path, kind: .choice, options: names.values.sorted(), read: { names[$0[keyPath: kp]] ?? $0[keyPath: kp] }, write: { s, v in
            guard let code = names.first(where: { $0.value.caseInsensitiveCompare(v) == .orderedSame || $0.key.caseInsensitiveCompare(v) == .orderedSame })?.key else { return false }
            s[keyPath: kp] = code; return true },
            accepts: { v in names.contains { $0.value.caseInsensitiveCompare(v) == .orderedSame || $0.key.caseInsensitiveCompare(v) == .orderedSame } })
    }

    // MARK: the catalogue

    static let all: [AppSettingEntry] = [
        // General
        choice("clickBehavior", "Open channels with", "Settings → General → Browsing", "Single click plays a channel at once; double click plays it and a single click only selects. Return also plays.", \.clickBehavior, label: { $0.title }),
        toggle("collapseDuplicates", "Group quality variants", "Settings → General → Browsing", "Shows HD, FHD and 4K copies of a channel as one entry with a Streams menu.", \.collapseDuplicates),
        toggle("hideEmptyFolders", "Hide empty folders", "Settings → General → Browsing", "Folders the provider lists but that hold nothing right now are hidden. They are never deleted.", \.hideEmptyFolders),
        choice("defaultLibrarySort", "Movies and series order", "Settings → General → Browsing", "How Movies and Series are sorted when you open them.", \.defaultLibrarySort),
        choice("defaultChannelSort", "Channel order", "Settings → General → Browsing", "Provider order follows the playlist; alphabetical sorts by name.", \.defaultChannelSort),
        toggle("rememberFolders", "Remember last folder", "Settings → General → Browsing", "Returns you to the folder you were in when you come back to a tab.", \.rememberFolders),
        toggle("resumeLastChannel", "Resume the last channel", "Settings → General → At launch", "Starts the live channel that was playing when you last quit, in the bottom player. The app always opens on Home → Discover.", \.resumeLastChannel),
        toggle("remindersEnabled", "Programme reminders", "Settings → General → Notifications", "Adds a bell to upcoming programmes. Reminders are local notifications; nothing leaves the device. Needs the system's notification permission.", \.remindersEnabled),
        // Appearance
        choice("theme", "Theme", "Settings → Appearance → Theme", "Every theme is dark and restyles the whole app at once, sidebar included.", \.theme, skip: [.custom]),
        choice("accent", "Accent colour", "Settings → Appearance → Appearance", "Used for the selected tab, buttons and progress. The first swatch follows the theme.", \.accent, label: { $0.title }),
        choice("density", "Density", "Settings → Appearance → Appearance", "Card size in grids, and row height in channel lists and the sidebar.", \.density),
        choice("language", "App language", "Settings → Appearance → Appearance", "The language of the app's own wording. Titles and descriptions come from your playlists and stay as they are. Some text is still in English.", \.language, label: { $0.label }),
        toggle("reduceMotion", "Reduce animation", "Settings → Appearance → Appearance", "Turns off transitions and hover animation throughout the app.", \.reduceMotion),
        toggle("highContrast", "Increase contrast", "Settings → Appearance → Appearance", "Brighter text and stronger outlines. Also follows the system Increase Contrast setting.", \.highContrast),
        choice("sidebarLaunch", "Sidebar at launch", "Settings → Appearance → Appearance", "Whether the sidebar starts expanded, collapsed or as you left it. It can always be collapsed from its header.", \.sidebarLaunch),
        // Playback: video
        choice("hardwareDecoding", "Hardware decoding", "Settings → Playback → Video", "Automatic uses the graphics hardware where it helps. Software decoding is slower but avoids hardware quirks on some streams.", \.hardwareDecoding),
        choice("videoQuality", "Preferred quality", "Settings → Playback → Video", "Chooses between the quality variants of adaptive (HLS) streams; other streams play as provided. Data saver uses the least data.", \.videoQuality),
        toggle("liveRewind", "Pause and rewind live TV", "Settings → Playback → Live TV", "Keeps a few minutes of the channel in memory so you can pause it and wind back. Uses up to about 400 MB while a channel plays. Needs the MPV engine.", \.liveRewind),
        choice("bufferingMode", "Buffering mode", "Settings → Playback → Buffering", "Automatic suits most; Low latency favours speed on live TV; Standard is balanced; Large buffer favours stability on poor connections. A playlist can use its own mode (Playlists → its Connection section).", \.bufferingMode, label: { $0.title }),
        // Playback: audio / subtitles
        languageChoice("preferredAudioLanguage", "Preferred audio language", "Settings → Playback → Audio", "Chosen automatically when a stream offers several audio tracks. You can still switch inside the player.", \.preferredAudioLanguage),
        languageChoice("preferredSubtitleLanguage", "Preferred subtitle language", "Settings → Playback → Subtitles", "The language subtitles are looked for in, including when they are fetched online.", \.preferredSubtitleLanguage),
        toggle("subtitlesByDefault", "Show subtitles by default", "Settings → Playback → Subtitles", "Turns subtitles on when a track in your language exists.", \.subtitlesByDefault),
        toggle("autoSubtitles", "Fetch subtitles automatically", "Settings → Playback → Subtitles online", "When a film or episode has no subtitles in your language, gets the most downloaded one a few seconds after it starts. Needs your own OpenSubtitles account and key.", \.autoSubtitles),
        number("subtitleSize", "Subtitle size", "Settings → Playback → Subtitles", "How large subtitle text is, as a percentage of normal.", range: 60...200, step: 10, unit: "%", \.subtitleSize),
        AppSettingEntry(id: "subtitleBackground", title: "Subtitle background opacity", detail: "How dark the box behind subtitles is. 0 is none, 100 is solid.", path: "Settings → Playback → Subtitles", kind: .number, options: [],
                        read: { "\(Int($0.subtitleBackground * 100))%" }, write: { s, v in guard let x = Double(v.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) else { return false }; s.subtitleBackground = AppSettings.clamp(x / 100, 0...1); return true }),
        choice("subtitleColor", "Subtitle text colour", "Settings → Playback → Subtitles", "White, yellow, green or cyan.", \.subtitleColor),
        toggle("subtitleOutline", "Subtitle outline and shadow", "Settings → Playback → Subtitles", "Keeps text readable over bright scenes. Needs the MPV engine.", \.subtitleOutline),
        // Playback: behaviour
        toggle("autoPlayNextEpisode", "Play next episode automatically", "Settings → Playback → Behaviour", "Only continues within the series you are watching.", \.autoPlayNextEpisode),
        toggle("rememberPosition", "Remember playback position", "Settings → Playback → Behaviour", "Saves where you stop in movies and episodes so Continue Watching works. Live channels have no position. Off means no resume points are written.", \.rememberPosition),
        toggle("resumeAutomatically", "Resume automatically", "Settings → Playback → Behaviour", "Continues a partly watched title where it stopped instead of from the start. Needs “Remember playback position”.", \.resumeAutomatically),
        toggle("bestVersionFirst", "Play the best version first", "Settings → Playback → Behaviour", "When a film is in your library in several qualities or folders, starts with the best (4K, then 1080p, never a cinema recording first). If it does not play, the next one is tried.", \.bestVersionFirst),
        choice("renderingProfile", "Scaling quality", "Settings → Playback → Advanced video", "Performance, Balanced or High quality for how video is scaled. Applies to streams the MPV engine plays, from the next stream you start.", \.renderingProfile),
        choice("toneMapping", "HDR tone mapping", "Settings → Playback → Advanced video", "How HDR video is shown on a normal display. Automatic is best unless colours look wrong. Applies from the next stream.", \.toneMapping),
        choice("deinterlace", "Deinterlacing", "Settings → Playback → Advanced video", "Automatic turns it on for live TV, where interlaced video is common, and leaves films alone. Choose On for an interlaced recording.", \.deinterlace),
        choice("audioProcessing", "Volume normalization", "Settings → Playback → Advanced video", "Off, Standard (evens out loudness) or Night Mode (quieter loud parts, easier on neighbours). Needs the MPV engine.", \.audioProcessing, label: { $0.rawValue }),
        toggle("stereoDownmix", "Downmix to stereo", "Settings → Playback → Advanced video", "Mixes 5.1 and 7.1 audio down to two channels, for speakers and headphones.", \.stereoDownmix),
        toggle("showDiagnosticsOverlay", "Show stream information", "Settings → Playback → Advanced video", "A small overlay with resolution, bitrate and dropped frames.", \.showDiagnosticsOverlay),
        choice("enginePreference", "Player engine", "Settings → Playback → Player engine", "Automatic uses Apple's player for HLS and MP4 and MPV for MKV, raw MPEG-TS, RTSP and DASH, and tries the other engine once if a format is not supported. Automatic is recommended.", \.enginePreference),
        AppSettingEntry(id: "subtitlePosition", title: "Subtitle vertical position", detail: "How high subtitles sit on the picture: 0% is the bottom edge, 100% is the top. Needs the MPV engine.", path: "Settings → Playback → Subtitles", kind: .number, options: [],
                        read: { "\(Int($0.subtitlePosition * 100))%" }, write: { s, v in guard let x = Double(v.trimmingCharacters(in: CharacterSet(charactersIn: "% "))), x.isFinite else { return false }; s.subtitlePosition = AppSettings.clamp(x / 100, 0...1); return true }),
        // Library
        choice("catalogRefresh", "Refresh playlists", "Settings → Library → Catalog", "How often playlists are refreshed in the background, only while the app is open and never while something plays. Fresh enough catalogues are skipped.", \.catalogRefresh),
        toggle("refreshOnOpen", "Refresh when the app opens", "Settings → Library → Catalog", "Playlists more than an hour old are refreshed as the app opens, even when the schedule is Manual.", \.refreshOnOpen),
        choice("guideRefresh", "Refresh the programme guide", "Settings → Library → Programme guide", "How often the guide is downloaded from each playlist's XMLTV address. Fresh guides are skipped.", \.guideRefresh),
        AppSettingEntry(id: "guideRetentionDays", title: "Keep past programmes", detail: "How far back the TV guide grid can scroll. Applies from the next guide download.", path: "Settings → Library → Programme guide", kind: .choice, options: ["3 hours", "1 day", "3 days", "7 days"],
                        read: { switch $0.guideRetentionDays { case 0: "3 hours"; case 1: "1 day"; case 3: "3 days"; case 7: "7 days"; default: "\($0.guideRetentionDays) days" } },
                        write: { s, v in guard let d = ["3 hours": 0, "1 day": 1, "3 days": 3, "7 days": 7][v.lowercased()] else { return false }; s.guideRetentionDays = d; return true }),
        AppSettingEntry(id: "guideHoursVisible", title: "Guide hours shown", detail: "How many hours of programmes the TV Guide grid shows at once: 2, 3, 4 or 6.", path: "TV Guide screen → Hours visible", kind: .choice, options: ["2 hours", "3 hours", "4 hours", "6 hours"],
                        read: { "\(Int($0.guideHoursVisible)) hours" }, write: { s, v in guard let h = ["2 hours": 2.0, "3 hours": 3.0, "4 hours": 4.0, "6 hours": 6.0][v.lowercased()] else { return false }; s.guideHoursVisible = h; return true }),
        toggle("autoBackup", "Back up automatically", "Settings → Library → Backup", "Once a week a backup is saved and the newest five are kept. It never contains passwords.", \.autoBackup),
        // Information only: not changed by the assistant
        info("appLock", "App lock", "Settings → Privacy → App lock", "Asks for Touch ID or the Mac password when StreamSetu opens, after the screen sleeps, or after 30 seconds away. A playing stream keeps playing. The assistant cannot change this; do it in Settings."),
        info("parental", "Parental controls and PIN", "Settings → Privacy → Parental controls", "Lock a folder from the sidebar (right-click) or from the Channel manager's Folders tab; locked folders vanish from every list and search until unlocked with the PIN. “Unlock lasts” sets how long. The assistant cannot change this."),
        info("profiles", "Profiles", "Settings → General → Profiles", "Everyone shares the same playlists; each profile has its own favourites, collections, history and resume points. A kids profile keeps locked folders hidden and needs its PIN to leave. The assistant is switched off in a kids profile."),
        info("proxy", "Proxy", "Settings → Privacy → Proxy", "Sends playlist, guide, artwork and detail requests, and streams played by MPV, through an HTTP proxy. Apple's player ignores it. The assistant cannot change this."),
        info("vpn", "VPN", "Settings → Privacy → VPN", "StreamSetu does not run a VPN; it only notices one is connected, and can pause playback if the VPN drops. The assistant cannot change this."),
        info("icloudSync", "iCloud sync", "Settings → General → iCloud", "Playlists, favourites, collections, history, resume positions, folder organisation and settings follow you to your other devices through your private iCloud. “Sync logins” also moves playlist logins and your TMDB key through iCloud Keychain. The assistant cannot change this."),
        info("lanSync", "Sync on this network", "Settings → General → Sync on this network", "Devices on the same Wi-Fi share favourites, Watch Later, collections and resume points directly, with no account or server. Pair each device once. Works between Mac, iPhone, iPad, Android phones and Fire TV."),
        info("keywordAlerts", "Guide alerts", "Settings → General → Guide alerts", "Add a word such as a sport, team or show; when a programme with that word is coming up in the next day and a half you get one reminder a minute before it starts. Needs Programme reminders on."),
        info("tmdb", "TMDB key (artwork and details)", "Settings → Library → Artwork and details", "Fills in posters, summaries, years and ratings your playlist lacks, using The Movie Database with your own free API key. Only the title and year are sent. A TMDB key also lets the app look up an actor's full filmography."),
        info("castReading", "Cast and directors", "Settings → Library → Cast and directors", "Lets you search by actor or director. The app asks your playlists slowly in the background, never while something plays, and keeps what it learns. “Read Cast Now” speeds it up. Until it has read a film, that film is not found by its cast."),
        info("integrations", "Trakt, Debrid and AI", "Settings → Integrations", "Trakt (watch history and watchlist), Debrid services (Real-Debrid, AllDebrid, Premiumize) and the AI assistant all use your own accounts or keys, stored in the Keychain and sent only to that service."),
        info("recordings", "Recordings", "Settings → Library → Recordings", "Live channels recorded while you watched them, kept on this device and out of backups. Uses the MPV player and the connection you are already watching with."),
        info("downloads", "Downloads", "Settings → Library → Downloads", "Movies and episodes saved to watch offline; kept out of backups and removable at any time. A download pauses while something is playing. There is an option to delete a download after you have watched it."),
        info("subscriptions", "Subscriptions", "Settings → General → Subscriptions", "Asked of each provider that reports it (Xtream) at most twice a day; you are warned from a week before one ends."),
        info("maintenance", "Maintenance and reset", "Settings → Library → Maintenance, Settings → Advanced", "Cache sizes, database checks, rebuilding the search index, and resets. Each reset button does one thing and none removes your playlists. “Remove all playlists and data” cannot be undone. The assistant cannot do these."),
    ]

    static func find(_ id: String) -> AppSettingEntry? { all.first { $0.id.caseInsensitiveCompare(id) == .orderedSame } }

    /// The best matches for a question, scored by how many of its words an entry mentions (the title counts most).
    static func search(_ query: String, limit: Int = 4) -> [AppSettingEntry] {
        let q = tokens(query)
        guard !q.isEmpty else { return [] }
        let phrase = query.lowercased().trimmingCharacters(in: .whitespaces)
        let scored: [(AppSettingEntry, Int)] = all.map { e in
            let t = wordSet(e.title), w = wordSet(e.words)
            func has(_ set: Set<String>, _ tok: String) -> Bool { set.contains { $0.hasPrefix(tok) } }
            return (e, q.reduce(phrase.count >= 5 && e.words.contains(phrase) ? 4 : 0) { acc, tok in acc + (has(t, tok) ? 3 : 0) + (has(w, tok) ? 1 : 0) })
        }
        return scored.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    static func describe(_ e: AppSettingEntry, _ s: AppSettings) -> String {
        var t = "id: \(e.id) | \(e.title) | where: \(e.path)"
        if let r = e.read { t += " | now: \(r(s))" }
        if !e.options.isEmpty { t += " | options: " + e.options.joined(separator: ", ") }
        t += e.changeable ? " | can change: yes" : " | can change: no (explain where to find it)"
        return t + "\n   " + e.detail
    }

    nonisolated fileprivate static let stopWords: Set<String> = ["the", "a", "an", "to", "of", "in", "on", "off", "my", "me", "i", "it", "is", "do", "how", "what", "where", "can", "turn", "set", "change", "make", "and", "or", "for", "with", "when", "does", "this", "that", "should", "setting", "settings", "option", "options", "please", "use", "get", "want", "mode"]
    nonisolated fileprivate static func wordSet(_ s: String) -> Set<String> { Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)) }
    nonisolated fileprivate static func tokens(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 3 && !stopWords.contains($0) }.map { $0.hasSuffix("s") && $0.count > 4 ? String($0.dropLast()) : $0 }
    }
}

// MARK: - how-to knowledge

/// Short, accurate how-tos for what the app does, found by keyword. Only things the app really has.
enum AppGuide {
    struct Article { let title: String; let keys: [String]; let body: String }

    static let articles: [Article] = [
        .init(title: "Adding a playlist or source", keys: ["add", "playlist", "source", "setup", "connect", "type"], body: "Open Settings → Library → Manage (or the Add Source screen when you first open the app). Choose the Type, fill in the fields, and press Add Source. You can also paste any address into the box at the top (“Paste any address and it fills in the rest”). StreamSetu provides no channels or subscriptions: you add sources you are entitled to use, and everything stays on this device."),
        .init(title: "Adding Xtream", keys: ["xtream", "xtream codes", "username", "server"], body: "Adding Xtream: choose Type → Xtream, then fill in Server (like http://host:port), Username and Password, as your provider gave them. The name is optional. Press Add Source; the channels, movies and series load and the guide address is picked up automatically."),
        .init(title: "Adding an M3U link", keys: ["m3u", "link", "url", "json"], body: "Adding an M3U link: choose Type → M3U or JSON link and paste the Playlist address (https://example.com/playlist.m3u). For a file on this device choose Type → M3U or JSON file and press Choose File…. A guide (XMLTV) address can be added to the playlist afterwards."),
        .init(title: "Adding Jellyfin or Emby", keys: ["jellyfin", "emby", "media server"], body: "Adding Jellyfin or Emby: choose the type, then fill in the Server address, your Username and Password for that server. Your library of movies and series appears under Movies and Series."),
        .init(title: "Adding Plex", keys: ["plex", "token"], body: "Adding Plex: choose Type → Plex, enter the Server address (like http://host:32400) and your X-Plex-Token. The token is stored in the Keychain on this device."),
        .init(title: "Adding Stalker or HDHomeRun", keys: ["stalker", "mag", "portal", "hdhomerun", "tuner"], body: "Stalker / MAG portal asks for the Portal address and the MAC address. HDHomeRun asks for the Tuner address (like 192.168.1.50 or hdhomerun.local), and “Find Tuners on This Network” can look for it. (The App Store build leaves Stalker out.)"),
        .init(title: "Guide problems", keys: ["guide", "epg", "xmltv", "empty", "programme", "wrong", "time", "hours"], body: "The guide comes from each playlist's XMLTV address. If it is empty: check the playlist has a guide address, run a guide refresh, and make sure the provider really returns guide data (channels still play without it). If times are hours off, shift that playlist's guide in its settings. If few channels have entries, the provider's channel ids do not match the playlist's. Programmes are kept up to seven days ahead; how far back is “Keep past programmes”."),
        .init(title: "Player engines", keys: ["engine", "avplayer", "mpv", "codec", "format", "mkv", "hls"], body: "StreamSetu has two players. Apple's AVPlayer is best for HLS and MP4, with hardware decoding. MPV opens what Apple's cannot: MKV, raw MPEG-TS, RTSP and DASH, and offers more audio and picture options (pause and rewind of live TV, volume normalization, subtitle position). Settings → Playback → Player engine on Automatic picks for each stream and tries the other once if a format fails; a playlist or channel can have its own choice. AirPlay and Picture in Picture depend on the engine in use."),
        .init(title: "Sign-in and login problems", keys: ["login", "password", "expired", "401", "403", "authorization", "rejected", "denied", "too many", "devices"], body: "A rejected login usually means the username or password is wrong or expired, or the account is already streaming on too many devices. Check them with your provider and update them in the playlist's settings. StreamSetu does not see your provider's account rules."),
        .init(title: "Where StreamSetu keeps things", keys: ["local", "stored", "storage", "data", "keychain", "account", "cloud", "collect", "analytics"], body: "Your library, favourites, history and settings are stored on this device. Playlist logins and API keys are in the Keychain. No StreamSetu account is needed and no content is provided by StreamSetu. iCloud or network sync, TMDB, Trakt, Debrid and an AI are optional and use your own accounts; they are off until you set them up. The assistant never sends playlist addresses, logins or tokens."),
        .init(title: "Search", keys: ["search", "find", "filter", "sort", "actor", "genre", "mood", "command"], body: "The search box at the top searches channels, movies, series, episodes and the guide together. It also understands sentences: “telugu movies 2024 unwatched”, “top rated hindi series”, “newest movies”, “comedy not horror”, “a tense thriller under 2 hours”, an actor's name (“prabhas movies”), moods (“date night”, “with the kids”, “something short”, “binge”). Typing commands works too: “go to live tv”, “play Inception”, “resume”, “add Jersey to watch later”. With an AI connected, a request that finds nothing is passed to it, and its suggestions are matched against your library."),
        .init(title: "Favorites and Watch Later", keys: ["favorite", "favourite", "watch later", "watchlist", "save", "heart", "bookmark"], body: "Favorites (heart) and Watch Later (bookmark) are two lists per profile. Use the buttons on a title's page or its right-click menu; both lists are in the sidebar under Home. Search commands also work: “add Jersey to favourites”."),
        .init(title: "Continue Watching and history", keys: ["continue", "resume", "history", "recent", "watched", "unwatched", "mark"], body: "Continue Watching lists partly watched movies and episodes, if “Remember playback position” is on. Recently Watched and Watch History list what you played. A title can be marked Watched or Unwatched from its menu. “Watch Privately” plays something without saving it to history."),
        .init(title: "Collections", keys: ["collection", "playlist", "group", "list"], body: "Collections are your own named groups of titles. Add a title with its menu (“Add to collection”) and remove it with “Remove from collection”. They are in the sidebar under Home and sync with your other devices if sync is on."),
        .init(title: "Live TV and the guide", keys: ["live", "channel", "guide", "epg", "programme", "program", "schedule", "now", "tonight"], body: "Live TV lists channels by folder; TV Guide shows what is on now and next as a grid, which scrolls back as far as “Keep past programmes” allows. Programme reminders add a bell to upcoming shows. If guide times are hours off, a playlist can shift its guide (Playlists → its settings)."),
        .init(title: "Playlists", keys: ["playlist", "add", "source", "xtream", "m3u", "stalker", "refresh", "provider"], body: "Playlists are managed in Library settings → Manage (add, edit, refresh, organise channels and folders). They are refreshed on a schedule you choose and when the app opens (if that is on). Passwords and full playlist addresses are never exported in a backup; a restored playlist comes back switched off and asks for its login."),
        .init(title: "Recording and downloads", keys: ["record", "recording", "download", "offline", "save"], body: "Live channels can be recorded while you watch them; recordings and downloads live on this device and stay out of backups. Movies and episodes can be downloaded to watch offline; downloads pause while something plays."),
        .init(title: "Subtitles", keys: ["subtitle", "caption", "cc", "opensubtitles"], body: "Preferred language, “Show by default”, size, colour, background and outline are in Settings → Playback → Subtitles. Subtitles can be fetched online from OpenSubtitles with your own free account and API key; turn on “Fetch automatically” to get one when none exists in your language. Inside the player, the subtitle button switches tracks."),
        .init(title: "Audio", keys: ["audio", "sound", "language", "volume", "mute", "night", "loud", "stereo", "surround"], body: "Preferred audio language, output device and volume normalization (Off, Standard, Night Mode) are in Settings → Playback. “Downmix to stereo” mixes surround to two channels. Inside the player you can switch audio tracks, change volume and mute."),
        .init(title: "Playback problems", keys: ["buffer", "buffering", "stutter", "freeze", "lag", "slow", "error", "fail", "not playing", "black", "no video", "no sound", "fix"], body: "If a stream buffers or fails: (1) try another player engine for that playlist or app-wide (Settings → Playback → Player engine; Automatic retries the other engine once); (2) raise buffering to Large buffer for poor connections, or Low latency for live TV on a fast one; (3) set Hardware decoding to Software if the picture glitches; (4) check the provider is reachable and the playlist is refreshed; (5) a VPN or proxy can slow streams. Ask the assistant to look at what is playing: it can see the player's state."),
        .init(title: "Privacy and safety", keys: ["privacy", "private", "secure", "lock", "pin", "kids", "parental", "profile"], body: "Playlist logins and API keys live in the Keychain. The app can be locked with Touch ID or the Mac password. Folders can be locked behind a PIN and a kids profile hides them. The AI assistant sends only the words you type (and, if you allow it with the eye button, the screen name, what is playing and library counts), never logins, playlist addresses or watch history lists."),
        .init(title: "Trakt, Debrid and AI", keys: ["trakt", "debrid", "real-debrid", "alldebrid", "premiumize", "ai", "gemini", "openai", "claude", "ollama", "api key", "key", "scrobble"], body: "Settings → Integrations: Trakt marks things watched and can import your watchlist into Watch Later (your own Trakt app keys); Debrid services resolve hoster links; the AI assistant uses your own key from Apple Intelligence (on device), Gemini, OpenRouter, Claude, OpenAI, Groq, NVIDIA, Ollama Cloud or your own Ollama. Free tiers exist for several; limits and prices are shown next to each."),
        .init(title: "Backup and sync", keys: ["backup", "restore", "sync", "icloud", "devices", "export"], body: "Library settings → Backup saves playlists, collections, favourites, preferences and history (never passwords). iCloud sync and network sync keep favourites, Watch Later, collections and resume points the same across devices."),
        .init(title: "Keyboard", keys: ["keyboard", "shortcut", "key", "hotkey"], body: "⌘K (or /) focuses search; Esc clears it; ↑↓ choose a result and Return opens it. Return plays a selected channel."),
    ]

    static func search(_ query: String, limit: Int = 2) -> [Article] {
        let q = AppSettingsCatalog.tokensForGuide(query)
        guard !q.isEmpty else { return [] }
        let scored = articles.map { a -> (Article, Int) in
            let hay = AppSettingsCatalog.wordsForGuide(a.title + " " + a.keys.joined(separator: " ")), body = AppSettingsCatalog.wordsForGuide(a.body)
            return (a, q.reduce(0) { acc, tok in acc + (hay.contains { $0.hasPrefix(tok) } ? 3 : 0) + (body.contains { $0.hasPrefix(tok) } ? 1 : 0) })
        }
        return scored.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
}

extension AppSettingsCatalog { nonisolated static func wordsForGuide(_ s: String) -> Set<String> { wordSet(s) }
    nonisolated static func tokensForGuide(_ s: String) -> [String] { tokens(s) } }
