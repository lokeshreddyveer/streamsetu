import Foundation

/// Hand-written how-tos and the few "about Setu" entries. Every step names a control the app really has. `reviewed` is true only where each step's label was checked in the code.
enum AtlasRecipes {
    private static func step(_ say: String, _ anchor: String? = nil, _ reach: AtlasReach? = nil) -> AtlasStep { AtlasStep(say: say, anchor: anchor, reach: reach) }

    private static func how(_ id: String, _ title: String, _ summary: String, aliases: [String] = [], path: [String]? = nil, reach: AtlasReach = .none, steps: [AtlasStep],
                            related: [String] = [], platforms: AtlasPlatforms = .all, shortcut: String? = nil, reviewed: Bool = false) -> AtlasEntry {
        .make(id, .recipe, title, summary, path: path ?? ["How to", title], reach: reach, aliases: aliases, platforms: platforms, shortcut: shortcut, related: related, recipe: steps, safety: .read, reviewed: reviewed)
    }

    private static let addPath = ["Add Playlist"]
    private static let addReach = AtlasReach.modal("addPlaylist")
    private static let allButStore: AtlasPlatforms = [.mac, .iPhone, .iPad, .dmgOnly]

    static let all: [AtlasEntry] = sources + playbackFixes + library + people + devices + around + meta

    // MARK: adding sources

