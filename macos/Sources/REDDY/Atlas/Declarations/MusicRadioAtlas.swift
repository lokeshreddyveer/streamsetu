import Foundation

/// Atlas entries for the Radio page: starting a station, the station that is playing, the thumbs, the cards and the station editor.
enum AtlasMusicRadio {
    private static func c(_ id: String, _ title: String, _ summary: String, _ path: [String]) -> AtlasEntry {
        .make(id, .control, title, summary, path: path, platforms: .mac)
    }

    static let all: [AtlasEntry] = [
        c("control.music.radioSeedField", "Start a station field", "Type an artist, a song, a genre or a language at the top of Radio. Suggestions appear as you type; Return starts a station from the words.", ["Music", "Radio"]),
        c("control.music.radioSeedStart", "Start the typed station", "Starts a station from what is typed in the field: a language you named, an artist or song your source finds, or the words themselves.", ["Music", "Radio"]),
        c("control.music.radioSeedClear", "Clear the station field", "Empties the Start a station field.", ["Music", "Radio"]),
        c("control.music.radioSeedSuggestion", "Pick a station suggestion", "A suggestion under the field: the typed words, a completion, an artist or a song. It starts a station from that item.", ["Music", "Radio"]),
        c("control.music.radioNowCard", "Now on radio card", "Shown at the top of Radio while a station plays: its cover, the song, what the station follows, its mode, thumbs, New station and Stop station.", ["Music", "Radio"]),
        c("control.music.radioNowSong", "Open the radio's song", "Opens the page of the song that the station is playing.", ["Music", "Radio"]),
        c("control.music.radioNowArtist", "Open the radio's artist", "Opens the artist of the song that the station is playing.", ["Music", "Radio"]),
        c("control.music.radioSeedChip", "Open what a station follows", "A chip for each seed of the station. An artist opens the artist, a song opens its album, a genre, language or mood runs that search.", ["Music", "Radio"]),
        c("control.music.radioMode", "Station mode", "Familiar plays mostly songs you already know, Mixed blends them with new ones, Discover plays mostly new songs. It applies to the next songs the station adds.", ["Music", "Radio"]),
        c("control.music.radioRetry", "Try the station again", "Shown when a station could not find songs to play. Asks its sources again.", ["Music", "Radio"]),
        c("control.music.radioThumbUp", "Thumbs up", "While a station plays: the artist and language of this song count for more on the station, and the song is added to your liked songs. Press again to take it back; the toast has Undo.", ["Music", "Radio", "Player"]),
        c("control.music.radioThumbDown", "Thumbs down", "While a station plays: skips the song and never plays it again on this station. The toast has Undo.", ["Music", "Radio", "Player"]),
        c("control.music.radioNotForAWhile", "Not for a while", "While a station plays: skips the song and keeps it off every station for 30 days. It does not touch your Never play list. The toast has Undo.", ["Music", "Radio", "Player"]),
        c("control.music.radioStationCard", "Play a station card", "Starts the station. A station that is playing shows a wave instead of the play button. Right-click your own stations to rename, edit, copy or delete them.", ["Music", "Radio"]),
        c("control.music.radioRename", "Rename a station", "Opens the station editor to change the station's name.", ["Music", "Radio"]),
        c("control.music.radioEditSeeds", "Edit what a station follows", "Opens the station editor to add or remove the artists, songs, genres or languages the station follows.", ["Music", "Radio"]),
        c("control.music.radioDuplicate", "Make a copy of a station", "Adds a copy of the station with the same seeds and mode but its own history and thumbs.", ["Music", "Radio"]),
        c("control.music.radioDelete", "Delete a station", "Removes the station and what it learned from your thumbs. It stops the radio if the station is playing.", ["Music", "Radio"]),
        c("control.music.radioEditName", "Station name", "The name shown on the station's card.", ["Music", "Radio", "Edit station"]),
        c("control.music.radioEditAddField", "Add to a station", "Type an artist, song, genre or language the station should also follow.", ["Music", "Radio", "Edit station"]),
        c("control.music.radioEditAdd", "Add the typed seed", "Adds what is typed to the station's seeds.", ["Music", "Radio", "Edit station"]),
        c("control.music.radioEditRemoveSeed", "Stop following a seed", "Removes the seed from the station. The last seed cannot be removed.", ["Music", "Radio", "Edit station"]),
        c("control.music.radioEditDone", "Finish editing a station", "Saves the name and closes the station editor.", ["Music", "Radio", "Edit station"])
    ]
}
