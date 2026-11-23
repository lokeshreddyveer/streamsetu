import Foundation

/// The Mac menu bar, one entry per item of `MenuCommands` (Application/MenuCommands.swift). While the app is locked, every item except the system's own does nothing.
enum AtlasMenus {
    private static func item(_ id: String, _ title: String, _ menu: String, _ summary: String, reach: AtlasReach = .none, aliases: [String] = [], detail: String? = nil, shortcut: String? = nil,
                             related: [String] = [], safety: AtlasSafety = .read, platforms: AtlasPlatforms = .mac) -> AtlasEntry {
        .make("menu.\(id)", .menuItem, title, summary, path: ["Menu bar", menu, title], reach: reach, aliases: aliases, detail: detail, platforms: platforms, shortcut: shortcut, related: related, safety: safety, reviewed: true)
    }

    static let all: [AtlasEntry] = [
        item("app.checkForUpdates", "Check for Updates…", "StreamSetu", "Asks the update service whether a newer version of the app is out.", aliases: ["update", "new version", "upgrade the app", "software update", "sparkle"],
             detail: "The item is greyed out when this copy of the app has no update address, which is the case in the App Store version. The App Store updates the app there.", platforms: [.mac, .dmgOnly]),

        item("file.addPlaylist", "Add Playlist…", "File", "Opens the Add Playlist form, where you choose a type and enter the address or login of a source.", reach: .modal("addPlaylist"),
             aliases: ["new playlist", "add source", "add provider", "add m3u", "add xtream", "new source"], shortcut: "⌘N", related: ["guide.addingAPlaylistOrSource", "guide.addingXtream", "guide.addingAnM3uLink"]),
        item("file.openVideoFile", "Open Video File…", "File", "Lets you pick a video file on this Mac and plays it in the player. Subtitle files that sit next to it are picked up.",
             aliases: ["play a file", "open file", "local video", "play mkv", "play mp4", "play from disk", "open movie file"], shortcut: "⌘O", related: ["menu.file.filesAndServers"], platforms: .all),
        item("file.filesAndServers", "Files and Servers…", "File", "Opens the Files window, where you browse folders on this Mac and servers you have added, and play from them.", reach: .window("files"),
             aliases: ["files window", "browse files", "webdav", "network server", "on your device", "local files", "podcasts"], related: ["menu.file.openVideoFile"]),
        item("file.refreshAll", "Refresh All Playlists", "File", "Reloads every playlist that is switched on: channels, movies, series and their guides.", aliases: ["update playlists", "reload playlists", "sync playlists", "refresh sources", "reload channels", "update channel list"],
             detail: "It does not shuffle the recommendations; Shuffle Recommendations is a separate command.", shortcut: "⌘R", related: ["menu.navigate.shuffle", "setting.catalogRefresh", "setting.refreshOnOpen"]),

        item("help.sendFeedback", "Send Feedback…", "Help", "Opens the feedback window so you can write to the developer.", reach: .window("feedback"), aliases: ["report a bug", "contact", "support", "bug report", "suggest a feature"], related: ["screen.feedback"]),
        item("help.askSetu", "Ask Setu", "Help", "Opens Setu, the assistant, so you can ask how something works or where a setting is.", reach: .searchCommand("askSetu"), aliases: ["open setu", "open assistant", "help me", "ask for help", "talk to setu", "assistant shortcut"], shortcut: "⌥⌘/"),
        item("help.keyboardShortcuts", "Keyboard Shortcuts", "Help", "Opens a window that lists the keyboard shortcuts.", reach: .window("shortcuts"), aliases: ["hotkeys", "keys list", "shortcut list", "cheat sheet"], shortcut: "⌘/"),

        item("navigate.home", "Home", "Navigate", "Goes to the Home tab.", reach: .tab("Home"), aliases: ["go home", "first tab"], shortcut: "⌘1", related: ["screen.tab.home"]),
        item("navigate.liveTV", "Live TV", "Navigate", "Goes to the Live TV tab.", reach: .tab("Live TV"), aliases: ["channels tab", "go to live tv"], shortcut: "⌘2", related: ["screen.tab.liveTV"]),
        item("navigate.movies", "Movies", "Navigate", "Goes to the Movies tab.", reach: .tab("Movies"), aliases: ["films tab", "go to movies"], shortcut: "⌘3", related: ["screen.tab.movies"]),
        item("navigate.series", "Series", "Navigate", "Goes to the Series tab.", reach: .tab("Series"), aliases: ["shows tab", "tv shows", "go to series"], shortcut: "⌘4", related: ["screen.tab.series"]),
        item("navigate.tvGuide", "TV Guide", "Navigate", "Goes to the TV Guide tab.", reach: .tab("TV Guide"), aliases: ["epg tab", "programme guide", "guide tab"], shortcut: "⌘5", related: ["screen.tab.guide"]),
        item("navigate.search", "Search", "Navigate", "Moves the cursor to the search box at the top. Type a title, a person or a command such as “open movies”. While Netflix is open the box reads Search your library; typing in it goes back to StreamSetu and shows the results.", reach: .searchCommand("focus"),
             aliases: ["command k", "find anything", "palette", "search everything", "global search", "top search", "cmd k", "command palette"], shortcut: "⌘K", related: ["guide.search", "menu.navigate.searchThisScreen"]),
        item("navigate.searchThisScreen", "Search in This Screen", "Navigate", "Moves the cursor to the search box of the screen you are on, so you filter only what that screen shows. It does nothing while Netflix is open.", reach: .searchCommand("focusScreen"),
             aliases: ["filter this screen", "find in page", "search this page", "local search", "filter list"], shortcut: "⌘F", related: ["menu.navigate.search"]),
        item("navigate.shuffle", "Shuffle Recommendations", "Navigate", "Picks a new set of recommendations on Home. It does not refresh your playlists.", aliases: ["reshuffle", "new recommendations", "mix again", "shuffle home", "different suggestions"],
             shortcut: "⇧⌘R", related: ["menu.file.refreshAll", "screen.shortcut.discover"]),

        item("navigate.services", "Services", "Navigate", "Opens the Services list in the top row, where every streaming service can be opened, pinned or unpinned. It does not open a particular service and there are no per-service shortcuts. It does not exist on iPhone or iPad.", aliases: ["open services", "streaming services", "go to netflix", "open netflix"], shortcut: "⌘6", related: ["control.services.menu", "menu.navigate.streamsetu"]),
        item("navigate.streamsetu", "StreamSetu", "Navigate", "Goes back from a streaming service to the StreamSetu screen you were on (Home, Live TV, Movies, Series or TV Guide).", aliases: ["back to streamsetu", "leave service", "close service", "leave netflix"], shortcut: "⌘0", related: ["control.nav.streamsetu"]),
        item("services.back", "Back", "Services", "Goes back one page in the service that is open. It is off when no service is open.", shortcut: "⌘←", related: ["control.services.menu"]),
        item("services.forward", "Forward", "Services", "Goes forward one page in the service that is open.", shortcut: "⌘→", related: ["control.services.menu"]),
        item("services.reload", "Reload", "Services", "Loads the current page of the open service again.", shortcut: "⌘R", related: ["control.services.menu"]),
        item("services.zoomIn", "Zoom In", "Services", "Makes the open service's page a little larger, in 5% steps up to 150%. The size is kept for next time, separately for each service. A service's own full-screen player is not affected.", shortcut: "⌘=", related: ["control.services.menu"]),
        item("services.zoomOut", "Zoom Out", "Services", "Makes the open service's page a little smaller, in 5% steps down to 60%.", shortcut: "⌘-", related: ["control.services.menu"]),
        item("services.actualSize", "Actual Size", "Services", "Returns the open service's page to its standard size.", shortcut: "⌥⌘0", related: ["control.services.menu"]),
        item("services.openInBrowser", "Open in Default Browser", "Services", "Opens the page you are on in your default browser. It works for Netflix only and is greyed out for the other services, which never open pages outside StreamSetu. Use it when Netflix does not play inside StreamSetu.", shortcut: "⇧⌥⌘O", related: ["control.services.menu"]),
        item("services.pin", "Pin to Top Bar", "Services", "Pins the open service to the top bar, or unpins it when it is already pinned. Pinning only changes the top bar: it never signs you out or clears anything.", related: ["control.services.pin"]),
        item("services.clearData", "Clear Data…", "Services", "After a confirmation, signs you out of the open service in StreamSetu and removes the cookies and saved site data of that service only. Playlists, settings and the other services are not touched.", related: ["control.services.menu"], safety: .confirm),

        item("playback.openMultiView", "Open Multi-View", "Playback", "Opens the Multi-View window, which plays up to four channels at once. One tile has the sound.", reach: .window("multiview"),
             aliases: ["multiview", "split screen", "watch several channels", "four channels", "multi screen", "picture in grid"], shortcut: "⇧⌘M", related: ["screen.multiview"]),
        item("playback.openPlayerWindow", "Open Player in New Window", "Playback", "Moves the player into a window of its own. Greyed out when nothing is playing.", reach: .window("player"),
             aliases: ["detach player", "float player", "separate player window", "pop out player"], shortcut: "⇧⌘P"),
        item("playback.playPause", "Play / Pause", "Playback", "Pauses what is playing, or resumes it. Greyed out when nothing is playing.", aliases: ["pause", "resume", "play"], related: ["shortcut.player.space"]),
        item("playback.nextChannel", "Next Channel", "Playback", "Plays the next channel in the list you are watching from. Only for live TV.", aliases: ["channel up", "channel down", "next station", "zap forward", "change channel"], shortcut: "⌘]", related: ["menu.playback.previousChannel", "gesture.ios.playerZap"]),
        item("playback.previousChannel", "Previous Channel", "Playback", "Plays the previous channel in the list you are watching from. Only for live TV.", aliases: ["channel back", "previous station", "zap back"], shortcut: "⌘[", related: ["menu.playback.nextChannel"]),
        item("playback.lastChannel", "Last Channel", "Playback", "Goes back to the channel you were watching before this one. Only for live TV.", aliases: ["previous channel i watched", "go back to last channel", "flip back", "recall"], shortcut: "⌘L", related: ["menu.playback.previousChannel"]),
        item("playback.skipForward", "Skip Forward 10 Seconds", "Playback", "Jumps ten seconds ahead in what is playing.", aliases: ["fast forward", "forward 10", "skip ahead", "jump forward"], shortcut: "⌘→", related: ["menu.playback.skipBack"]),
        item("playback.skipBack", "Skip Back 10 Seconds", "Playback", "Jumps ten seconds back in what is playing.", aliases: ["rewind", "back 10", "replay", "go back 10 seconds"], shortcut: "⌘←", related: ["menu.playback.skipForward"]),
        item("playback.nextEpisode", "Next Episode", "Playback", "Plays the next episode of the series you are watching. Greyed out when there is no next episode.", aliases: ["skip episode", "following episode", "next show"], shortcut: "⌘E", related: ["setting.autoPlayNextEpisode"]),
        item("playback.sleepTimer", "Sleep Timer", "Playback", "A submenu that stops playback after 15, 30, 45, 60, 90 or 120 minutes, or at the end of this episode or movie. Greyed out when nothing is playing.",
             aliases: ["stop after", "fall asleep", "timer", "turn off tv later", "auto stop", "sleep"], related: ["menu.playback.sleepTimerEndOfItem", "menu.playback.sleepTimerCancel", "intent.sleepTimer"]),
        item("playback.sleepTimerEndOfItem", "Stop at the End of This Episode or Movie", "Playback", "Inside Sleep Timer: stops when the current episode or movie ends. Not offered for live TV.", aliases: ["stop after this episode", "stop at end"], related: ["menu.playback.sleepTimer"]),
        item("playback.sleepTimerCancel", "Cancel Sleep Timer", "Playback", "Inside Sleep Timer: switches the running timer off. It only appears while a timer is running.", aliases: ["stop the timer", "remove sleep timer"], related: ["menu.playback.sleepTimer"]),
        item("playback.stop", "Stop", "Playback", "Stops playback and closes the player.", aliases: ["stop playing", "close player", "end playback"], shortcut: "⌘.", related: ["intent.stopPlayback"]),
    ]
}