    static let sources: [AtlasEntry] = [
        how("recipe.addXtream", "Add an Xtream provider", "Enter the server address, username and password your provider gave you.",
            aliases: ["xtream codes", "iptv login", "username password provider", "add my iptv subscription", "xstream"], path: addPath, reach: addReach,
            steps: [step("Open Add Playlist.", "menu.file.addPlaylist", addReach), step("Pick the Xtream tile."),
                    step("Fill in Server (like http://host:port), Username and Password."), step("Press Connect. Channels, movies and series load and the guide address is picked up.")],
            related: ["guide.addingXtream", "recipe.refreshPlaylist", "recipe.fixEmptyGuide"], reviewed: true),
        how("recipe.addM3U", "Add an M3U link", "Paste the playlist address your provider gave you.",
            aliases: ["m3u url", "add playlist link", "m3u8", "paste playlist url", "iptv link"], path: addPath, reach: addReach,
            steps: [step("Open Add Playlist.", "menu.file.addPlaylist", addReach), step("Pick the M3U or JSON link tile."), step("Paste the Playlist address (https://example.com/playlist.m3u)."),
                    step("Press Connect. A guide (XMLTV) address can be added afterwards.", "recipe.addGuideAddress")],
            related: ["guide.addingAnM3uLink", "recipe.addM3UFile", "recipe.pasteAnyAddress"], reviewed: true),
        how("recipe.addM3UFile", "Add an M3U file from this device", "Pick a playlist file you saved on this device.",
            aliases: ["local playlist", "m3u file", "import playlist file", "open playlist file"], path: addPath, reach: addReach,
            steps: [step("Open Add Playlist.", "menu.file.addPlaylist", addReach), step("Pick the M3U or JSON file tile."), step("Press Choose File… and pick the file."), step("Press Connect.")],
            related: ["recipe.addM3U", "guide.addingAnM3uLink"], reviewed: true),
        how("recipe.addJellyfin", "Add a Jellyfin server", "Enter your server address, username and password. Your movies and series show up under Movies and Series.",
            aliases: ["jellyfin server", "media server", "connect jellyfin"], path: addPath, reach: addReach,
            steps: [step("Open Add Playlist.", "menu.file.addPlaylist", addReach), step("Pick the Jellyfin tile."), step("Fill in Server, Username and Password for that server."), step("Press Connect.")],
            related: ["guide.addingJellyfinOrEmby", "recipe.addEmby"], reviewed: true),
        how("recipe.addEmby", "Add an Emby server", "Works like Jellyfin: server address, username and password.",
            aliases: ["emby server", "connect emby"], path: addPath, reach: addReach,
            steps: [step("Open Add Playlist.", "menu.file.addPlaylist", addReach), step("Pick the Emby tile."), step("Fill in Server, Username and Password."), step("Press Connect.")],
            related: ["guide.addingJellyfinOrEmby", "recipe.addJellyfin"], reviewed: true),
        how("recipe.addPlex", "Add a Plex server", "Enter the server address and your X-Plex-Token. The token is kept in the Keychain on this device.",
            aliases: ["plex server", "plex token", "connect plex"], path: addPath, reach: addReach,
            steps: [step("Open Add Playlist.", "menu.file.addPlaylist", addReach), step("Pick the Plex tile."), step("Enter the Server address (like http://host:32400) and your X-Plex-Token."), step("Press Connect.")],
            related: ["guide.addingPlex"], reviewed: true),
        how("recipe.addStalker", "Add a Stalker or MAG portal", "Enter the portal address and the MAC address. The App Store build leaves this type out.",
            aliases: ["stalker portal", "mag box", "mac address portal", "ministra"], path: addPath, reach: addReach,
            steps: [step("Open Add Playlist.", "menu.file.addPlaylist", addReach), step("Choose the Stalker portal tile."), step("Fill in the Portal address and the MAC address."), step("Press Connect.")],
            related: ["guide.addingStalkerOrHdhomerun"], platforms: allButStore, reviewed: true),
        how("recipe.addHDHomeRun", "Add an HDHomeRun tuner", "Enter the tuner address, or let the app look for tuners on your network.",
            aliases: ["hdhomerun", "tv tuner", "antenna tuner", "over the air tuner"], path: addPath, reach: addReach,
            steps: [step("Open Add Playlist.", "menu.file.addPlaylist", addReach), step("Choose the TV tuner or receiver tile, then HDHomeRun."), step("Enter the Tuner address (like 192.168.1.50 or hdhomerun.local), or press Find Tuners on This Network and pick yours."), step("Press Connect.")],
            related: ["guide.addingStalkerOrHdhomerun"], reviewed: true),
        how("recipe.pasteAnyAddress", "Paste any address and let the app work it out", "Paste a link into the box at the top of Add Playlist. StreamSetu works out the type and fills in the rest.",
            aliases: ["paste url", "auto detect playlist", "detect source type", "drop a link"], path: addPath, reach: addReach,
            steps: [step("Open Add Playlist.", "menu.file.addPlaylist", addReach), step("Paste the address into the box at the top (Paste a playlist link, server address or stream)."), step("Press Continue (or Return) to open the form it chose, check what was filled in, then press Connect.")],
            related: ["recipe.addM3U", "recipe.addXtream"], reviewed: true),
        how("recipe.refreshPlaylist", "Refresh a playlist", "Reload channels, movies and series from your providers now instead of waiting for the schedule.",
            aliases: ["update playlist", "reload channels", "sync playlists", "playlist not updating", "get new channels"], path: ["File", "Refresh All Playlists"],
            steps: [step("Choose File, then Refresh All Playlists (Command R).", "menu.file.refreshAll"), step("On iPhone, tap the same tab three times to refresh.", "gesture.ios.tabTripleTap"), step("To change how often it happens, open Settings, Library, Catalog and choose Refresh automatically.", "setting.catalogRefresh", .settingsPage("Library"))],
            related: ["setting.refreshOnOpen", "setting.catalogRefresh"], reviewed: true),
        how("recipe.addGuideAddress", "Add a guide (XMLTV) address", "Give a playlist the address of its programme guide so the TV Guide fills in.",
            aliases: ["epg url", "xmltv link", "add epg", "guide link", "tv guide source"], path: ["Playlists", "Edit", "Guide address"], reach: .modal("playlists"),
            steps: [step("Open Playlists and pick the playlist.", "screen.playlists", .modal("playlists")), step("Press Edit and enter the Guide (XMLTV) address, or press From File… to use a guide file, then press Save. The guide is refreshed straight away."), step("Open TV Guide to check.", "screen.tab.guide")],
            related: ["recipe.fixEmptyGuide", "recipe.shiftGuideTimes"], reviewed: true),
        how("recipe.shiftGuideTimes", "Fix guide times that are hours off", "Shift one playlist's guide forward or back in half hour steps.",
            aliases: ["epg time offset", "guide wrong time", "programme times wrong", "guide time shift", "timezone guide"], path: ["Playlists", "Guide time shift"], reach: .modal("playlists"),
            steps: [step("Open Playlists and pick the playlist.", "screen.playlists", .modal("playlists")), step("Open its Guide section, find Guide time shift and choose the offset, from minus 12 to plus 12 hours. The guide refreshes at once.")],
            related: ["recipe.fixEmptyGuide", "guide.guideProblems"], reviewed: true),
    ]

