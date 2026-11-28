import Foundation

/// Atlas entries for the controls of the playlist page (the person's own playlists and a service's): header, action row, song rows and "More like this".
enum AtlasMusicPlaylistPage {
    private static func c(_ id: String, _ title: String, _ summary: String, _ path: [String]) -> AtlasEntry {
        .make(id, .control, title, summary, path: path, platforms: .mac)
    }

    static let all: [AtlasEntry] = [
        c("control.music.playlistTitleRename", "Rename a playlist in place", "Click the title of a playlist of yours to type a new name. Return saves it, Escape keeps the old one.", ["Music", "Your Library", "Playlist"]),
        c("control.music.playlistTitleField", "Playlist name field", "The field that replaces the title while you rename a playlist in place.", ["Music", "Your Library", "Playlist"]),
        c("control.music.playlistDescriptionMore", "Show more or less of a description", "A long playlist description is cut to three lines. More shows all of it, Less cuts it again.", ["Music", "Playlist"]),
        c("control.music.playlistAddDescription", "Add a description to a playlist", "Shown under the title of a playlist of yours that has no description. Opens the edit window to write one.", ["Music", "Your Library", "Playlist"]),
        c("control.music.playlistAddToQueue", "Add the playlist to the queue", "Adds every song of the playlist to the end of the queue. On a service's playlist it first loads all its pages.", ["Music", "Playlist"]),
        c("control.music.playlistPlayNext", "Play the playlist next", "Puts every song of the playlist right after the song that is playing.", ["Music", "Playlist"]),
        c("control.music.playlistDownload", "Download the playlist", "Downloads every song for offline listening. It is offered for playlists of up to 500 songs; for a longer one, select songs and download those.", ["Music", "Playlist"]),
        c("control.music.playlistShare", "Share the playlist", "Opens the share window with a link or card for the playlist.", ["Music", "Playlist"]),
        c("control.music.playlistViewAs", "Choose how songs are drawn", "Switch between rows with artwork, compact rows and a table with an album column. The choice is kept for every playlist.", ["Music", "Playlist"]),
        c("control.music.playlistMoreMenu", "Playlist menu", "The three dots in the playlist header: rename, description, cover, radio, add all to another playlist, duplicate and delete for your own playlists.", ["Music", "Playlist"]),
        c("control.music.playlistRename", "Rename the playlist", "Opens the edit window to change the name of a playlist of yours.", ["Music", "Your Library", "Playlist"]),
        c("control.music.playlistEditDescription", "Edit the playlist description", "Opens the edit window to write or change the description, up to 300 characters.", ["Music", "Your Library", "Playlist"]),
        c("control.music.playlistChangeCover", "Change the playlist cover", "Opens the edit window where you pick a JPEG or PNG from this Mac, or remove it to go back to the mosaic of its albums.", ["Music", "Your Library", "Playlist"]),
        c("control.music.playlistAddAllToPlaylist", "Add all songs to another playlist", "Opens the playlist picker with every song of this playlist, to copy them into another playlist or a new one.", ["Music", "Your Library", "Playlist"]),
        c("control.music.playlistDuplicate", "Duplicate the playlist", "Makes a copy of the playlist with its songs and description, named with the word copy, and opens it.", ["Music", "Your Library", "Playlist"]),
        c("control.music.playlistDelete", "Delete the playlist", "Asks first, then removes the playlist. The songs stay in Your library.", ["Music", "Your Library", "Playlist"]),
        c("control.music.playlistFindAnotherVersion", "Find another version of a song", "Shown beside a song that could not be played. Opens the list of other recordings of it from your audio sources, so you can pick one that plays.", ["Music", "Playlist"]),
        c("control.music.playlistSuggestionPlay", "Play a suggested song", "Plays a song from More like this without adding it to the playlist.", ["Music", "Playlist"]),
        c("control.music.playlistSuggestionAdd", "Add a suggested song", "Adds the song from More like this to the playlist, or asks which playlist for a service's list.", ["Music", "Playlist"]),
        c("control.music.playlistSuggestionsRefresh", "Show other suggestions", "Asks the playlist's service for another set of songs like the ones in it.", ["Music", "Playlist"]),
    ]
}
