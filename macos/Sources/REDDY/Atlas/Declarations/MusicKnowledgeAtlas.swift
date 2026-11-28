import Foundation

/// Music pages, the shell and the player surfaces as a person meets them today: no toolbar, a Back pill, a round side-panel button, a sidebar with Library, Playlists and Recent groups, a personal Listen Now,
/// a regional Explore, and a floating player bar. Written from Features/Music (MusicMainView, MusicSidebar, MusicHomePage, MusicExploreView, MusicPlayerBar, MusicContextPanel and friends).
enum AtlasMusicKnowledge {
    private static func m(_ kind: AtlasKind, _ id: String, _ title: String, _ summary: String, _ path: [String], aliases: [String] = [], detail: String? = nil, shortcut: String? = nil,
                          related: [String] = [], reach: AtlasReach = .destination("music")) -> AtlasEntry {
        .make(id, kind, title, summary, path: path, reach: reach, aliases: aliases, detail: detail, platforms: .mac, shortcut: shortcut, related: related, reviewed: true)
    }

    static let all: [AtlasEntry] = shell + pages + player

    // MARK: shell and sidebar

    static let shell: [AtlasEntry] = [
        m(.screen, "screen.music.sidebarLibrary", "Library group in the Music sidebar", "Four shortcuts under LIBRARY: Recently Added (your songs, newest first), Artists, Albums and Songs. There is no Favorite Songs row: songs you liked are the Songs tab of Your Library (heart icon). The group folds with its chevron and remembers that.",
          ["Music", "Sidebar", "Library"], aliases: ["recently added", "my songs", "my albums", "favourites", "liked songs", "favorite songs", "where is favorite songs", "how do i see the songs i liked", "saved songs"], related: ["screen.music.libraryTabs", "control.music.sidebarFold"]),
        m(.screen, "screen.music.sidebarPlaylists", "Playlists group in the Music sidebar", "All Playlists opens the Playlists tab of Your Library and each of your playlists is listed below it. Right-click a playlist for Play, Shuffle, Rename and Delete Playlist. Drop songs on a playlist row to add them. The group folds with its chevron.",
          ["Music", "Sidebar", "Playlists"], aliases: ["my playlists", "all playlists", "rename playlist", "delete playlist", "drop a song on a playlist"], related: ["control.music.sidebarFold"]),
        m(.control, "control.music.sidebarFold", "Fold a sidebar group", "The chevron on LIBRARY, PLAYLISTS and RECENT folds or opens that group. The choice is remembered.", ["Music", "Sidebar"], aliases: ["collapse library group", "hide recent", "fold playlists"]),
        m(.control, "control.music.sidebarOpenLink", "Open a Link (sidebar)", "The last row under More. Paste a song, album, artist or playlist link and Music opens its page; it never starts playing by itself.", ["Music", "Sidebar", "More", "Open a Link"],
          aliases: ["paste a link", "open spotify link", "open song link", "open youtube music link", "open a link in music"], related: ["control.music.openLink"]),
        m(.control, "control.music.backPill", "Back pill and history", "Music has no toolbar. A page opened from another page (an artist, album, playlist or film) shows a Back pill at its top. Command [ goes back from anywhere and Command ] goes forward; there is no Forward button. Your place on the page and its filters are kept.",
          ["Music", "Page top"], aliases: ["go back", "back button", "forward", "cmd [", "why is there no back button in music", "where did the toolbar go", "music toolbar missing", "how do i go back to the previous page in music"], shortcut: "⌘[", related: ["shortcut.music.forward"]),
        m(.control, "control.music.sidePanelButton", "Side panel button", "A round glass button at the top right of the page, shown while a song is loaded. It opens or closes the side panel (Now Playing, Queue, Lyrics, Related, Credits). The same as View, Show or Hide Details Panel. Without a loaded song the button is not there.",
          ["Music", "Page top right"], aliases: ["show panel", "queue panel", "lyrics panel", "details panel button", "side panel button disappeared", "details panel not showing", "where is the button to open the queue panel"], shortcut: "⌃⌘I", related: ["screen.music.sidePanel", "diag.music.panelButtonMissing"]),
        m(.screen, "screen.music.sidePanel", "Music side panel tabs", "Five tabs: Now Playing (cover, title links, a short lyrics preview), Queue (reorder, remove, clear, autoplay, undo with Command Z), Lyrics, Related (artist and album) and Credits (singers, composer, film). It opens beside the page from 1400 points wide and over it below that; Escape or the close button closes it. Each Music section remembers its last tab.",
          ["Music", "Side panel"], aliases: ["queue", "up next", "lyrics tab", "credits", "related", "now playing panel", "context panel"], shortcut: "⌃⌘I", related: ["control.music.sidePanelButton", "control.music.contextTab"]),
    ]

    // MARK: pages