    // MARK: fixing playback, guide and artwork

    static let playbackFixes: [AtlasEntry] = [
        how("recipe.fixBuffering", "Fix buffering", "Check what is playing first, then try a bigger buffer, software decoding or the other player engine.",
            aliases: ["stutter", "freezing", "lag", "keeps buffering", "choppy", "stream keeps stopping", "slow stream"], path: ["Playback"],
            steps: [step("Ask Setu to check what is playing, or look at the stream's error."), step("Open Settings, Playback and set Buffering mode to Large buffer for a poor connection, or Low latency for live TV on a fast one.", "setting.bufferingMode", .settingsPage("Playback")),
                    step("If the picture glitches, set Hardware decoding to Software decoding.", "setting.hardwareDecoding"), step("Still stuttering? Try the other Player engine.", "setting.enginePreference")],
            related: ["guide.playbackProblems", "diag.playback", "recipe.switchEngine"], reviewed: true),
        how("recipe.fixEmptyGuide", "Fix an empty TV Guide", "Check the playlist has a guide address, refresh the guide, and make sure the provider really returns guide data.",
            aliases: ["epg empty", "no guide data", "guide blank", "guide not loading", "no programmes"], path: ["TV Guide"],
            steps: [step("Open Playlists and check the playlist has a guide address (its Guide section, or Edit to add one).", "recipe.addGuideAddress", .modal("playlists")), step("Refresh the guide with Refresh Guide in the playlist's Guide section or in Settings, Library, Programme guide.", "setting.guideRefresh", .settingsPage("Library")),
                    step("If channels have no entries, the provider's channel ids do not match the playlist's; the provider has to fix that."), step("If times are hours off, use Guide time shift.", "recipe.shiftGuideTimes")],
            related: ["guide.guideProblems", "diag.guide", "setting.guideRefresh"], reviewed: true),
        how("recipe.fixWrongArtwork", "Fix wrong or missing posters", "Posters, summaries and ratings come from your playlist first and from TMDB for what is missing. Add your own free TMDB key, then run matching.",
            aliases: ["wrong poster", "missing artwork", "no posters", "wrong cover", "artwork not showing", "tmdb key", "rematch artwork"], path: ["Settings", "Library", "Artwork and details"], reach: .settingsPage("Library"),
            steps: [step("Open Settings, Library, Artwork and details.", "setting.tmdb", .settingsPage("Library")), step("Add your own TMDB key if you have one, and make sure Match artwork in the background is on."),
                    step("Press Match now to match what is still missing."), step("Matching needs the network and sends only the title and year; it never sends titles from locked or hidden folders.")],
            related: ["setting.tmdb", "guide.privacyAndSafety"], reviewed: true),
        how("recipe.switchEngine", "Switch the player engine", "Apple's player suits HLS and MP4; MPV opens MKV, MPEG-TS, RTSP and DASH. Automatic picks for each stream.",
            aliases: ["mpv", "avplayer", "change player", "use mpv", "codec not supported", "mkv wont play"], path: ["Settings", "Playback", "Player engine"], reach: .settingsPage("Playback"),
            steps: [step("Open Settings, Playback.", "screen.settings.playback", .settingsPage("Playback")), step("Choose Player engine: Automatic (recommended), Apple AVPlayer or MPV.", "setting.enginePreference"), step("Or switch for the stream playing now from the player's menu.", "control.player.engineSwitch")],
            related: ["guide.playerEngines", "diag.engine"], reviewed: true),
        how("recipe.airplayAndPip", "Use AirPlay or Picture in Picture", "Both depend on which engine is playing.",
            aliases: ["airplay", "cast to tv", "picture in picture", "pip", "floating video", "apple tv"], path: ["Player"],
            steps: [step("Start something playing.", "screen.tab.liveTV"), step("Use the AirPlay or Picture in Picture button in the player controls."), step("If a button is missing, the stream is probably playing in MPV. Both buttons only appear with Apple's player, so switch the engine.", "setting.enginePreference")],
            related: ["recipe.switchEngine", "guide.playerEngines", "diag.noPipAirplay"], reviewed: true),
    ]

