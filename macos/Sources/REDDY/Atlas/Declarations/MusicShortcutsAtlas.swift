import Foundation

/// The keys that work inside Music, from Features/Music/MusicShortcuts.swift (the in-app table and the optional global hotkeys) and MusicMainView's hidden buttons. They work while a Music window has focus
/// and you are not typing in a field. Command is the modifier on a Mac.
enum AtlasMusicShortcuts {
    private static func k(_ id: String, _ title: String, _ summary: String, _ keys: String, aliases: [String] = [], related: [String] = []) -> AtlasEntry {
        .make(id, .shortcut, title, summary, path: ["Keyboard", "Music"], reach: .none, aliases: aliases, platforms: .mac, shortcut: keys.isEmpty ? nil : keys, related: related, reviewed: true)
    }

    static let all: [AtlasEntry] = [
        k("shortcut.music.nextPrev", "Next and previous song", "Command Right Arrow plays the next song and Command D goes to the previous one. Inside Music these replace the Playback menu's live TV keys.", "⌘→ / ⌘D",
          aliases: ["next song shortcut", "skip song with keyboard", "previous song key", "next track key", "skip track"], related: ["shortcut.music.roomLock"]),
        k("shortcut.music.shuffleRepeat", "Shuffle and repeat keys", "Command S turns shuffle on or off and Command R cycles repeat (off, all, one). Note that Command R is repeat in Music; refresh is F5.", "⌘S / ⌘R", aliases: ["shuffle key", "repeat key", "cmd r repeat", "toggle shuffle with keyboard"], related: ["shortcut.music.refresh"]),
        k("shortcut.music.like", "Like or unlike the playing song", "Command L likes or unlikes the song that is playing. It is your own choice, so it still works in a listening room.", "⌘L", aliases: ["like with keyboard", "heart song shortcut", "favourite song key"]),
        k("shortcut.music.mute", "Mute", "Shift Command M mutes or unmutes Music.", "⇧⌘M", aliases: ["mute music key", "mute shortcut"]),
        k("shortcut.music.volumeKeys", "Volume keys", "Command > and Command < change the volume in 5 percent steps, and so do the Up and Down arrow keys when nothing else is using them. Command . and Command , also work.", "⌘> / ⌘<", aliases: ["volume up key", "volume down key", "music volume shortcut", "louder with keyboard"]),
        k("shortcut.music.seekKeys", "Skip ten seconds", "The Left and Right arrow keys skip back or forward 10 seconds, when focus is not in a list, slider or menu that uses the arrows.", "← / →", aliases: ["seek with arrow keys", "skip 10 seconds music", "rewind song"]),
        k("shortcut.music.playPause", "Play or pause", "Space (or ;) plays or pauses when you are not typing. Option Space works even while you type, and global hotkeys can do it from any app.", "Space / ⌥Space", aliases: ["play pause key", "spacebar music", "pause music with keyboard"], related: ["shortcut.music.optionSpace"]),
        k("shortcut.music.refresh", "Refresh the page", "F5 reloads the page you are on in Music. Command R is repeat, not refresh.", "F5", aliases: ["refresh the page in music", "reload music", "reload page"], related: ["shortcut.music.shuffleRepeat"]),
        k("shortcut.music.toggleNowPlaying", "Open or close Now Playing", "Command E opens the Now Playing view or goes back out of it.", "⌘E", aliases: ["now playing key", "toggle now playing", "open now playing"]),
        k("shortcut.music.zoom", "Zoom Music", "Command + and Command - make Music bigger or smaller and Command 0 puts it back to actual size.", "⌘+ / ⌘- / ⌘0", aliases: ["make music bigger", "zoom in music", "text too small in music", "music zoom"]),
        k("shortcut.music.theatreKey", "Theatre mode key", "F opens theatre mode, the large quiet view of the playing song. Escape closes it.", "F", aliases: ["cinema mode key", "full screen music key"], related: ["screen.music.theatre"]),
        k("shortcut.music.optionSpace", "Option Space plays or pauses (works while typing)", "The play button's own shortcut: Option Space plays or pauses even when the cursor is in a text field.", "⌥Space", aliases: ["option space", "alt space", "play pause while typing"]),
        k("shortcut.music.forward", "Forward and back between pages", "Command ] goes forward to the page you came back from, and Command [ goes back. Inside Music these replace the Playback menu's channel keys.", "⌘] / ⌘[", aliases: ["forward in music", "cmd ]", "go forward"], related: ["control.music.backPill"]),
        k("shortcut.music.search", "Search keys in Music", "Command F goes to the Music Search page and puts the cursor in its field. Command K opens the quick-search palette and Command K again closes it. Elsewhere in the app Command F only moves the cursor to the screen's own search box.", "⌘F / ⌘K",
          aliases: ["search music shortcut", "command palette", "quick search music"], related: ["control.music.palette"]),
        k("shortcut.music.queueUndo", "Undo and redo in the queue", "Command Z undoes the last queue change (a removed, cleared or moved song) and Shift Command Z redoes it, while the queue has focus.", "⌘Z / ⇧⌘Z", aliases: ["undo queue", "redo queue", "bring back removed song"], related: ["control.music.queueUndo", "control.music.queueRedo"]),
        k("shortcut.music.selectAll", "Select all songs", "Command A selects every song of the list while you are selecting songs.", "⌘A", aliases: ["select all in a song list"], related: ["control.music.listSelect"]),
        k("shortcut.music.globalHotkeys", "Global hotkeys", "Eleven optional system-wide hotkeys, off until you turn them on in Settings, Playback, Player, Global hotkeys: Control Option Space plays or pauses, Control Option Right and Left skip to the next and previous song, Up and Down change the volume, Page Up and Page Down seek, Home shows the app. Mute, shuffle and repeat have no key until you set one. A key needs Control, Option or Command unless it is an F key; media keys are not allowed.",
          "⌃⌥Space", aliases: ["system wide hotkeys", "control music from another app", "global shortcuts for music", "media keys"], related: ["setting.music.globalHotkeys"]),
        k("shortcut.music.roomLock", "Keys in a listening room", "In a listening room play or pause, skip, next, previous, shuffle and repeat follow the host and are ignored for guests. Volume, mute and like stay yours.", "", aliases: ["guest controls locked", "why cant i pause in a room", "listen together keys"], related: ["screen.music.room"]),
    ]
}