    static let pages: [AtlasEntry] = [
        m(.screen, "screen.music.listenNowPersonal", "Listen Now, your personal page", "Listen Now is built from what you play and like: quick actions (Play recent, Shuffle liked, Start radio, Open Library), Continue listening, one hero card, a shelf for the time of day, New from artists you follow (last four weeks), On repeat, connected shelves, Rediscover (saved songs you have not heard for a while), your languages, From the songs you liked and Your top tracks. A brand-new listener (no plays, no likes) sees a welcome card instead; charts, country lists and languages live in Explore.",
          ["Music", "Listen Now"], aliases: ["continue listening", "on repeat", "rediscover", "made for you", "my music home", "what is on repeat", "listen now empty", "listen now lo naa songs kanipinchatledu", "why no country picker in listen now"],
          detail: "There is no country picker on Listen Now; the country is chosen on Explore and Radio.", related: ["screen.music.exploreRegion", "behaviour.music.countryRules"]),
        m(.screen, "screen.music.exploreRegion", "Explore", "The region page: a country picker at the top right (only when a regional source is on), up to three feature cards with Play and Open, the Top chart in your country (or Top worldwide) as a grid of up to 12 ranked songs with a Shuffle button, worldwide shelves, New releases, Languages tiles, Moods and moments, and Genres. Shelves with fewer than three items are left out.",
          ["Music", "Explore"], aliases: ["charts", "top songs", "top 50", "trending", "new releases", "genres", "moods", "languages", "country charts", "regional music", "explore music"],
          detail: "If your country has no chart it says No charts for that country yet and offers Show worldwide. If loading fails it offers Try again.", related: ["behaviour.music.countryRules", "control.music.exploreShuffleChart", "diag.music.noChartsForCountry"]),
        m(.control, "control.music.exploreShuffleChart", "Shuffle the chart", "Next to the chart title on Explore (needs six or more songs): plays the whole chart of the chosen country in a new order each time.", ["Music", "Explore", "Chart"],
          aliases: ["shuffle top charts", "shuffle trending", "how do i shuffle the top chart", "shuffle the charts"], related: ["screen.music.exploreRegion"]),
        m(.control, "control.music.exploreFeatureCards", "Explore feature cards", "Up to three cards at the top of Explore (playlists first, then albums and artists), each with Play and Open.", ["Music", "Explore"], aliases: ["featured", "new release card", "explore hero"]),
        m(.control, "control.music.exploreLanguageTile", "Language tile on Explore", "A language tile that has its own song lists sets that language on Listen Now and takes you there. Other tiles search for the language instead.", ["Music", "Explore", "Languages"],
          aliases: ["hindi songs", "tamil songs", "telugu songs", "language filter", "gaano kaise language badlu music mein", "bhasha kaise add karu", "tamil songs ela play cheyali", "add a language in music"], related: ["screen.music.listenNowPersonal"]),
        m(.meta, "behaviour.music.countryRules", "How the country choice works", "The country picker is a globe pill with a searchable list: Worldwide, Your region (from the system), your last three countries, then A to Z; type to match the start of a name, a word or a code. It shows only when a source with country charts is on. The choice is shared by Explore, Radio and the assistant and is remembered.",
          ["Music", "Explore", "Country"], aliases: ["change country", "region", "country charts", "worldwide", "how do i change country for charts", "country picker"], related: ["screen.music.exploreRegion", "control.music.radioRegion"]),
        m(.control, "control.music.searchScope", "Where to search", "Under the Music search field: Everything, Your library or Local files.", ["Music", "Search"], aliases: ["search my library only", "search local files", "search scope"]),
        m(.control, "control.music.searchTypeChips", "Search result types", "Chips above the results: All, Songs, Albums, Artists, Playlists and, with the music graph, People, Films and Soundtracks.", ["Music", "Search"], aliases: ["filter songs only", "albums only", "result types"]),
        m(.control, "control.music.searchRecent", "Recent searches", "Under the search field: remove one recent search with its cross, or clear them all.", ["Music", "Search"], aliases: ["clear search history", "recent music searches", "delete recent searches"]),
        m(.screen, "screen.music.libraryTabs", "Library tabs", "Songs (the ones you liked), Albums, Artists (the ones you follow), Playlists, Podcasts (only once you have saved episodes), History and Local files (only when a local folder is switched on). A narrow window shows the tabs as a menu. Made for you smart playlists (On Repeat, Recently added, Never played, Forgotten favourites) can be hidden or saved as playlists.",
          ["Music", "Your Library"], aliases: ["liked songs", "favourites", "saved albums", "followed artists", "history", "local files", "podcasts tab missing", "cant see podcasts tab in library", "where are my local files"], related: ["screen.music.sidebarLibrary"]),
        m(.control, "control.music.libraryRecentlyAdded", "Recently Added", "Sidebar shortcut: Your Library, Songs, sorted newest first.", ["Music", "Sidebar", "Library"], aliases: ["newest songs", "just added", "recently added songs"]),
        m(.screen, "screen.music.miniPlayerWindow", "Mini player", "More player actions, Mini player opens a small window with Previous, Play or Pause, Next, Shuffle, Repeat, Dislike, Queue or lyrics, smaller and larger, Theatre mode and Back to the app.", ["Music", "Player bar", "Mini player"],
          aliases: ["floating player", "pip", "small player", "where is the mini player", "mini music player"], related: ["control.music.playerBarMore"]),
        m(.screen, "screen.music.theatre", "Theatre mode", "A large, quiet view of the playing song. Lyrics and queue columns need a wide window, and an optional clock is set in Settings, Playback, Theatre mode. Press F, or More player actions, Theatre mode; Escape closes it.",
          ["Music", "Player"], aliases: ["cinema mode", "big lyrics", "full screen music", "f key", "theatre"], shortcut: "F", related: ["setting.music.theatre"]),
        m(.control, "control.music.menuBarItem", "Music menu bar item", "An optional icon in the Mac menu bar (a waveform while playing). Click it for a small player with cover, progress, transport, like and volume; right-click or Control-click for a plain menu. Turn it on in Settings, Playback, Player, Windows, Menu bar item.",
          ["Music", "Settings", "Playback"], aliases: ["status bar player", "menubar music", "music in the menu bar", "menu bar icon"], related: ["setting.music.menuBarItem"]),
        m(.meta, "behaviour.music.notifications", "Song-change notifications", "Settings, Playback, Player, Windows: Notify when the song changes (only while the app is in the background) and Also when StreamSetu is open (only for songs that started on their own).", ["Music", "Settings", "Playback"],
          aliases: ["notification when song changes", "song notifications", "stop music notifications"], related: ["setting.music.trackNotifications"]),
        m(.screen, "screen.music.shortcutsList", "Music keyboard shortcuts list", "Command / in Music opens the list of Music keys; Done closes it.", ["Music"], aliases: ["cmd slash", "keys list", "keyboard shortcuts for music", "shortcuts list"], shortcut: "⌘/"),
    ]