    // MARK: subtitles, audio, recording, downloads, timers

    static let library: [AtlasEntry] = [
        how("recipe.setupSubtitles", "Set up subtitles", "Choose your language and whether they start on, then look and fetch options.",
            aliases: ["turn on subtitles", "subs always on", "captions", "opensubtitles", "get subtitles", "subtitle language"], path: ["Settings", "Playback", "Subtitles"], reach: .settingsPage("Playback"),
            steps: [step("Open Settings, Playback, Subtitles.", "screen.settings.playback", .settingsPage("Playback")), step("Pick the Preferred subtitle language.", "setting.preferredSubtitleLanguage"), step("Turn on Show subtitles by default.", "setting.subtitlesByDefault"),
                    step("Adjust Subtitle size, colour and background if needed.", "setting.subtitleSize"), step("To fetch missing ones from OpenSubtitles, add your own free account and key, then turn on Fetch subtitles automatically.", "setting.autoSubtitles")],
            related: ["guide.subtitles", "setting.subtitlePosition"], reviewed: true),
        how("recipe.chooseAudioLanguage", "Choose the audio language", "Set a preferred language for streams with several audio tracks, or switch inside the player.",
            aliases: ["dubbed", "change audio track", "hindi audio", "original language", "audio language"], path: ["Settings", "Playback", "Audio"], reach: .settingsPage("Playback"),
            steps: [step("Open Settings, Playback, Audio.", "screen.settings.playback", .settingsPage("Playback")), step("Pick the Preferred audio language.", "setting.preferredAudioLanguage"), step("Inside the player, use the audio button to switch tracks for this stream.")],
            related: ["guide.audio"], reviewed: true),
        how("recipe.record", "Record a live channel", "Record the live channel you are watching. Recordings stay on this device and out of backups.",
            aliases: ["dvr", "record tv", "record a show", "save live tv", "recording"], path: ["Player", "Record this channel"],
            steps: [step("Start the channel playing.", "screen.tab.liveTV"), step("Press the red dot (Record this channel) in the player controls. It only appears for a live channel playing in the MPV player."), step("Press it again to stop. Find the recording afterwards in Settings, Library, Recordings.", "setting.recordings", .settingsPage("Library"))],
            related: ["guide.recordingAndDownloads", "setting.recordings", "diag.recording"], platforms: [.mac], reviewed: true),
        how("recipe.download", "Download for offline", "Save a movie or episode to watch without a connection. Downloads pause while something plays.",
            aliases: ["offline", "save movie", "download episode", "watch offline", "travel"], path: ["Title page", "Download"],
            steps: [step("Open the movie or episode.", "screen.tab.movies"), step("Press Download."), step("Watch it later from the Downloads list (Settings, Library, Downloads on the Mac; the Downloads screen on iPhone and iPad).", "setting.downloads")],
            related: ["guide.recordingAndDownloads", "setting.downloads"], reviewed: true),
        how("recipe.sleepTimer", "Set a sleep timer", "Stop playback after a set time or at the end of this episode.",
            aliases: ["stop after", "fall asleep", "turn off tv later", "timer"], path: ["Playback", "Sleep Timer"],
            steps: [step("Start something playing."), step("Choose Playback, then Sleep Timer in the menu bar, or open the player's ... menu and choose Sleep Timer.", "menu.playback.sleepTimer"), step("Pick a time or the end of this item. Cancel Sleep Timer undoes it.")],
            related: ["menu.playback.sleepTimer", "intent.sleepTimer"], reviewed: true),
        how("recipe.multiView", "Watch several channels at once", "Multi-View shows several live channels together; one has the sound.",
            aliases: ["split screen", "multiview", "multi view", "watch two games", "many channels"], path: ["Playback", "Open Multi-View"],
            steps: [step("Choose Playback, then Open Multi-View.", "menu.playback.openMultiView", .window("multiview")), step("Add channels to the tiles."), step("Tap a tile to give it the sound; double-tap to enlarge it.", "gesture.mac.multiViewDoubleClick")],
            related: ["screen.multiview"], reviewed: true),
        how("recipe.watchPrivately", "Watch without saving history", "Watch Privately plays a title without writing it to your history or resume points.",
            aliases: ["private viewing", "dont save history", "incognito", "hide what i watch"], path: ["Title menu", "Watch Privately"],
            steps: [step("Open the title's menu (right-click on Mac), or the More menu on its page.", "context.tile.menu"), step("Choose Watch Privately.")],
            related: ["guide.continueWatchingAndHistory"], reviewed: true),
    ]

