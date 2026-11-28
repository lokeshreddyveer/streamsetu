import Foundation

/// Atlas entries for the playlist tools: merge, repeated songs, statistics, files in and out, and rule-based smart playlists.
enum AtlasMusicPlaylistTools {
    private static func c(_ id: String, _ title: String, _ summary: String, _ path: [String]) -> AtlasEntry {
        .make(id, .control, title, summary, path: path, platforms: .mac)
    }
    private static let page = ["Music", "Your Library", "Playlists"]

    static let all: [AtlasEntry] = [
        c("control.music.playlistMergeOpen", "Merge with other playlists", "In a playlist's More menu: opens a sheet to combine this playlist with others into a new playlist. The originals stay unless you choose to remove them.", page),
        c("control.music.playlistMergeChoice", "Playlist to merge with", "A row in the merge sheet. Tap it to add or remove that playlist from the merge. The count at the bottom shows how many songs the new playlist will hold.", page),
        c("control.music.playlistMergeDrop", "Leave out songs that appear more than once", "In the merge sheet: when on, a recording that appears in more than one playlist is added once, in the place it first appears.", page),
        c("control.music.playlistMergeDelete", "Remove the original playlists afterwards", "In the merge sheet: when on, the playlists you merged are deleted after the new one is made. Off by default.", page),
        c("control.music.playlistMerge", "Merge", "Makes the new playlist from this one and the playlists you ticked, in that order, with the name you typed (or the names joined).", page),
        c("control.music.playlistRepeatsOpen", "Find repeated songs", "In a playlist's More menu: lists songs that appear more than once (the same recording by id, ISRC, or title, artists and length). A remix or a live version is not a repeat.", page),
        c("control.music.playlistRemoveRepeats", "Remove repeated songs", "In the repeated-songs sheet: takes out the extra copies and keeps the first of each. A toast offers Undo to put them back.", page),
        c("control.music.playlistStatsOpen", "Playlist statistics", "In a playlist's More menu: shows its number of songs, total length, artists, albums, how many times and how many of its songs you have played, the last time, and the artists with the most songs.", page),
        c("control.music.playlistExport", "Export a playlist", "In a playlist's More menu, Export As: saves the playlist as an M3U8, M3U or JSON file you choose where to put. The JSON file keeps every song's details so it can be read back without searching. Mac only.", page),
        c("control.music.playlistImportFile", "Import a playlist file", "In the Playlists tab: reads an M3U, M3U8 or JSON playlist, finds each song with your sources, shows which ones were not found, and makes a new playlist from the rest.", page),
        c("control.music.playlistImportCreate", "Create playlist from the file", "At the end of an import: makes the playlist from the songs that were found. Songs that could not be found are listed and not added.", page),
        c("control.music.smartNew", "New smart playlist", "In the Playlists tab: starts a playlist defined by rules (title, artist, album, genre, language, release year, times played, last played, liked, length). It fills itself with the songs that match now.", page),
        c("control.music.smartEdit", "Edit a smart playlist", "Opens the rules of a smart playlist: all-or-any matching, the rules, how to sort, the most songs to keep, and a live count of what matches.", page),
        c("control.music.smartAddRule", "Add a rule", "In the smart playlist editor: adds a line to the rules.", page),
        c("control.music.smartRemoveRule", "Remove a rule", "In the smart playlist editor: removes that line from the rules.", page),
        c("control.music.smartSave", "Save a smart playlist", "Saves the rules. Only the rules are stored; the songs are worked out each time the list is opened. A rule with no value is ignored.", page),
        c("control.music.smartDuplicate", "Duplicate a smart playlist", "Right-click a smart playlist: makes a copy with the same rules to change.", page),
        c("control.music.smartDelete", "Delete a smart playlist", "Right-click a smart playlist: deletes the rules. No song is removed from your library.", page),
        c("control.music.smartKeep", "Keep as playlist", "On a smart playlist: makes an ordinary playlist from the songs that match right now, which then stays as it is.", page),
        c("control.music.smartRedraw", "Draw again", "On a smart playlist sorted at random: picks a new random order.", page),
        c("control.music.playlistToolsClose", "Close", "Closes this playlist tools sheet.", page),
        c("control.music.playlistToolsCancel", "Cancel", "Closes this playlist tools sheet without making any change.", page),
    ]
}
