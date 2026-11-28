import Foundation

/// How-tos and fixes for Music, in the words people use: how to sign in, set a sleep timer, change the country, add a language, download, listen together, pair a device, and why lyrics, charts, devices or the side panel are missing.
/// Written from the Music pages and settings (see AtlasMusicKnowledge and AtlasMusicSettings for the controls themselves).
enum AtlasMusicHelp {
    private static func step(_ say: String) -> AtlasStep { AtlasStep(say: say, anchor: nil, reach: nil) }

    private static func how(_ id: String, _ title: String, _ summary: String, _ steps: [String], _ path: [String], aliases: [String] = [], related: [String] = []) -> AtlasEntry {
        .make("recipe.music." + id, .recipe, title, summary, path: ["Music"] + path, reach: .destination("music"), aliases: aliases, platforms: .mac, related: related, recipe: steps.map(step), reviewed: true)
    }

    private static func fix(_ id: String, _ title: String, _ summary: String, _ path: [String], aliases: [String] = [], detail: String? = nil, related: [String] = []) -> AtlasEntry {
        .make("diag.music." + id, .diagnosis, title, summary, path: ["Music"] + path, reach: .destination("music"), aliases: aliases, detail: detail, platforms: .mac, related: related, reviewed: true)
    }

    static let all: [AtlasEntry] = recipes + diagnoses