    // MARK: the player bar

    static let player: [AtlasEntry] = [
        m(.control, "control.music.playerBarPill", "Floating player bar", "A compact glass pill at the bottom, up to 720 points wide and centred. Left: Shuffle, Previous, Play or Pause, Next, Repeat. Middle: the cover (opens Now Playing), title, artist (opens the artist), a heart to like or unlike, and the progress line. Right: Queue, Lyrics, Comments, volume (the mouse wheel changes it), Tempo, pitch and reverb, the audio quality chip, output device, sleep timer and a More menu. As the window narrows the right-hand buttons fold into More.",
          ["Music", "Player bar"], aliases: ["mini bar", "now playing bar", "player controls", "music player bar", "where are the player controls"], detail: "Use Full Player Bar in the More menu switches to the full-width strip, and Use Compact Player Bar goes back.", related: ["control.music.playerBarMore", "control.music.playerHideShow"]),
        m(.control, "control.music.playerBarMore", "More player actions", "The three dots in the player bar: Choose Another Audio Source, Open Full Window, Theatre mode, Mini player, Use Full or Compact Player Bar, Hide player, Stop playback, Volume Up and Down, and whatever buttons no longer fit the bar.", ["Music", "Player bar"],
          aliases: ["three dots", "hide player", "stop playback", "player more menu"], related: ["control.music.playerBarPill", "control.music.playerHideShow"]),
        m(.control, "control.music.playerHideShow", "Hide or show the player bar", "Hide player in the More menu removes the bar. A Now playing card then appears at the bottom of the sidebar while a song is loaded; click it to open Now Playing and bring the player back.", ["Music", "Player bar"],
          aliases: ["bring back player", "hide the player bar", "player bar gone", "show player again", "where did the player go"], related: ["diag.music.playerBarGone"]),
        m(.control, "control.music.sleepTimerMusic", "Music sleep timer", "The moon button in the player bar (or in the More menu): 15, 30, 45, 60 or 90 minutes, or End of this track. The volume fades out at the end, and Cancel Sleep Timer stops it. This is separate from the Playback menu's Sleep Timer, which is for movies and live TV.",
          ["Music", "Player bar", "Sleep timer"], aliases: ["stop music after", "fall asleep to music", "timer", "how do i set a sleep timer for music", "sleap timer", "slep timar music", "music sleep timer"], related: ["recipe.music.setSleepTimer", "recipe.sleepTimer"]),
        m(.control, "control.music.effectsPopover", "Tempo, pitch and reverb", "The sliders button in the player bar: tempo, pitch and reverb, presets you can save and delete, Reset all effects, and a page for the Equalizer.", ["Music", "Player bar", "Effects"],
          aliases: ["speed up song", "slow down", "nightcore", "pitch", "reverb", "equalizer", "how to open the equalizer", "equalizer kahan hai", "change song speed"], related: ["setting.music.equalizer", "recipe.music.useEqualizer"]),
        m(.control, "control.music.audioQualityChip", "Audio quality chip", "A small chip in the player bar that reports the stream's codec, bitrate and sample rate. It only reports; the quality you ask for is set in Settings, Playback, Audio.", ["Music", "Player bar"],
          aliases: ["bitrate", "codec", "lossless indicator", "what quality is this song"], related: ["setting.music.audioQuality"]),
    ]
}