    // MARK: lists, search, people

    static let people: [AtlasEntry] = [
        how("recipe.makeCollection", "Make a collection", "Collections are your own named groups of titles.",
            aliases: ["create list", "playlist of movies", "group titles", "new collection"], path: ["Collections"], reach: .shortcut("collections"),
            steps: [step("Open Collections in the sidebar under Home, and choose New Collection.", "screen.shortcut.collections", .shortcut("collections")), step("On any title's menu, choose Add to Collection and pick it.", "context.tile.menu"), step("Remove a title with Remove from collection.")],
            related: ["guide.collections"], reviewed: true),
        how("recipe.favoritesWatchLater", "Save titles to Favorites or Watch Later", "Favorites (heart) and Watch Later (bookmark) are two lists for each profile.",
            aliases: ["heart a movie", "bookmark", "watchlist", "add to favourites", "save for later"], path: ["Home", "Favorites"], reach: .shortcut("favorites"),
            steps: [step("Use the heart or bookmark button on a title's page, or its menu.", "context.tile.menu"), step("Find the lists in the sidebar under Home.", "screen.shortcut.favorites", .shortcut("favorites")), step("You can also type it in search: add Jersey to favourites.", "recipe.searchCommands")],
            related: ["guide.favoritesAndWatchLater", "screen.shortcut.watchLater"], reviewed: true),
        how("recipe.continueWatching", "Pick up where you left off", "Continue Watching lists partly watched movies and episodes.",
            aliases: ["resume movie", "where i stopped", "unfinished", "resume watching"], path: ["Home", "Continue Watching"], reach: .shortcut("continueWatching"),
            steps: [step("Open Continue Watching in the sidebar.", "screen.shortcut.continueWatching", .shortcut("continueWatching")), step("If it is empty, turn on Remember playback position.", "setting.rememberPosition", .settingsPage("Playback")), step("To resume without asking, turn on Resume automatically.", "setting.resumeAutomatically")],
            related: ["guide.continueWatchingAndHistory"], reviewed: true),
        how("recipe.searchCommands", "Type commands in the search box", "The top search box also takes commands such as go to live tv, play Inception, resume, or add Jersey to watch later.",
            aliases: ["command k", "search commands", "go to", "quick open", "voice style commands"], path: ["Search"],
            steps: [step("Press Command K to focus the search box (on iPad, Command F opens Search).", "menu.navigate.search"), step("Type a command such as go to live tv, play Inception or resume."), step("Press Return, or use the arrows to choose a result.")],
            related: ["guide.search", "guide.keyboard"], platforms: [.mac, .iPad], reviewed: true),
        how("recipe.searchByActor", "Search by actor or director", "Type a person's name to see their films and series in your library.",
            aliases: ["films with actor", "cast search", "director", "find by actor"], path: ["Settings", "Library", "Cast and directors"], reach: .settingsPage("Library"),
            steps: [step("Type the name in the search box.", "menu.navigate.search"), step("If a film is missing, open Settings, Library, Cast and directors and press Read Cast Now.", "setting.castReading", .settingsPage("Library")), step("Until a film's cast has been read it is not found by cast.")],
            related: ["setting.castReading"], reviewed: true),
        how("recipe.hideFolders", "Hide or unhide a folder", "Hiding takes a folder out of the sidebar without deleting it from the provider.",
            aliases: ["hide category", "remove folder from sidebar", "unhide folder", "hidden folders"], path: ["Sidebar", "Folder menu"],
            steps: [step("Right-click the folder in the sidebar and choose Hide Folder, or open the Channel manager, choose its Folders tab and press the eye on the folder.", "screen.channelManager.folders", .modal("channelManager")), step("To bring it back, open the Channel manager, Folders tab, and press the eye again (it says Hidden).", "screen.settings.channelManager", .modal("channelManager")), step("To hide empty folders automatically, turn on Hide empty folders.", "setting.hideEmptyFolders")],
            related: ["screen.settings.channelManager"], reviewed: true),
        how("recipe.reorderChannels", "Organise channels and folders", "The Channel manager renames, regroups, hides and favourites channels, and reorders and hides folders. Nothing changes at your provider.",
            aliases: ["channel manager", "reorder channels", "rename channels", "sort channels", "hide dead channels"], path: ["Channel Manager"], reach: .modal("channelManager"),
            steps: [step("Open the Channel Manager.", "screen.settings.channelManager", .modal("channelManager")), step("On the Channels tab, tick channels, then use Rename, Folder, Guide, Hide or Favorite. Restore undoes your changes."), step("On the Folders tab, drag a folder or use its arrows to reorder, or use the Order menu to sort A to Z."), step("To change how channels are sorted, use Channel order in Settings, General.", "setting.defaultChannelSort", .settingsPage("General"))],
            related: ["setting.defaultChannelSort", "recipe.hideFolders"], reviewed: true),
    ]

