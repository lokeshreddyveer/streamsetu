import Foundation

/// Gestures, long presses, swipes, drags and mouse actions that have no button. Written from the code that handles them; the path of each says where it works.
enum AtlasGestures {
    private static func g(_ id: String, _ title: String, _ summary: String, path: [String], aliases: [String] = [], detail: String? = nil, platforms: AtlasPlatforms, related: [String] = [], reviewed: Bool = true) -> AtlasEntry {
        .make("gesture.\(id)", .gesture, title, summary, path: path, aliases: aliases, detail: detail, platforms: platforms, related: related, reviewed: reviewed)
    }
    private static let phone: AtlasPlatforms = [.iPhone, .iPad]

    static let all: [AtlasEntry] = ios + player + mac

    // MARK: iPhone and iPad, outside the player

    static let ios: [AtlasEntry] = [
        g("ios.tabTripleTap", "Tap a tab three times", "Three quick taps (within a second) on the same tab of the bottom bar refresh your library: the playlist that is open, or every playlist when all are chosen. A message says “Refreshing your library…”, or that it is already refreshing.",
          path: ["iPhone", "Bottom tab bar"], aliases: ["triple tap", "refresh from tab bar", "refresh library by tapping tab", "tap tab three times", "quick refresh"],
          detail: "Taps on different tabs never count, so moving around the bar cannot start a refresh by accident.", platforms: [.iPhone], related: ["gesture.ios.tabRetap", "gesture.ios.pullToRefresh", "menu.file.refreshAll"]),
        g("ios.tabRetap", "Tap the current tab again", "Tapping the tab you are already on rebuilds that screen, which closes whatever page you had opened inside it and returns to its first page.",
          path: ["iPhone", "Bottom tab bar"], aliases: ["go back to the top", "reset tab", "close opened page", "back to tab root", "pop to root"], platforms: [.iPhone], related: ["gesture.ios.tabTripleTap"]),
        g("ios.tabBarPill", "Bottom bar shrinks while you scroll", "While a page scrolls down, the tab bar shrinks into a small round button at the right showing the current tab. Tap that button to bring the whole bar back.",
          path: ["iPhone", "Bottom tab bar"], aliases: ["tab bar disappeared", "where did the tab bar go", "bottom bar hidden", "bring back tab bar"], platforms: [.iPhone]),
        g("ios.pullToRefresh", "Pull down to refresh", "Pull a list down and let go to refresh your playlists. It works on Home, the Library lists (Movies, Series and more) and Live TV. In a Files folder, pulling down reloads that folder.",
          path: ["iPhone", "Home, Library, Live TV"], aliases: ["pull to refresh", "swipe down to refresh", "refresh by pulling", "drag down refresh", "reload by pulling"], platforms: phone, related: ["gesture.ios.tabTripleTap", "menu.file.refreshAll"]),
        g("ios.swipeFavourite", "Swipe a channel to favourite it", "In the Live TV list on iPhone, swipe a channel from the left edge toward the right to add it to Favourites, or to remove it when it is already one. The button is pink with a heart.",
          path: ["iPhone", "Live TV", "Channel row"], aliases: ["swipe to favorite", "favourite a channel by swiping", "heart a channel", "swipe right on channel", "add favorite quickly"], platforms: [.iPhone], related: ["context.tile.favorite", "screen.shortcut.favorites"]),
        g("ios.swipeActions", "Swipe a row for its actions", "Many lists show buttons when you swipe a row sideways: Playlists (Delete, Refresh), Watch History (Remove), Collections (Delete), the Channel Manager (Hide or Show), Hidden folders (Hide) and paired devices (Forget).",
          path: ["iPhone", "Lists"], aliases: ["swipe to delete", "swipe left", "swipe a row", "delete by swiping", "swipe actions"], platforms: phone,
          related: ["gesture.ios.swipePlaylist", "gesture.ios.swipeHistory", "gesture.ios.swipeCollection", "gesture.ios.swipeChannelManager", "gesture.ios.swipeFolderHide", "gesture.ios.swipePeer"]),
        g("ios.swipePlaylist", "Swipe a playlist: Delete or Refresh", "In Playlists, swipe a playlist row to get Delete (asks first) and Refresh, which refreshes that playlist and its guide.", path: ["More", "Playlists", "Playlist row"],
          aliases: ["delete a playlist", "refresh one playlist"], platforms: phone, related: ["context.ios.playlist"]),
        g("ios.swipeHistory", "Swipe a history line: Remove", "In Watch History, swipe a line to remove that title's progress from your history.", path: ["More", "Watch History", "Line"],
          aliases: ["remove from history", "clear history entry", "delete watched"], platforms: phone, related: ["screen.shortcut.watchHistory"]),
        g("ios.swipeCollection", "Swipe a collection: Delete", "In Collections, swipe a collection to delete it. The titles in it stay in your library.", path: ["More", "Collections", "Collection row"],
          aliases: ["delete collection"], platforms: phone, related: ["screen.shortcut.collections"]),
        g("ios.swipeChannelManager", "Swipe a channel in the Channel Manager: Hide or Show", "In the Channel Manager, swipe a channel to hide it, or to show it again when it is hidden.", path: ["Settings", "Channel Manager", "Channel row"],
          aliases: ["hide channel by swiping", "unhide channel"], platforms: phone, related: ["screen.settings.channelManager", "context.tile.hideChannel"]),
        g("ios.swipeFolderHide", "Swipe a folder: Hide", "In the Library settings list of folders, swipe a folder to hide it.", path: ["Settings", "Library", "Folders", "Folder row"], aliases: ["hide folder by swiping", "hide category"],
          platforms: phone),
        g("ios.swipePeer", "Swipe a paired device: Forget", "In Sync on this network, swipe a paired device to forget it.", path: ["Settings", "Sync on this network", "Devices"], aliases: ["unpair device", "forget device", "remove paired device"],
          platforms: phone, related: ["setting.lanSync"]),
        g("ios.guideDrag", "Drag the TV Guide sideways", "In the TV Guide on iPhone and iPad, drag left or right to move through time. Vertical drags still scroll the channels.", path: ["TV Guide"], aliases: ["scroll guide time", "swipe guide", "move guide to later", "guide horizontal scroll"],
          platforms: phone, related: ["shortcut.guide.arrows", "screen.tab.guide"]),
        g("ios.multiViewTap", "Multi-View: tap for sound, double-tap to fill", "In Multi-View, tap a tile to give it the sound. Double-tap a tile to make it fill the screen, and double-tap again to go back.", path: ["Multi-View", "Tile"],
          aliases: ["multiview double tap", "maximise a tile", "switch sound tile"], platforms: phone, related: ["context.ios.multiViewTile", "gesture.mac.multiViewDoubleClick"]),

        // The player on iPhone and iPad (Player/PlayerGestures.swift, PlayerScreen.swift)
        g("ios.playerTap", "Tap the video to show or hide the controls", "A single tap on the video shows the controls or hides them. When the controls are locked, a tap shows the unlock button.", path: ["Player"],
          aliases: ["show controls", "hide controls", "controls disappeared", "tap screen"], platforms: phone),
        g("player.doubleTapSeek", "Double-tap to skip 10 seconds", "In a movie or episode, double-tap the left half of the video to go back 10 seconds, or the right half to go forward 10. Keep double-tapping on the same side to add more: 20, 30 seconds. Live TV has no skip.",
          path: ["Player"], aliases: ["double tap to skip", "skip forward by tapping", "skip back by tapping", "tap twice rewind", "double tap seek", "double tap side of screen", "skip 10 seconds"], platforms: phone, related: ["shortcut.player.seekArrows"]),
        g("player.hold", "Press and hold for double speed", "In a movie or episode, press and hold the video to play at 2× while you hold. Let go and the old speed returns. Live TV has no hold.", path: ["Player"],
          aliases: ["hold to speed up", "2x speed", "fast forward by holding", "long press video", "temporary fast speed"], platforms: phone),
        g("ios.playerBrightnessVolume", "Drag at the sides for brightness and volume", "In the player, drag up or down along the left side to change the screen brightness, or along the right side to change the volume. The sides swap when left-handed mode is on. A percentage shows while you drag.",
          path: ["Player"], aliases: ["change brightness by swiping", "volume swipe", "swipe volume", "brightness slider gesture", "drag for volume"], platforms: phone, related: ["gesture.ios.playerScrub"]),
        g("ios.playerScrub", "Swipe along the video to move through a movie", "In a movie or episode, drag left or right across the middle of the video. A preview shows where you would land, and letting go jumps there.", path: ["Player"],
          aliases: ["swipe to seek", "scrub", "drag to seek", "slide to skip"], platforms: phone, related: ["gesture.ios.playerSeekBar", "gesture.player.doubleTapSeek"]),
        g("ios.playerZap", "Swipe to change channel", "While watching live TV, swipe left or up for the next channel, or right or down for the previous one. The swipe has to be at least 80 points long.", path: ["Player", "Live TV"],
          aliases: ["swipe channel", "change channel by swiping", "zap", "next channel gesture", "channel surf"], platforms: phone, related: ["menu.playback.nextChannel"]),
        g("ios.playerPullDown", "Pull the top of the video down to close the player", "Drag down from the top part of the video and let go after about 140 points to close the full-screen player. The system's own edge swipes are left alone.", path: ["Player"],
          aliases: ["swipe down to close player", "dismiss player", "minimise player", "drag player down"], platforms: phone),
        g("ios.playerPinch", "Pinch the video to fill or zoom", "Spread two fingers to fill the screen and then zoom in; pinch them together to zoom out and then go back to fit. When zoomed in, drag the picture with one finger to move it.", path: ["Player"],
          aliases: ["zoom video", "pinch to zoom", "fill screen", "fit to screen", "remove black bars", "aspect ratio gesture"], platforms: phone),
        g("ios.playerSeekBar", "Drag the seek bar", "Touch the seek bar and slide to the time you want. The time shows above your finger, and the jump happens when you let go.", path: ["Player", "Seek bar"], aliases: ["scrubber", "progress bar", "timeline"],
          platforms: phone, related: ["gesture.ios.playerScrub"]),
        g("ios.playerEdges", "Gestures ignore the screen edges", "Touches that start at the very edges of the screen, or just above the home bar, are left to the system, so Home and Control Center swipes never trigger a player gesture.", path: ["Player"],
          aliases: ["gesture not working at edge", "swipe from edge"], platforms: phone),
    ]