    static let recipes: [AtlasEntry] = [
        how("signInYouTubeMusic", "Sign in to YouTube Music", "Open the account menu at the very bottom of the Music sidebar and choose Sign in with Google. A window opens for the Google sign-in; your session is kept in the Keychain.",
            ["Open Music (command 8).", "At the bottom of the sidebar open the account menu and choose Sign in with Google.", "Finish the sign-in in the window that opens. Add plays to my YouTube history is off by default; Where new things go (Settings, Plugins & Sources, YouTube Music) chooses whether likes and new playlists live on this device or in your YouTube account."],
            ["Settings", "Plugins & Sources", "YouTube Music"], aliases: ["how to sign in to youtube music", "log in to youtube music", "connect my google account to music", "youtube music account"], related: ["setting.music.youtubeMusicAccount"]),
        how("setSleepTimer", "Set a sleep timer for Music", "Use the moon button in the player bar: 15, 30, 45, 60 or 90 minutes, or End of this track. The volume fades out, and Cancel Sleep Timer stops it.",
            ["Start a song so the player bar shows.", "Press the moon button (or open More player actions).", "Pick a time, or End of this track."], ["Player bar", "Sleep timer"], aliases: ["music sleep timer how", "stop the music after an hour"], related: ["control.music.sleepTimerMusic"]),
        how("changeCountry", "Change the country for charts", "Open Explore and use the country picker at the top right. It is also on Radio. Choose Worldwide, Your region, a recent country or search the list. Listen Now has no country picker.",
            ["Open Explore in the Music sidebar.", "Click the globe pill at the top right.", "Pick a country or type to search it. The choice is remembered and shared with Radio."], ["Explore"], aliases: ["how do i change country for charts", "music region", "show charts for another country"], related: ["behaviour.music.countryRules"]),
        how("addLanguage", "Add a language to Music", "On Explore, open the Languages tiles and choose a language: a tile with its own song lists sets that language on Listen Now and takes you there.",
            ["Open Explore.", "Scroll to Languages and click the language you want.", "That language's songs open from the tile; Listen Now itself follows only what you play."], ["Explore", "Languages"], aliases: ["hindi songs in music", "how to add tamil", "bhasha kaise add karu", "language chips"], related: ["control.music.exploreLanguageTile"]),
        how("importPlaylist", "Import a playlist", "In Your Library open the More menu (three dots) and choose Import playlists, then follow the steps for the service you import from. Imported playlists appear under Playlists.",
            ["Open Your Library.", "Open the More menu and choose Import playlists.", "Follow the steps for the service."], ["Your Library"], aliases: ["import a spotify playlist", "bring my playlists", "move playlists to streamsetu music"], related: ["control.music.libraryMore"]),
        how("downloadSongs", "Download songs to play offline", "Use Download in a song's menu, or Download these songs on a Library list of 100 songs or fewer. Open Downloads in the sidebar to play them offline, and retry or remove them there.",
            ["Right-click a song and choose Download, or open a Library list and use its more menu, Download these songs.", "Open Downloads in the sidebar (More group).", "Choose Play offline."], ["Downloads"], aliases: ["how do i download songs for offline", "where are my downloads", "save songs offline"], related: ["screen.music.downloads", "control.music.libraryDownload"]),
        how("startListenTogether", "Start a Listen Together room", "Open Listen Together in the sidebar and choose Start a room on this device. It shows a room code; friends use Look for rooms or Join with code. You choose Let in or Refuse for each request, and End room stops it.",
            ["Open Listen Together (More group).", "Choose Start a room on this device and share the room code.", "Let in or refuse requests; guests can Suggest a song. End room when you are done."], ["Listen Together"],
            aliases: ["how to start listen together", "party mode", "share music with friends", "listening room"], related: ["screen.music.room", "shortcut.music.roomLock"]),
        how("pairDevice", "Pair another device to control Music", "Open Devices, turn on Allow other devices to control this one and choose Show pairing code. On the other device choose Look for my devices and Pair with code.",
            ["Open Devices (More group).", "Turn on Allow other devices to control this one and press Show pairing code.", "On the other device use Look for my devices, then Pair with code."], ["Devices"], aliases: ["how to control music from my phone", "pair my phone", "remote control for music"], related: ["setting.music.devicesAllowControl", "diag.music.devicesNotFound", "diag.music.pairingLocked"]),
        how("connectLastFm", "Connect Last.fm or ListenBrainz", "Open Music Settings, Plugins & Sources, Scrobbling and connect the service. Scrobbling is off until you do.",
            ["Open the sidebar's More group and choose Settings.", "Go to the Plugins & Sources tab, Scrobbling.", "Choose Connect Last.fm or Connect ListenBrainz and sign in, then switch on Scrobble plays."], ["Settings", "Plugins & Sources", "Scrobbling"],
            aliases: ["how do i connect lastfm", "scrobbling kaise on kare", "send plays to last.fm"], related: ["setting.music.scrobbling"]),
        how("turnOnCrossfade", "Turn on crossfade", "Open Music Settings, Playback, Player and switch on Crossfade, then set its length from 1 to 10 seconds. It is off in listening rooms.",
            ["Open Settings from the sidebar's More group.", "Go to Playback, Player.", "Switch on Crossfade and set its length."], ["Settings", "Playback", "Player"], aliases: ["how do i turn on crossfade", "crosfade", "fade songs together"], related: ["setting.music.crossfade"]),
        how("useEqualizer", "Use the equalizer", "Press the sliders button in the player bar, then open Equalizer. Choose a preset, move the seven bands or drag the bass and treble pad.",
            ["Play a song and press the sliders (Tempo, pitch and reverb) button in the player bar.", "Open Equalizer.", "Choose one of sixteen presets, drag the pad or move the bands."], ["Player bar", "Equalizer"], aliases: ["how to open the equalizer", "equalizer kahan hai", "bass boost how"], related: ["setting.music.equalizer", "control.music.effectsPopover"]),
        how("findFavouriteSongs", "Find the songs I liked", "There is no Favorite Songs row. Your liked songs are in Your Library on the Songs tab (heart icon); the sidebar's Library group has a Songs shortcut to it.",
            ["Open Your Library, or the Songs row under LIBRARY in the sidebar.", "The Songs tab lists everything you liked."], ["Your Library", "Songs"], aliases: ["where is favorite songs", "how do i see the songs i liked", "my liked songs"], related: ["screen.music.sidebarLibrary"]),
        how("blockSong", "Never play a song or artist", "Right-click a song and choose Never Play This Track (an artist's menu has Never Play and their name). The Never Play List, opened from Settings, Playback, Audio or from Your Library's More menu, shows what you blocked and lets you allow it again.",
            ["Right-click the song and choose Never Play This Track.", "To undo it, open the Never Play List and choose Allow This Track Again."], ["Never Play list"], aliases: ["how do i block a song", "never play this", "song kabhi mat bajao", "hide an artist"], related: ["screen.music.blacklist"]),
    ]