    // MARK: profiles, sync, backup

    static let devices: [AtlasEntry] = [
        how("recipe.kidsProfile", "Make a kids profile and lock a folder", "Setu explains this but never changes it: profiles, PINs and locks are done by you in Settings.",
            aliases: ["kids mode", "parental controls", "child profile", "lock a folder", "pin"], path: ["Settings", "Library", "Profiles"], reach: .settingsPage("Library"),
            steps: [step("Open Settings, Library, Profiles, press Add a Profile…, turn on Kids profile and set its PIN (4 to 8 digits). It is the PIN needed to leave the kids profile.", "setting.profiles", .settingsPage("Library")), step("Set a PIN in Settings, Privacy, Parental controls (Set PIN…).", "setting.parental", .settingsPage("Privacy")),
                    step("Lock a folder with Lock Folder with PIN from its right-click menu in the sidebar, or the lock button in the Channel manager's Folders tab.", "context.sidebar.folderLock"), step("Unlock lasts sets how long an unlock holds. Setu is switched off in a kids profile.")],
            related: ["setting.parental", "setting.profiles"], reviewed: true),
        how("recipe.moveToNewDevice", "Move to a new device", "Back up on the old one and restore, or let sync carry your library over.",
            aliases: ["new phone", "new mac", "transfer data", "switch devices", "migrate"], path: ["Settings", "Library", "Backup"], reach: .settingsPage("Library"),
            steps: [step("On the old device, use Export Backup… in Settings, Library, Backup (on iPhone and iPad, More, Backup and Restore).", "recipe.backupRestore", .settingsPage("Library")), step("Or turn on iCloud sync on both devices.", "recipe.icloudSync"),
                    step("Restored playlists come back switched off and ask for their login again; passwords are never in a backup.")],
            related: ["guide.backupAndSync", "recipe.lanSyncPair"], reviewed: true),
        how("recipe.backupRestore", "Back up and restore", "A backup holds playlists, collections, favourites, preferences and history, never passwords.",
            aliases: ["export backup", "restore backup", "save my settings", "auto backup"], path: ["Settings", "Library", "Backup"], reach: .settingsPage("Library"),
            steps: [step("Open Settings, Library, Backup.", "screen.settings.backup", .settingsPage("Library")), step("Press Export Backup… to save one now, or turn on Back up automatically.", "setting.autoBackup"), step("To restore, choose Restore Backup… and confirm; logins must be entered again.")],
            related: ["guide.backupAndSync", "setting.autoBackup"], reviewed: true),
        how("recipe.icloudSync", "Turn on iCloud sync", "Keeps favourites, history, collections, resume points and settings the same across your devices through your private iCloud.",
            aliases: ["sync devices", "cloud sync", "icloud", "sync favourites"], path: ["Settings", "Library", "iCloud"], reach: .settingsPage("Library"),
            steps: [step("Sign in to iCloud with the same Apple ID on each device.", nil), step("Open Settings, Library, iCloud and turn on Sync with iCloud on each device (on iPhone and iPad, More, iCloud Sync).", "setting.icloudSync", .settingsPage("Library")), step("Turn on Sync logins if logins should move too, through iCloud Keychain.")],
            related: ["guide.backupAndSync", "recipe.lanSyncPair"], reviewed: true),
        how("recipe.lanSyncPair", "Sync on your own network", "Devices on the same Wi-Fi share favourites, Watch Later, collections and resume points directly, with no account.",
            aliases: ["wifi sync", "local sync", "sync without icloud", "pair devices", "android sync"], path: ["Settings", "Library", "Sync on this network"], reach: .settingsPage("Library"),
            steps: [step("Open Settings, Library, Sync on this network on both devices (on iPhone and iPad, More, Sync on this network) and turn it on.", "setting.lanSync", .settingsPage("Library")), step("On both devices press Add a Device…, then pick the other device in the list and press Pair."), step("Check both screens show the same six digits and press They Match. It works between Mac, iPhone, iPad, Android phones and Fire TV.")],
            related: ["guide.backupAndSync", "recipe.icloudSync"], reviewed: true),
    ]