    // MARK: Mac player (hover and click)

    static let player: [AtlasEntry] = [
        g("mac.playerClick", "Click the video to play or pause", "A single click on the video pauses it, or plays it again.", path: ["Player"], aliases: ["click to pause", "click video", "mouse pause"], platforms: .mac, related: ["shortcut.player.space"]),
        g("mac.playerDoubleClick", "Double-click the video for full screen", "A double-click on the video switches full screen on or off.", path: ["Player"], aliases: ["double click fullscreen", "double click to enlarge", "mouse fullscreen"], platforms: .mac, related: ["shortcut.player.fullscreen"]),
        g("mac.playerHover", "Move the mouse to show the controls", "Moving the pointer over the player shows its controls. They fade again after a short while without movement.", path: ["Player"], aliases: ["controls hidden", "where are the controls", "show player controls", "controls disappear"],
          platforms: .mac),
        g("mac.playerPan", "Drag a zoomed picture", "When the picture is zoomed in, click and drag it to move it. At normal size, dragging does nothing.", path: ["Player"], aliases: ["move zoomed video", "pan video"], platforms: .mac),
        g("mac.seekBarDrag", "Drag on the seek bar", "Click or drag along the seek bar to choose a time. The jump happens when you let go, so seeking does not flood the stream. VoiceOver can adjust it in 10 second steps.", path: ["Player", "Seek bar"],
          aliases: ["scrub", "click progress bar", "jump to time", "timeline"], platforms: .mac),
    ]

