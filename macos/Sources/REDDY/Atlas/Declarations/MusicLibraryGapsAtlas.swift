import Foundation

/// Atlas entries for Your library's quick links, genre and language rows, playlist folders and the Local files folder view.
enum AtlasMusicLibraryGaps {
    private static func c(_ id: String, _ title: String, _ summary: String, _ path: [String]) -> AtlasEntry {
        .make(id, .control, title, summary, path: path, platforms: .mac)
    }

    static let all: [AtlasEntry] = [
        c("control.music.libraryQuickLink", "Library quick links", "A row at the top of Your library with one click to Favorites, Recently added, Recently played, Most played and Never played. The last three open lists built from what you played on this Mac.", ["Music", "Your Library"]),
        c("control.music.libraryFacetMenu", "Genre or language menu", "On a narrow window the Genres and Languages rows become menus. Pick one to show only those songs, or All to show everything.", ["Music", "Your Library"]),
        c("control.music.libraryFacetChip", "Genre or language chip", "Each chip is a genre or language found in the tab, with how many items it has. Click one to filter the list and click it again to show everything. Songs with no genre or language stated are in no chip.", ["Music", "Your Library"]),
        c("control.music.libraryFolderNew", "New playlist folder", "Creates a folder for grouping your playlists. Playlists stay in your library; a folder only lists which ones it holds.", ["Music", "Your Library", "Playlists"]),
        c("control.music.libraryFolderChoose", "Choose the playlists in a folder", "Opens a list of all your playlists with a check for those in the chosen folder. A playlist is in one folder at most, so ticking it moves it here.", ["Music", "Your Library", "Playlists"]),
        c("control.music.libraryFolderRename", "Rename a playlist folder", "Changes the name of the chosen folder. A name another folder already has is refused.", ["Music", "Your Library", "Playlists"]),
        c("control.music.libraryFolderDelete", "Delete a playlist folder", "Removes the chosen folder only. Every playlist in it stays in your library.", ["Music", "Your Library", "Playlists"]),
        c("control.music.libraryFolderToggle", "Put a playlist in the folder", "Adds the playlist to the chosen folder, or takes it out when it is already there.", ["Music", "Your Library", "Playlists"]),
        c("control.music.libraryLocalFolders", "Browse Local files by folder", "Switches Local files between one list of every file and the folders you chose, with their sub-folders.", ["Music", "Your Library", "Local files"]),
        c("control.music.libraryLocalFolderRow", "Open a music folder", "Opens the folder to see its sub-folders and files. The count is every song in it and below it.", ["Music", "Your Library", "Local files"]),
        c("control.music.libraryLocalCrumb", "Go back up the folder path", "Each name in the path above the list is a folder you passed through. Click one to go back to it.", ["Music", "Your Library", "Local files"]),
        c("control.music.libraryLocalCrumbRoot", "All music folders", "Returns to the list of folders you chose for Local files.", ["Music", "Your Library", "Local files"]),
        c("control.music.libraryLocalPlayFolder", "Play folder", "Plays every song in the folder you are in and in the folders below it, files first, then each sub-folder in name order.", ["Music", "Your Library", "Local files"]),
        c("control.music.libraryLocalShuffleFolder", "Shuffle folder", "Plays every song in the folder you are in and below it in a random order.", ["Music", "Your Library", "Local files"]),
    ]
}