    // MARK: around the app

    static let around: [AtlasEntry] = [
        how("recipe.siriShortcuts", "Use Siri and the Shortcuts app", "StreamSetu has actions for playing a channel, pause, resume, stop, sleep timer and next channel.",
            aliases: ["siri", "shortcuts app", "hey siri play", "voice control", "app intents"], path: ["Siri and Shortcuts"],
            steps: [step("Say Play <channel> in StreamSetu to Siri.", "intent.playChannel"), step("Or open the Shortcuts app and add a StreamSetu action.")],
            related: ["intent.playChannel", "intent.sleepTimer"], platforms: [.iPhone, .iPad], reviewed: true),
        how("recipe.changeTheme", "Change the theme or accent colour", "Every theme is dark and restyles the whole app; the accent colour is used for the selected tab, buttons and progress.",
            aliases: ["dark mode", "light mode", "colours", "change colors", "appearance"], path: ["Settings", "Appearance"], reach: .settingsPage("Appearance"),
            steps: [step("Open Settings, Appearance.", "screen.settings.appearance", .settingsPage("Appearance")), step("Choose a Theme.", "setting.theme"), step("Choose an Accent colour.", "setting.accent")],
            related: ["setting.density", "setting.highContrast"], reviewed: true),
        how("recipe.keyboardOnly", "Use the app from the keyboard", "Most things have a key: search, tabs, playback and channel changes.",
            aliases: ["keyboard shortcuts", "hotkeys", "no mouse", "cheat sheet"], path: ["Help", "Keyboard Shortcuts"], reach: .window("shortcuts"),
            steps: [step("Open the list with Help, Keyboard Shortcuts.", "screen.shortcuts", .window("shortcuts")), step("Command K focuses search; Esc clears it; arrows choose and Return opens.", "menu.navigate.search"), step("In the player, Space plays or pauses.", "shortcut.player.space")],
            related: ["guide.keyboard", "screen.shortcuts"], platforms: [.mac], reviewed: true),
        how("recipe.reportProblem", "Report a problem", "Send feedback, and copy a problem report that has logins, addresses and tokens removed.",
            aliases: ["send feedback", "bug report", "diagnostics", "something is broken", "contact support"], path: ["Help", "Send Feedback…"], reach: .window("feedback"),
            steps: [step("Choose Send Feedback… from the menu.", "screen.feedback", .window("feedback")), step("Or ask Setu for a problem report and copy it; nothing secret is in it.")],
            related: ["screen.feedback"], reviewed: true),
        how("recipe.updateApp", "Update the app", "The direct-download Mac app checks for updates; App Store builds update through the App Store.",
            aliases: ["check for updates", "new version", "upgrade", "sparkle"], path: ["StreamSetu", "Check for Updates…"],
            steps: [step("Choose StreamSetu, then Check for Updates….", "menu.app.checkForUpdates"), step("Follow the prompt to install.")],
            related: ["meta.whatsNew"], platforms: [.mac, .dmgOnly], reviewed: true),
    ]

