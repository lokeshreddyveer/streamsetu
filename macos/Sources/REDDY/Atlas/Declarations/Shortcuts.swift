import Foundation

/// Keyboard shortcuts as plain data. The Keyboard Shortcuts window draws `groups`; Setu indexes `all`. Keys that are also a menu item are described by the menu entry (AtlasMenus) and not repeated here.
enum AtlasShortcuts {
    struct Row: Sendable, Hashable { let keys: String; let what: String }
    struct Group: Sendable, Hashable { let title: String; let rows: [Row] }

    static let groups: [Group] = [
        Group(title: "Moving around", rows: [
            Row(keys: "⌘1 – ⌘5", what: "Home, Live TV, Movies, Series, TV Guide"),
            Row(keys: "⌘6", what: "Services list (Mac only); ⌘0 goes back to StreamSetu"),
            Row(keys: "⌘7", what: "Podcasts (Mac only)"),
            Row(keys: "⌘K", what: "Search everything"),
            Row(keys: "⌘F", what: "Search within this screen"),
            Row(keys: "⌘N", what: "Add a playlist"),
            Row(keys: "⌘O", what: "Open a video file"),
            Row(keys: "⌘R", what: "Refresh all playlists"),
            Row(keys: "⇧⌘R", what: "Shuffle recommendations (does not refresh)"),
            Row(keys: "⌘/", what: "Show this list of keyboard shortcuts"),
            Row(keys: "⌥⌘/", what: "Ask Setu"),
            Row(keys: "Esc", what: "Close the top-most thing: search, a panel, a detail page, then the player"),
            Row(keys: "Tab / ⇧Tab", what: "Move between buttons and cards (turn on Keyboard navigation in System Settings > Keyboard)"),
            Row(keys: "Return", what: "Open or play what is highlighted"),
            Row(keys: "← →", what: "In the TV Guide: move the time window by 30 minutes"),
        ]),
        Group(title: "Playing", rows: [
            Row(keys: "Space", what: "Play or pause"),
            Row(keys: "F", what: "Full screen on or off"),
            Row(keys: "M", what: "Mute"),
            Row(keys: "← →", what: "Back or forward 10 seconds (full screen, movies and episodes)"),
            Row(keys: "J  L", what: "Back or forward 10 seconds (movies and episodes)"),
            Row(keys: "↑ ↓", what: "Volume for movies; previous or next channel for live TV (full screen)"),
            Row(keys: "Page Up / Page Down", what: "Previous or next channel"),
            Row(keys: "0 – 9, Return", what: "Type a channel number, then Return to go to it"),
            Row(keys: "Tab, C or Return", what: "Open the channel list while playing live TV"),
            Row(keys: "⌘→  ⌘←", what: "Skip forward or back 10 seconds"),
            Row(keys: "⌘]  ⌘[", what: "Next or previous channel"),
            Row(keys: "⌘L", what: "Go back to the last channel"),
            Row(keys: "⌘E", what: "Next episode"),
            Row(keys: "⌘.", what: "Stop"),
            Row(keys: "⇧⌘M", what: "Open Multi-View"),
            Row(keys: "⇧⌘P", what: "Open the player in its own window"),
        ]),
    ]

    private static func key(_ id: String, _ title: String, _ keys: String, _ summary: String, path: [String], aliases: [String] = [], detail: String? = nil, related: [String] = [],
                            platforms: AtlasPlatforms = .mac, reviewed: Bool = true) -> AtlasEntry {
        .make("shortcut.\(id)", .shortcut, title, summary, path: path, aliases: aliases, detail: detail, platforms: platforms, shortcut: keys, related: related, reviewed: reviewed)
    }

