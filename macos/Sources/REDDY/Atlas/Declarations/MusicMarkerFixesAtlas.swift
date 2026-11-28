import Foundation

/// Atlas entries for controls that were added to the Music screens without one: the Listen Now menus and links, folder dialogs, facet pickers, the radio thumbs and the playlist and smart-playlist pickers.
enum AtlasMusicMarkerFixes {
    private static func c(_ id: String, _ title: String, _ summary: String, _ path: [String]) -> AtlasEntry {
        .make(id, .control, title, summary, path: path, platforms: .mac)
    }

    static let all: [AtlasEntry] = [
        c("control.music.homeHeroTitle", "Hero title", "The title of the big card on Listen Now. It opens the album, playlist or station the card is about (Play plays it).", ["Music", "Listen Now"]),
        c("control.music.homeTopTrackMenu", "Top track menu", "Right-click a song in Your top tracks on Listen Now for the song menu: play next, add to queue or playlist, like, go to the artist or album.", ["Music", "Listen Now"]),
        c("control.music.homeTopTrackText", "Top track title", "Click a song's title in Your top tracks on Listen Now to play it. The artist names beside it open the artist.", ["Music", "Listen Now"]),
        c("control.music.homeMixPlay", "Play a mix", "In a mix tile's menu on Listen Now: plays the mix from the top.", ["Music", "Listen Now"]),
        c("control.music.homeMixShuffle", "Shuffle a mix", "In a mix tile's menu on Listen Now: plays the mix in random order.", ["Music", "Listen Now"]),
        c("control.music.homeMixPlayNext", "Play a mix next", "In a mix tile's menu on Listen Now: puts the mix's songs right after the one playing.", ["Music", "Listen Now"]),
        c("control.music.homeMixQueue", "Add a mix to the queue", "In a mix tile's menu on Listen Now: adds the mix's songs to the end of the queue.", ["Music", "Listen Now"]),
        c("control.music.libraryFacetPicker", "Genre or language filter", "In Your Library when the window is narrow: a menu that filters the list by one genre or one language. Choose All to clear it.", ["Music", "Your Library"]),
        c("control.music.libraryFolderCreate", "Create a playlist folder", "In the New folder dialog: makes an empty folder for playlists with the name you typed.", ["Music", "Your Library", "Playlists"]),
        c("control.music.libraryFolderCancel", "Cancel a folder dialog", "Closes the New folder or Rename folder dialog without changing anything.", ["Music", "Your Library", "Playlists"]),
        c("control.music.libraryFolderDone", "Done choosing playlists for a folder", "Closes the sheet where playlists are chosen for a folder. Each tick is saved as you make it.", ["Music", "Your Library", "Playlists"]),
        c("control.music.radioThumb", "Thumbs up and down", "While a radio station plays: thumbs up gives more songs like this one and likes it; thumbs down skips it and keeps it off this station.", ["Music", "Radio"]),
        c("control.music.playlistExportMenu", "Export As menu", "In a playlist's More menu: choose the file type (M3U8, M3U or JSON) to save the playlist as.", ["Music", "Your Library", "Playlists"]),
        c("control.music.playlistIconButton", "Playlist action button", "A round button in a playlist's header (add to queue, play next, download, share). Hover it for what it does.", ["Music", "Your Library", "Playlists"]),
        c("control.music.smartChipMenu", "Smart playlist menu", "Right-click a smart playlist chip in the Playlists tab: Edit, Duplicate or Delete.", ["Music", "Your Library", "Playlists"]),
        c("control.music.smartMatch", "Match all or any rule", "In the smart playlist editor: whether a song must match all the rules or just one of them.", ["Music", "Your Library", "Playlists"]),
        c("control.music.smartSort", "Smart playlist sort", "In the smart playlist editor: the order of the matching songs (recently added, most played, least played, A to Z, artist, random).", ["Music", "Your Library", "Playlists"]),
        c("control.music.smartField", "Rule field", "In the smart playlist editor: what a rule looks at (title, artist, album, genre, language, release year, times played, last played, liked, length).", ["Music", "Your Library", "Playlists"]),
        c("control.music.smartOperator", "Rule comparison", "In the smart playlist editor: how a rule compares (contains, does not contain, is, at least, at most, yes or no).", ["Music", "Your Library", "Playlists"]),
    ]
}