    // MARK: about Setu and what's new

    static let meta: [AtlasEntry] = [
        .make("meta.canDoHere", .meta, "What can I do here?", "Ask me where something is, how to do it, what a setting does, or why something is not working. I answer from what is in the app, so I work with no AI connected.",
              path: ["Setu"], aliases: ["help", "what can you do", "what can setu do", "how do i use setu", "what is this screen", "what can i do on this screen"],
              detail: "Show me points at the control. Open this takes you to the screen. Changing a setting is only offered for ones I may change, and you confirm it first. App lock, proxy and parental controls I explain but never change.",
              related: ["meta.privacySetu", "recipe.searchCommands"], reviewed: true),
        .make("meta.privacySetu", .meta, "What Setu sends and keeps", "Answers from the app's own knowledge stay on this device. Only if you connect an AI does it get the words you type, and never logins, playlist addresses or tokens.",
              path: ["Setu", "Privacy"], aliases: ["is setu private", "does setu send data", "assistant privacy", "ai privacy", "what does the assistant see"],
              detail: "The eye button lets you share the screen name, what is playing and library counts with the AI. Misses are counted on this device only.", related: ["guide.privacyAndSafety", "setting.integrations"], reviewed: true),
        .make("meta.whatsNew", .meta, "What's new", "What's New appears once after an update, when the opening ends. The latest release is Mac 2.17.0 and iPhone and iPad 1.3: a new look and opening, a smarter Home, folder rows, cast, privacy for locked folders. About shows your version.",
              path: ["About", "What's new"], reach: .modal("about"), aliases: ["new features", "release notes", "changelog", "what changed", "latest version", "new in this version"],
              related: ["meta.whatsNew.2026.11.21", "meta.whatsNew.2026.11.07", "meta.whatsNew.2026.11.02"], reviewed: true),
        .make("meta.whatsNew.2026.11.21", .meta, "New in Mac 2.17.0 and iPhone 1.3", "A new icon and opening (Settings has an Opening setting: Automatic or Off), a smarter Home, a Folders view for Movies, Series and Live TV, other languages and versions on a title page, a cast row, and three quick taps on a tab to refresh on iPhone.",
              path: ["About", "What's new"], reach: .modal("about"), aliases: ["2.17", "mac 2.17.0", "ios 1.3", "new opening", "folders view"],
              detail: "Locked and hidden folders stay private in counts, search, recommendations, widgets, cast and similar titles, and nothing from them is sent to TMDB. Don't Recommend This keeps a title out of your recommendations.", since: "2.17.0", reviewed: true),
        .make("meta.whatsNew.2026.11.07", .meta, "New in Mac 2.16.0", "App Lock covers every window, menu command, link and file you open. iCloud sync keeps what is newer. If the saved logins vault cannot be opened, StreamSetu no longer starts an empty one over it.",
              path: ["About", "What's new"], reach: .modal("about"), aliases: ["2.16", "mac 2.16.0", "app lock everything"],
              detail: "Changing channels quickly always ends on the last channel you chose, and a memory leak of about 8 MB per channel is fixed.", since: "2.16.0", reviewed: true),
        .make("meta.whatsNew.2026.11.02", .meta, "New on Fire TV and Android in November", "Smart collections, ranked OpenSubtitles results, Settings search and Essential mode, and Projector mode arrived on Fire TV, Android TV and Android phones. These are not Apple features.",
              path: ["About", "What's new"], aliases: ["fire tv 0.23", "android smart collections", "projector mode"], platforms: [], since: "0.23.0", reviewed: true),
    ]
}
