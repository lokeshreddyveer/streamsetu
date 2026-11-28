import Foundation

/// Atlas entries for the controls the album page adds: the cover viewer, the playback options, the tracklist search and sort, disc menus, versions and edition
/// choices, credits by person, the film card, export and refresh.
enum AtlasMusicAlbumPage {
    private static func c(_ id: String, _ title: String, _ summary: String, _ path: [String] = ["Music", "Album"], aliases: [String] = []) -> AtlasEntry {
        .make(id, .control, title, summary, path: path, aliases: aliases, platforms: .mac)
    }

    static let all: [AtlasEntry] = [
        c("control.music.albumCoverOpen", "Open the album cover", "Click the cover of an album to see it large in its own window, where you can zoom in and out."),
        c("control.music.albumCoverZoomIn", "Zoom in on the album cover", "Makes the cover in the cover window larger, up to four times."),
        c("control.music.albumCoverZoomOut", "Zoom out of the album cover", "Makes the cover in the cover window smaller again, down to its normal size."),
        c("control.music.albumCoverClose", "Close the cover window", "Closes the large view of the album cover and returns to the album page."),
        c("control.music.albumTrackSearch", "Search inside an album", "Type to show only the songs of this album whose title or artists match. The album order is not changed."),
        c("control.music.albumTrackSort", "Sort the songs of an album", "Shows the songs by album order, by title or longest first. Only the view changes; the album keeps its own order."),
        c("control.music.albumTrackFilter", "Filter the songs of an album", "Shows all songs, only the ones you liked, or only the ones you have not played yet."),
        c("control.music.albumTrackSortMenu", "Sort and filter menu of an album", "Opens the choices to sort the songs of an album and to show only liked or unplayed songs."),
        c("control.music.albumPlayModesMenu", "Album play options", "Opens the ways to play this album: in order, shuffled, continue it, only liked songs, only unplayed songs, or one disc."),
        c("control.music.albumPlayMode", "Choose how to play the album", "Starts the album in the chosen way through the normal player and queue.", aliases: ["play disc", "shuffle disc", "unplayed songs"]),
        c("control.music.albumDiscToggle", "Collapse or expand a disc", "Hides or shows the songs of one disc of a multi-disc album."),
        c("control.music.albumDiscMenu", "Disc menu", "Plays or shuffles one disc of an album, or puts that disc next in the queue or at the end of it."),
        c("control.music.albumVersionOpen", "Open another version of the album", "Opens the page of another edition, language version or related soundtrack listed under Versions."),
        c("control.music.albumVersionMenu", "Edition options", "Compare an edition with this one, set it as your preferred edition, or hide it from the list."),
        c("control.music.albumCompareEditions", "Compare editions", "Opens a side by side comparison of two editions: number of songs, length, year, language and the songs only one of them has."),
        c("control.music.albumShowEditions", "Show other editions", "Switches the album page to its Versions list, where each edition can be opened or compared with this one."),
        c("control.music.albumCompareOpen", "Open the compared edition", "Closes the comparison and opens the page of the other edition."),
        c("control.music.albumCompareClose", "Close the comparison", "Closes the edition comparison window."),
        c("control.music.albumSetPreferred", "Set the preferred edition", "Marks an edition with a star on the Versions list as the one you prefer for this album. An album opened from a song, a shelf or a search result then opens on that edition; the Versions list and Compare still open the edition they name. Nothing is deleted."),
        c("control.music.albumHideEdition", "Hide an edition", "Hides an edition from the Versions list on this device. It can be restored from Hidden editions."),
        c("control.music.albumRestoreEdition", "Restore a hidden edition", "Shows an edition you hid in the Versions list again."),
        c("control.music.albumContributorSongs", "Songs of a contributor", "Opens a list of the songs of this album a credited person is credited on."),
        c("control.music.albumContributorOpen", "Open the contributor page", "Closes the list and opens the page of the credited person with the role they have on this album."),
        c("control.music.albumContributorClose", "Close the contributor list", "Closes the list of songs a contributor is credited on."),
        c("control.music.albumFilmCard", "Open the film of this soundtrack", "Opens the page of the film this album is the soundtrack of."),
        c("control.music.albumGoToArtist", "Go to the album artist", "Opens the page of the artist of this album.", aliases: ["open artist"]),
        c("control.music.albumGoToFilm", "Go to the film", "Opens the page of the film this soundtrack album belongs to."),
        c("control.music.albumViewCredits", "View album credits", "Switches the album page to the Credits tab, where people are grouped by what they did."),
        c("control.music.albumExport", "Export the tracklist", "Saves the song list of this album as a plain text or CSV file, after you choose where."),
        c("control.music.albumRefresh", "Refresh album details", "Reads the details, credits and songs of this album again."),
        c("control.music.albumArtworkPrevious", "Previous album picture", "Shows the previous picture of the album in the artwork window, such as the back cover or the booklet."),
        c("control.music.albumArtworkNext", "Next album picture", "Shows the next picture of the album in the artwork window, such as the back cover or the booklet."),
        c("control.music.albumArtworkPage", "Choose an album picture", "Opens one of the small pictures of the album in the strip below the large picture in the artwork window."),
        c("control.music.albumViewArtwork", "View album artwork", "Opens the artwork window with the cover and the other pictures of this album that are available."),
        c("control.music.albumAddToPlaylist", "Add the album to a playlist", "Chooses a playlist to add every song of this album to."),
        c("control.music.albumDownload", "Download the album", "Downloads every song of this album that the source lets you keep offline."),
        c("control.music.albumInformation", "Album information", "Switches the album page to the About tab with the label, date, catalogue number and other facts of this release."),
        c("control.music.albumPersonal", "Your rating and notes", "Opens a window for your own rating, collection tags and notes about this album, kept on this device only."),
        c("control.music.albumPersonalClose", "Close your rating and notes", "Closes the window of your own rating, tags and notes without saving changes."),
        c("control.music.albumPersonalSave", "Save your rating and notes", "Saves your rating, collection tags and notes for this album on this device and closes the window."),
        c("control.music.albumRatingStar", "Rate the album", "Gives the album one to five stars. Choosing the same star again removes your rating."),
        c("control.music.albumTagsField", "Collection tags", "Type your own tags for this album, separated by commas, to group it in your own way."),
        c("control.music.albumNotesField", "Notes about the album", "Write your own notes about this album. They stay on this device."),
        c("control.music.albumSelectToggle", "Select songs of the album", "Turns on choosing several songs of this album at once, or turns it off again."),
        c("control.music.albumSelectAll", "Select or clear all songs", "Chooses every song of this album, or clears the choice when all are already chosen."),
        c("control.music.albumSelectPlayNext", "Play the chosen songs next", "Puts the chosen songs next in the queue, in album order."),
        c("control.music.albumSelectQueue", "Add the chosen songs to the queue", "Adds the chosen songs to the end of the queue, in album order."),
        c("control.music.albumSelectPlaylist", "Add the chosen songs to a playlist", "Chooses a playlist to add the chosen songs to."),
        c("control.music.albumSelectLike", "Like the chosen songs", "Adds every chosen song of this album that is not liked yet to Liked Songs. Songs you already liked stay liked."),
        c("control.music.albumRadioButton", "Start a radio from the album", "Starts a station seeded from songs spread over the whole album, not only its first song, and plays it through the normal queue."),
        c("control.music.albumTracksRetry", "Try loading the missing songs again", "Asks the source again for the songs of this album that could not be loaded, when the tracklist is incomplete."),
        c("control.music.albumPlayUnplayed", "Play the songs you have not played", "Plays the songs of this album that have no counted play in your history, in album order."),
    ]
}
