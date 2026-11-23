import Foundation

/// Right-click (Mac) and press-and-hold (iPhone, iPad) menus. The title and channel menus come from one table (`TileMenu.Action` in Features/Shared/TileMenu.swift); every other menu has one entry
/// that lists its actions.
enum AtlasContext {
    private static let tileHow = "Right-click a poster (Mac) or press and hold it (iPhone, iPad)."

    private static func tile(_ action: String, _ title: String, _ summary: String, aliases: [String] = [], detail: String? = nil, platforms: AtlasPlatforms = .all, related: [String] = [], reviewed: Bool = true) -> AtlasEntry {
        .make("context.tile.\(action)", .contextAction, title, summary, path: ["Any poster or channel", "Context menu", title], aliases: aliases, detail: detail, platforms: platforms, related: related + ["context.tile.menu"], reviewed: reviewed)
    }

    private static func site(_ id: String, _ title: String, _ summary: String, path: [String], platforms: AtlasPlatforms = .mac, aliases: [String] = [], detail: String? = nil, related: [String] = [], guideOnly: Bool = false,
                             safety: AtlasSafety = .read) -> AtlasEntry {
        .make("context.\(id)", .contextAction, title, summary, path: path + ["Context menu"], aliases: aliases, detail: detail, platforms: platforms, related: related, safety: safety, guideOnly: guideOnly, reviewed: true)
    }

    static let all: [AtlasEntry] = tiles + sites

    // MARK: titles and channels (TileMenu)

    static let tiles: [AtlasEntry] = [
        .make("context.tile.menu", .contextAction, "Poster menu (right-click or press and hold)",
              "\(tileHow) A menu opens with Play, Watch Privately, details, Favorites, Watch Later, Add to Collection, queue items, Don't Recommend, Share Link and Hide. The list changes with the title: for example, the favourites moves only show for a favourite.",
              path: ["Any poster", "Context menu"], aliases: ["long press", "press and hold", "right click", "right-click menu", "context menu", "poster menu", "tile menu", "hold a poster", "more options for a title", "three dots"],
              related: ["context.tile.play", "context.tile.favorite", "context.tile.watchLater", "context.tile.hide", "context.channel.menu"], reviewed: true),
        .make("context.channel.menu", .contextAction, "Channel menu (right-click or press and hold)",
              "Right-click a channel (Mac) or press and hold it (iPhone, iPad). The menu has Play, Watch Privately, Add to Favorites, Add to Collection, Share Link, Add to Multi-View, Hide Channel and, on iPhone and iPad, Rename.",
              path: ["Any channel", "Context menu"], aliases: ["channel long press", "channel right click", "hold a channel", "channel options", "channel context menu"],
              related: ["context.tile.multiView", "context.tile.hideChannel", "context.tile.rename", "context.tile.menu"], reviewed: true),

        tile("resume", "Resume", "Shown on titles in Continue Watching. It plays the title.", aliases: ["continue", "pick up where i left off"], related: ["screen.shortcut.continueWatching"], reviewed: true),
        tile("play", "Play", "Plays the title or the channel.", aliases: ["start", "watch now"]),
        tile("watchPrivately", "Watch Privately", "Plays without saving anything to your history or Continue Watching.", aliases: ["private", "incognito", "no history", "watch without history", "hide from history"],
             related: ["guide.continueWatchingAndHistory"]),
        tile("openDetails", "View Details", "Opens the title page. On a Continue Watching title the same item is called Open Title Page.", aliases: ["open title page", "details", "info", "more info", "title page"]),
        tile("openFolder", "In folder", "Shown as “In folder” followed by the folder name. It opens the folder this title belongs to in Movies or Series.", aliases: ["show folder", "go to category", "open category", "which folder"],
             platforms: .all),
        tile("goToCast", "Go to Cast", "Opens the title page with the cast row in view. It only appears when the cast of that title has been read.", aliases: ["cast", "actors", "see the cast"], related: ["setting.castReading"]),
        tile("favorite", "Add to Favorites", "Adds the title or channel to Favorites, or removes it when it is already there. On iPhone and iPad the word is spelled Favourites.", aliases: ["favourite", "heart", "star", "like", "love", "save to favorites", "remove from favorites"],
             related: ["screen.shortcut.favorites"]),
        tile("watchLater", "Add to Watch Later", "Adds the title to Watch Later, or removes it when it is already there.", aliases: ["bookmark", "watchlist", "save for later", "queue for later", "remove from watch later"], related: ["screen.shortcut.watchLater"]),
        tile("moveToFront", "Move to Front of Favorites", "Moves a favourite to the start of the Favorites list. Only shown for titles that are already favourites.", aliases: ["favorite to top", "reorder favorites", "put first"], related: ["context.tile.moveToEnd"]),
        tile("moveToEnd", "Move to End of Favorites", "Moves a favourite to the end of the Favorites list. Only shown for titles that are already favourites.", aliases: ["favorite to bottom", "reorder favorites", "put last"], related: ["context.tile.moveToFront"]),
        tile("collection", "Add to Collection", "A submenu with your collections, so you can put the title or channel in one.", aliases: ["collections", "add to list", "put in a group", "new collection"], related: ["screen.shortcut.collections", "guide.collections"]),
        tile("playNext", "Play Next", "Puts the title at the front of your queue so it plays after what is playing now. A toast confirms it.", aliases: ["play after this", "next up", "queue next"], related: ["context.tile.addToQueue"]),
        tile("addToQueue", "Add to Queue", "Adds the title to the end of your queue. A toast confirms it.", aliases: ["queue", "watch queue", "add to up next"], related: ["context.tile.playNext", "context.tile.removeFromQueue"]),
        tile("removeFromQueue", "Remove from Queue", "Takes the title out of the queue. It replaces Play Next and Add to Queue when the title is already queued.", aliases: ["unqueue", "remove from up next"], related: ["context.tile.addToQueue"]),
        tile("dontRecommend", "Don't Recommend This", "Stops this title being picked for the recommendations on Home. A toast offers Undo for 8 seconds. The title stays in your library.", aliases: ["not interested", "stop suggesting", "hide from recommendations", "dislike", "thumbs down", "dismiss recommendation"],
             related: ["menu.navigate.shuffle"]),
        tile("share", "Share Link", "Opens the system share sheet with a streamsetu:// link to the title or channel.", aliases: ["share", "send a link", "copy link", "deep link"]),
        tile("hide", "Hide This Title", "Hides the title from your lists and search without deleting it from the provider. A toast offers Undo for 8 seconds.", aliases: ["hide movie", "hide series", "remove from library", "hide show", "get rid of a title"],
             detail: "Hidden titles are not deleted; the provider still lists them."),
        tile("removeFromContinue", "Remove from Continue Watching", "Takes the title off Continue Watching. A toast offers Undo for 8 seconds. It does not delete your history.", aliases: ["clear from continue watching", "remove from resume", "stop showing", "dismiss continue"],
             related: ["screen.shortcut.continueWatching"]),
        tile("multiView", "Add to Multi-View", "Adds the channel to Multi-View, which shows up to four channels at once. When four are already in it, a message says it is full.", aliases: ["multiview", "add to split screen", "watch with others"],
             related: ["menu.playback.openMultiView"]),
        tile("hideChannel", "Hide Channel", "Hides the channel from your lists without deleting it from the playlist. You can show it again in the Channel Manager.", aliases: ["hide a channel", "remove channel", "hide station"], related: ["screen.settings.channelManager"]),
        tile("rename", "Rename…", "Lets you give the channel your own name. Offered on iPhone and iPad.", aliases: ["rename channel", "change channel name", "edit channel name"], platforms: [.iPhone, .iPad], related: ["screen.settings.channelManager"]),
    ]

