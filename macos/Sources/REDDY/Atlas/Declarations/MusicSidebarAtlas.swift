import Foundation

/// Atlas entries for the controls the Music side panel gained: the queue's search, selection and sections, the Now Playing cover and menu, the audio settings, the panel's resize
/// handle and tab keys, the lyrics alignment, the seek bar's time switch and the Related tab's links.
enum AtlasMusicSidebar {
    private static func c(_ id: String, _ title: String, _ summary: String, _ path: [String], aliases: [String] = []) -> AtlasEntry {
        .make(id, .control, title, summary, path: path, aliases: aliases, platforms: .mac)
    }

    private static let queue = ["Music", "Queue"]
    private static let nowPlaying = ["Music", "Now Playing"]

    static let all: [AtlasEntry] = [
        // The queue
        c("control.music.queueSearchToggle", "Search the queue", "Opens a search box above the queue list. Type words from a title, an artist or an album to see only the matching songs; clear the box to see the whole queue again.", queue, aliases: ["find a song in the queue", "filter the queue"]),
        c("control.music.queueSearchClear", "Clear the queue search", "Empties the queue search box so the whole queue shows again.", queue),
        c("control.music.queueSelectStart", "Select songs in the queue", "Turns on selecting in the queue: tap songs to tick them, then remove them together or add them to a playlist. Press it again, or Done, to stop selecting.", queue, aliases: ["select several songs", "multi-select the queue"]),
        c("control.music.queueSelectRow", "Select this queue song", "In a queue row's menu: starts selecting with this song ticked.", queue),
        c("control.music.queueSelectAll", "Select every upcoming song", "While selecting in the queue: ticks every song after the one playing.", queue),
        c("control.music.queueSelectRemove", "Remove the selected songs", "While selecting in the queue: takes the ticked songs out of the queue in one step. The playing song stays. Undo brings them back.", queue, aliases: ["bulk remove from queue"]),
        c("control.music.queueSelectToPlaylist", "Add the selected songs to a playlist", "While selecting in the queue: opens Add to Playlist with the ticked songs.", queue),
        c("control.music.queueSelectDone", "Finish selecting in the queue", "Leaves selecting mode in the queue and clears the ticks.", queue),
        c("control.music.queueOptionsMenu", "Queue options menu", "The three-dot button above the queue: jump to the playing song, put a shuffled queue back in its original order, or go back to the queue that was replaced.", queue),
        c("control.music.queueJumpCurrent", "Jump to the playing song in the queue", "Scrolls the queue back to the song that is playing. The Current button also appears by itself when you have scrolled away from it.", queue, aliases: ["go to current song in queue", "back to now playing in queue"]),
        c("control.music.queueRestoreOrder", "Restore the original queue order", "Turns shuffle off, which puts the queue back in the order it had before it was shuffled. Songs you added by hand stay where you put them.", queue, aliases: ["unshuffle the queue", "undo shuffle order"]),
        c("control.music.queueBackPrevious", "Back to the previous queue", "Brings back the queue that your last click replaced, at the song and place you left it.", queue),
        c("control.music.queueMoveBottom", "Move a queue song to the bottom", "In a queue row's menu: moves the song to the end of the queue.", queue),
        c("control.music.queueStopAfterRow", "Stop after this queue song", "In a queue row's menu: playback stops when this very row has played and the next song waits. Another copy of the same song in the queue does not stop it. Choose it again to take it back.", queue, aliases: ["stop after selected song"]),

        // Now Playing
        c("control.music.nowPlayingArtwork", "Now Playing cover", "Click the cover in the side panel to open the full player. Right-click it to see the cover large, go to the album, or choose the picture.", nowPlaying),
        c("control.music.nowPlayingViewArtwork", "View the cover large", "Opens the cover of the playing song in its own window, where you can zoom in.", nowPlaying),
        c("control.music.nowPlayingAudioSettings", "Audio settings", "Opens the audio settings: volume normalising, crossfade, tempo, pitch and reverb, the equalizer, the stream's signal information, the output device and the sleep timer.", nowPlaying, aliases: ["crossfade", "normalise volume", "signal information"]),
        c("control.music.nowPlayingModeMenu", "Now Playing layout", "Chooses how much of the Now Playing tab the cover takes: Compact, Balanced or Immersive. The choice is remembered.", nowPlaying),
        c("control.music.nowPlayingMode", "Choose a Now Playing layout", "Sets the Now Playing tab to Compact (small cover, more room for lyrics), Balanced or Immersive (the cover fills the width).", nowPlaying, aliases: ["compact layout", "immersive layout"]),
        c("control.music.nowPlayingUpNext", "Up next preview", "Shows the next song in the queue under the controls. Press it to open the Queue tab.", nowPlaying),
        c("control.music.playerTimeToggle", "Time left or total length", "The time at the right of the seek bar: press it to switch between the time left and the song's whole length. The choice is remembered.", nowPlaying, aliases: ["remaining time", "total time"]),

        // Audio settings
        c("control.music.audioNormalize", "Normalise volume", "In the audio settings: brings songs to a similar loudness. The same switch is in Music settings.", nowPlaying),
        c("control.music.audioCrossfade", "Crossfade length", "In the audio settings: how many seconds one song fades into the next. Off means no crossfade.", nowPlaying),
        c("control.music.audioEffectsOpen", "Open tempo, pitch and reverb", "In the audio settings: goes to the page with the presets, tempo, pitch and reverb.", nowPlaying),
        c("control.music.audioEqualizerOpen", "Open the equalizer", "In the audio settings: goes to the equalizer page.", nowPlaying),
        c("control.music.audioSignalOpen", "Open signal information", "In the audio settings: shows what the playing stream reports, such as codec, bitrate and sample rate. Only what is known is listed.", nowPlaying),
        c("control.music.audioBack", "Back to the audio settings", "From the signal information page: goes back to the audio settings.", nowPlaying),

        // The panel
        c("control.music.panelResize", "Resize the details panel", "Drag the left edge of the side panel to make it wider or narrower, between 280 and 500 points. Double-click the edge to go back to the automatic width. The width is remembered.", ["Music", "Details panel"], aliases: ["panel width", "make the sidebar wider"]),
        c("control.music.panelTabShortcut", "Open a panel tab with the keyboard", "Command-Option-1 to 5 open the side panel on Now Playing, Queue, Lyrics, Related or Credits. Press the key again on the tab that is showing to close the panel.", ["Music", "Details panel"], aliases: ["keyboard shortcut for queue", "keyboard shortcut for lyrics"]),

        // Lyrics and Related
        c("control.music.lyricsAlignment", "Lyrics alignment", "Cycles where the lyric lines sit: automatic (a duet's second voice on the right), left, centred or right. The choice is remembered.", ["Music", "Lyrics"], aliases: ["centre the lyrics", "align the lyrics"]),
        c("control.music.relatedSongRadio", "Start a song radio", "In the Related tab: starts a radio from the song that is playing. Nothing is queued until you press it.", ["Music", "Related"]),
        c("control.music.relatedVersions", "Other versions and recordings", "In the Related tab: opens the song's page, where its other versions and recordings are listed.", ["Music", "Related"]),
        c("control.music.relatedMoreFrom", "More from a music director, lyricist or film", "In the Related tab: opens the person's or the film's page for the song that is playing.", ["Music", "Related"]),

        // Players
        c("control.music.expandedPlayerRetry", "Retry in the full-window player", "Shown under the controls of the full-window player when the song could not be played: starts the same song again from where it was.", ["Music", "Expanded player"], aliases: ["try the song again"]),
        c("control.music.miniPlayerRetry", "Retry in the mini player", "Shown under the title of the mini player when the song could not be played: starts the same song again from where it was.", ["Music", "Mini player"], aliases: ["try the song again"]),
        c("control.music.lyricsStripRomanisation", "Show romanisation in the lyrics strip", "In the lyrics strip's style popover: shows the line written in Latin letters under the line being sung. It is the same switch as the side panel's lyrics toolbar.", ["Music", "Lyrics"], aliases: ["transliteration in the strip"]),
        c("control.music.miniPlayerEmptyBack", "Back to the app from an empty mini player", "Shown in the mini player when nothing is playing any more: shows the main window again so the person is never left with a bare floating panel.", ["Music", "Mini player"], aliases: ["leave the mini player"]),
    ]
}