    static let all: [AtlasEntry] = [
        // Anywhere
        key("global.escape", "Esc closes the top layer", "Esc", "Closes the top-most thing: the search results, then a panel, then a title page, then the menus, then the expanded player. Each press closes one layer.", path: ["Keyboard", "Anywhere"],
            aliases: ["escape", "close", "go back", "dismiss", "back out"], detail: "In full screen, Esc leaves full screen. While the app is locked the keys do nothing."),
        key("global.tab", "Tab moves between controls", "Tab / ⇧Tab", "Moves the focus to the next or previous button or card. Turn on Keyboard navigation in System Settings > Keyboard if it skips controls.", path: ["Keyboard", "Anywhere"], aliases: ["focus", "navigate with keyboard", "tab key"]),
        key("global.return", "Return opens or plays", "Return", "Opens or plays whatever is highlighted: a result, a channel, a folder row.", path: ["Keyboard", "Anywhere"], aliases: ["enter", "play selected", "open selected"]),
        // Search
        key("search.escape", "Esc clears the search", "Esc", "In the top search box, Esc empties the text and leaves the box.", path: ["Keyboard", "Search"], aliases: ["clear search", "exit search"], related: ["menu.navigate.search"]),
        key("search.down", "Down arrow moves into the results", "↓", "In the top search box, the down arrow moves the focus into the list of results.", path: ["Keyboard", "Search"], aliases: ["go to results", "arrow down search"], related: ["menu.navigate.search"]),
        key("search.results", "Arrows and Return in search results", "↑ ↓ Return", "In the results, the up and down arrows change the selected result and Return opens or plays it.", path: ["Keyboard", "Search results"], aliases: ["choose a result", "pick a search result"], related: ["menu.navigate.search"]),
        // TV Guide
        key("guide.arrows", "TV Guide: move the time window", "← →", "In the TV Guide, the left and right arrows move the visible time window by 30 minutes.", path: ["Keyboard", "TV Guide"], aliases: ["guide earlier", "guide later", "scroll guide time", "epg time keys"], related: ["screen.tab.guide", "setting.guideHoursVisible"]),
        // Live TV list
        key("liveTV.return", "Live TV list: Return plays the channel", "Return", "On a channel row in the Live TV list, Return plays that channel.", path: ["Keyboard", "Live TV"], aliases: ["play highlighted channel"]),
        key("folderRow.return", "Folder rows: Return opens the folder", "Return", "On a folder row in Movies or Series, Return opens the folder.", path: ["Keyboard", "Movies and Series"], aliases: ["open folder with keyboard"]),
        // Player
        key("player.space", "Play or pause", "Space", "Plays or pauses what is playing.", path: ["Keyboard", "Player"], aliases: ["spacebar", "pause", "stop temporarily"], related: ["menu.playback.playPause"]),
        key("player.fullscreen", "Full screen", "F", "Switches full screen on or off for the player.", path: ["Keyboard", "Player"], aliases: ["fullscreen", "maximize player", "enter full screen", "exit full screen"]),
        key("player.mute", "Mute", "M", "Mutes or unmutes the sound.", path: ["Keyboard", "Player"], aliases: ["silence", "sound off", "unmute"]),
        key("player.exitFullscreen", "Esc leaves full screen", "Esc", "In full screen, Esc goes back to the normal player. While you are typing a channel number, Esc cancels the number.", path: ["Keyboard", "Player"], aliases: ["leave full screen", "exit fullscreen"]),
        key("player.seekArrows", "Arrow keys skip 10 seconds", "← →", "For movies and episodes, the left and right arrows jump 10 seconds back or forward. This works in full screen and while the player is open over the screen. Live TV has no position to skip.", path: ["Keyboard", "Player"],
            aliases: ["rewind", "fast forward", "skip back", "skip forward", "seek"], related: ["menu.playback.skipForward", "menu.playback.skipBack"]),
        key("player.seekJL", "J and L skip 10 seconds", "J  L", "For movies and episodes, J jumps 10 seconds back and L jumps 10 seconds forward.", path: ["Keyboard", "Player"], aliases: ["j key", "l key", "youtube keys"], related: ["shortcut.player.seekArrows"]),
        key("player.upDown", "Up and down arrows in full screen", "↑ ↓", "In full screen, movies change the volume by 5 percent per press. Live TV goes to the previous or next channel.", path: ["Keyboard", "Player"], aliases: ["volume keys", "volume up", "volume down", "channel up down"], related: ["menu.playback.nextChannel"]),
        key("player.pageKeys", "Page Up and Page Down change channel", "Page Up / Page Down", "While watching live TV, Page Up goes to the previous channel and Page Down to the next.", path: ["Keyboard", "Player"], aliases: ["next channel key", "previous channel key", "zap"], related: ["menu.playback.nextChannel"]),
        key("player.numberEntry", "Type a channel number", "0 – 9, Return", "While watching live TV, type the digits of a channel number. A badge shows what you typed. Return goes to that channel and Esc cancels.", path: ["Keyboard", "Player"], aliases: ["go to channel number", "enter channel number", "number pad channels", "type channel"]),
        key("player.channelList", "Open the channel list", "Tab, C or Return", "While watching live TV in full screen, Tab, C or Return opens the channel switcher. Inside it, the arrows move, Page Up and Page Down move eight rows, Return plays and Esc closes.", path: ["Keyboard", "Player"], aliases: ["channel switcher", "channel picker", "channel overlay", "quick switch"]),
        // Multi-View
        key("multiView.number", "Multi-View: pick a tile with 1 to 4", "1 – 4", "In the Multi-View window, the keys 1 to 4 give the sound to that tile.", path: ["Keyboard", "Multi-View"], aliases: ["choose tile", "select tile", "sound to tile"], related: ["menu.playback.openMultiView"]),
        key("multiView.mute", "Multi-View: mute", "M", "In the Multi-View window, M mutes or unmutes the tile that has the sound.", path: ["Keyboard", "Multi-View"], aliases: ["mute tile"], related: ["menu.playback.openMultiView"]),
        key("multiView.fill", "Multi-View: fill the window", "F", "In the Multi-View window, F makes the tile that has the sound fill the window, and again to go back.", path: ["Keyboard", "Multi-View"], aliases: ["maximize tile", "full tile"], related: ["gesture.mac.multiViewDoubleClick"]),
        key("multiView.escape", "Multi-View: Esc restores the tiles", "Esc", "In the Multi-View window, Esc puts a filled tile back with the others.", path: ["Keyboard", "Multi-View"], aliases: ["back to all"], related: ["menu.playback.openMultiView"]),
        // Home slideshow
        key("slideshow.keys", "Featured banner: arrows and Space", "← → Space", "On the big banner at the top of Discover and Featured, the left and right arrows change the slide and Space pauses or resumes the automatic change.", path: ["Keyboard", "Featured banner"], aliases: ["slideshow keys", "banner keys", "pause slideshow"]),
        // Person page
        key("person.arrows", "Person page: switch between all and your library", "← →", "On an actor or director page, the left arrow shows all their films and the right arrow shows only those in your library.", path: ["Keyboard", "Person page"], aliases: ["filmography scope", "library only filmography"]),
        // Photos
        key("photos.keys", "Photo viewer: arrows and Esc", "← → Esc", "In the photo viewer under Files, the left and right arrows go to the previous or next photo and Esc closes it.", path: ["Keyboard", "Photo viewer"], aliases: ["next photo", "previous photo", "close photo"]),
        // Dialogs
        key("dialog.escape", "Esc closes a dialog", "Esc", "In a dialog or a sheet with a Close, Back or Done button, Esc does the same as that button.", path: ["Keyboard", "Dialogs"], aliases: ["cancel dialog", "close sheet"]),
        key("dialog.return", "Return confirms the main button", "Return", "In forms such as Add Playlist or the custom theme editor, Return presses the main button (Connect, Apply, Continue).", path: ["Keyboard", "Dialogs"], aliases: ["confirm", "submit", "press ok"], related: ["menu.file.addPlaylist"]),
        // iPad
        key("ipad.tabs", "iPad: ⌘1 to ⌘9 open the sidebar destinations", "⌘1 – ⌘9", "With a keyboard on iPad, ⌘1 to ⌘9 open the sidebar destinations in the order the sidebar lists them.", path: ["Keyboard", "iPad"], aliases: ["ipad hotkeys", "ipad keyboard", "switch screens"], platforms: [.iPad]),
        key("ipad.search", "iPad: ⌘F opens Search", "⌘F", "With a keyboard on iPad, ⌘F opens the Search screen.", path: ["Keyboard", "iPad"], aliases: ["ipad find", "search with keyboard"], platforms: [.iPad]),
        key("ipad.folders", "iPad: ⌥⌘0 hides or shows the folder column", "⌥⌘0", "With a keyboard on iPad, ⌥⌘0 hides or shows the column of folders next to a list.", path: ["Keyboard", "iPad"], aliases: ["toggle folders", "hide folders", "sidebar toggle"], platforms: [.iPad]),
    ]
}