    static let diagnoses: [AtlasEntry] = [
        fix("noLyrics", "No lyrics are showing", "Music asks the lyrics sources in the order set in Settings, Lyrics, Lyrics sources, with files next to local songs first. If every one misses you see no lyrics. Use Search again on the Lyrics tab, check that some sources are switched on, or change the order. Time-synced lyrics only appear when a source has them.",
            ["Side panel", "Lyrics"], aliases: ["lyrics not showing", "why cant i see lyrics", "no lyrics for this song", "lyrics missing"], related: ["setting.music.lyricsSources", "control.music.lyricsSearchAgain"]),
        fix("songWontPlay", "A song will not play", "Press Retry in the player bar, or choose Choose Another Audio Source in the More menu to pick a different copy of the song. If it keeps failing, Settings, Privacy & About, Playback problems shows why a song did not start and can copy playback diagnostics.",
            ["Player bar"], aliases: ["song wont play", "music wont play", "playback failed music", "retry song", "song skips immediately", "audio source failed"], related: ["control.music.playerBarMore", "setting.music.deleteAllData"]),
        fix("noChartsForCountry", "No charts for my country", "Explore says No charts for that country yet when no source has a chart for it. Choose Show worldwide, or pick another country; the picker shows only while a source with country charts is switched on.",
            ["Explore"], aliases: ["why is there no charts for my country", "no top songs for my country", "charts empty"], related: ["behaviour.music.countryRules", "recipe.music.changeCountry"]),
        fix("noSourceOn", "No music source is switched on", "Listen Now says No music source is switched on when every source is off. Press Open Settings, go to Plugins & Sources and switch on at least one source, or add a local folder or your own music server.",
            ["Listen Now"], aliases: ["music is empty", "nothing in listen now", "no music sources", "music has no songs"], related: ["screen.music.listenNowPersonal", "setting.music.localFolders"]),
        fix("devicesNotFound", "Devices cannot be found", "Both devices must be on the same Wi-Fi, and the one you want to control must have Allow other devices to control this one switched on. Then use Look for my devices again.",
            ["Devices"], aliases: ["cant find devices", "devices nahi mil rahe", "my phone does not show up", "look for my devices finds nothing"], related: ["recipe.music.pairDevice"]),
        fix("pairingLocked", "Pairing is locked", "After too many wrong pairing codes a device is locked out for a while. Wait, then use Show pairing code again for a new code and enter it carefully.",
            ["Devices"], aliases: ["pairing locked", "too many wrong codes", "cant pair device", "pairing code not accepted"], related: ["recipe.music.pairDevice"]),
        fix("playerBarGone", "The player bar is gone", "You or a click used Hide player in the More menu. While a song is loaded, a Now playing card at the bottom of the sidebar brings it back when you click it. Use Stop playback only when you want the music to end.",
            ["Player bar"], aliases: ["player bar disappeared", "where did the player go", "bring back the player", "music controls missing"], related: ["control.music.playerHideShow"]),
        fix("sidebarNamesMissing", "The sidebar shows only icons", "Under 1000 points wide the Music sidebar shows icons only. Make the window wider and the names return. The collapse button in the sidebar header (Control Command S) is disabled below that width.",
            ["Sidebar"], aliases: ["window too narrow sidebar names gone", "sidebar icons only", "sidebar labels missing", "sidebar collapsed"], related: ["control.music.sidebarToggle"]),
        fix("panelButtonMissing", "The side panel button is missing", "The round side-panel button at the top right of the page appears only while a song is loaded. Start a song and it returns. View, Show or Hide Details Panel (Control Command I) does the same.",
            ["Page top right"], aliases: ["side panel button disappeared", "details panel not showing", "queue button missing", "where is the queue panel"], related: ["control.music.sidePanelButton"]),
    ]
}