    // MARK: Mac elsewhere

    static let mac: [AtlasEntry] = [
        g("mac.multiViewDoubleClick", "Multi-View: click for sound, double-click to fill", "In the Multi-View window, a click on a tile gives it the sound and a double-click makes it fill the window. Double-click again to go back.", path: ["Multi-View", "Tile"],
          aliases: ["maximize tile", "fill the window", "multiview click", "switch audio tile"], platforms: .mac, related: ["context.multiView.tileMac", "shortcut.multiView.fill"]),
        g("mac.channelListDivider", "Drag the divider of the channel list", "In Live TV, drag the thin divider between the channel list and the video to change how wide the list is. The pointer turns into a left-right arrow over it. VoiceOver can change it in steps of 20 points.",
          path: ["Live TV", "Channel list"], aliases: ["resize channel list", "make list wider", "make list narrower", "channel list width", "drag divider"], platforms: .mac, related: ["screen.tab.liveTV"]),
        g("mac.sidebarDragFolders", "Drag folders in the sidebar to reorder them", "In the sidebar, drag a folder up or down and drop it where you want it. The right-click menu has the same moves for the keyboard.", path: ["Sidebar", "Folders"],
          aliases: ["reorder folders", "rearrange categories", "sort folders by dragging", "move folder"], platforms: .mac, related: ["context.sidebar.folderReorder"]),
        g("mac.windowDrop", "Drop a file or link on the window", "Drop a playlist file or a link on the app window and the Add Playlist form opens with it filled in. A video file plays at once instead. Text that is not a playlist link shows a message. While the app is locked, drops are ignored.",
          path: ["Any screen"], aliases: ["drag and drop playlist", "drop m3u", "drop a file", "drag a link into the app", "drag video to play"], platforms: .mac, related: ["menu.file.addPlaylist", "menu.file.openVideoFile"]),
        g("mac.slideshowHover", "Hover the banner to pause it", "Moving the pointer over the big banner on Discover or Featured, or giving it keyboard focus, stops the slides from changing by themselves. They carry on when you leave. The slides also stop when Reduce animation is on.",
          path: ["Home", "Discover", "Banner"], aliases: ["banner keeps changing", "stop slideshow", "pause banner"], platforms: .mac, related: ["setting.reduceMotion", "shortcut.slideshow.keys"]),
        g("mac.photoPinch", "Photo viewer: pinch to zoom, swipe to change photo", "In the photo viewer under Files, pinch to zoom in. When not zoomed, swipe left or right (a drag of more than 60 points) to go to the next or previous photo.", path: ["Files and Servers", "Photo viewer"],
          aliases: ["zoom photo", "next photo swipe"], platforms: .mac, related: ["shortcut.photos.keys"]),
    ]
}