    // MARK: other menus

    static let sites: [AtlasEntry] = [
        site("sidebar.folderReorder", "Sidebar folder menu", "Right-click a folder in the sidebar. Move to Top, Move Up, Move Down and Move to Bottom change its place. Hide Folder hides it. Lock Folder with PIN or Unlock Folder is also there.",
             path: ["Sidebar", "Folder"], aliases: ["reorder folders", "move folder", "hide folder", "folder order", "sort folders", "right click folder"], related: ["context.sidebar.folderLock", "screen.settings.channelManager"]),
        site("sidebar.folderLock", "Lock or unlock a folder", "Right-click a folder and choose Lock Folder with PIN, or Unlock Folder when it is locked. It only appears when parental controls are available. Setu explains this and never changes it.",
             path: ["Sidebar", "Folder"], aliases: ["lock folder", "pin folder", "parental lock", "unlock folder", "restrict folder"], related: ["setting.parental"], guideOnly: true, safety: .never),
        site("slideshow.banner", "Featured banner menu", "Right-click a slide of the big banner on Discover to get the same menu as a poster. The banner on the Featured screen has no menu.", path: ["Home", "Discover", "Banner"],
             aliases: ["banner menu", "slideshow menu", "featured menu"], related: ["context.tile.menu"]),
        site("series.episode", "Episode menu", "Right-click an episode on a series page: Play, Mark as Watched (or Mark as Unwatched when it is done) and, when it has progress, Reset Progress.",
             path: ["Series page", "Episode"], aliases: ["mark episode watched", "mark as watched", "mark unwatched", "reset progress", "episode options", "watched episode"], related: ["guide.continueWatchingAndHistory"]),
        site("series.seasonEpisode", "Episode list menu", "Right-click an episode in the list on a series page: Play, or Watch Privately to play it without saving history.", path: ["Series page", "Episodes"],
             aliases: ["play episode", "watch episode privately"], related: ["context.tile.watchPrivately"]),
        site("guide.row", "Guide programme menu", "Right-click a programme in the TV Guide: Details, and Watch Now when it is on right now.", path: ["TV Guide", "Programme"], aliases: ["programme details", "watch now from guide", "guide right click", "epg menu"],
             related: ["screen.tab.guide"]),
        site("commandCenter.channel", "Channel Manager row menu", "Right-click a channel in the Channel Manager: Rename…, Move to folder…, Match guide…, Show or Hide, Add to or Remove from favorites, and Restore provider defaults.",
             path: ["Channel Manager", "Channel"], aliases: ["rename channel", "move channel", "match guide", "epg match", "restore channel defaults", "hide channel", "channel manager menu", "command center"], related: ["screen.settings.channelManager"]),
        site("home.recentChannel", "Recently Watched channel menu", "Right-click a channel in Recently Watched: Play, Watch Privately, and Remove from Recently Watched.", path: ["Home", "Recently Watched"],
             aliases: ["remove from history", "clear recent channel"], related: ["screen.shortcut.recentlyWatched"]),
        site("home.historyEntry", "Watch History entry menu", "Right-click a line in Watch History and choose Remove Entry. The small cross at the end of the line does the same.", path: ["Home", "Watch History"],
             aliases: ["delete history entry", "remove from history", "clear one item from history", "forget what i watched"], related: ["screen.shortcut.watchHistory"]),
        site("home.collectionChip", "Collection menu", "Right-click a collection name at the top of Collections: Rename… or Delete. Deleting a collection does not delete the titles in it.", path: ["Home", "Collections"],
             aliases: ["rename collection", "delete collection", "remove collection"], related: ["screen.shortcut.collections", "guide.collections"]),
        site("home.collectionItem", "Collection item menu", "Right-click a channel, movie or series in a collection and choose Remove from collection. A channel also has Play.", path: ["Home", "Collections", "Item"],
             aliases: ["remove from collection", "take out of collection"], related: ["screen.shortcut.collections"]),
        site("liveTV.channel", "Live TV channel menu", "Right-click a channel in Live TV for the channel menu: Play, Watch Privately, favourites, collection, share, Add to Multi-View and Hide Channel.", path: ["Live TV", "Channel"],
             aliases: ["channel options"], related: ["context.channel.menu"]),
        site("files.source", "Files source menu", "Right-click a folder or server in Files and choose Remove. It removes the entry from the app, not the files.", path: ["Files and Servers", "Source"], aliases: ["remove server", "remove folder", "forget server"],
             related: ["menu.file.filesAndServers"]),
        site("podcasts.show", "Podcast menu", "Right-click a podcast you follow and choose Unfollow.", path: ["Files and Servers", "Podcasts"], aliases: ["unfollow podcast", "unsubscribe podcast", "remove podcast"], related: ["menu.file.filesAndServers"]),
        site("multiView.tileMac", "Multi-View tile menu (Mac)", "Right-click a tile in the Multi-View window: Play Sound from This Channel, Fill the Window (or Back to All Channels), Make Large Tile (with two or more tiles), Change Channel…, Reload and Remove.",
             path: ["Multi-View", "Tile"], aliases: ["make tile big", "change multiview channel", "remove from multiview", "spotlight tile", "reload tile"], related: ["menu.playback.openMultiView", "gesture.mac.multiViewDoubleClick"]),
        site("search.result", "Search result menu", "Right-click a title or channel in the search results for the same menu as a poster. Folders, episodes and programmes have no menu.", path: ["Search results", "Result"],
             aliases: ["search result options"], related: ["context.tile.menu", "context.channel.menu"], safety: .read),
        site("ios.episode", "Episode menu (iPhone and iPad)", "Press and hold an episode on a series page: Play, or Watch Privately to play it without saving history.", path: ["Series page", "Episodes"], platforms: [.iPhone, .iPad],
             aliases: ["hold an episode", "play episode privately"], related: ["context.tile.watchPrivately"]),
        site("ios.playlist", "Playlist menu (iPhone and iPad)", "Press and hold a playlist in Playlists: Use This Playlist (when it is not the active one), Refresh, and Delete…, which asks first.", path: ["More", "Playlists", "Playlist"],
             platforms: [.iPhone, .iPad], aliases: ["delete playlist", "refresh one playlist", "switch playlist", "use playlist"], related: ["gesture.ios.swipeActions", "screen.playlists"]),
        site("ios.liveChannel", "Live TV channel menu (iPhone and iPad)", "Press and hold a channel in Live TV for the channel menu: Play, Watch Privately, favourites, collection, share, Rename…, Add to Multi-View and Hide Channel.",
             path: ["Live TV", "Channel"], platforms: [.iPhone, .iPad], aliases: ["hold channel", "rename channel on iphone"], related: ["context.channel.menu", "gesture.ios.swipeFavourite"]),
        site("ios.multiViewTile", "Multi-View tile menu (iPhone and iPad)", "Press and hold a tile in Multi-View: Play Sound, Fill the Screen (or Back to All), Make Large Tile (with two or more tiles), Change Channel…, Reload and Remove.",
             path: ["Multi-View", "Tile"], platforms: [.iPhone, .iPad], aliases: ["hold a multiview tile", "make tile big", "remove tile"], related: ["gesture.ios.multiViewTap"]),
    ]
}
