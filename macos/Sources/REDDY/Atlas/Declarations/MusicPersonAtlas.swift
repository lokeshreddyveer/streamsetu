import Foundation

/// Atlas entries for the person page of Music: a singer, composer, lyricist, actor, director or group, from the music graph.
enum AtlasMusicPerson {
    private static func c(_ id: String, _ title: String, _ summary: String) -> AtlasEntry {
        .make(id, .control, title, summary, path: ["Music", "Person"], platforms: .mac)
    }

    static let all: [AtlasEntry] = [
        .make("screen.music.person", .screen, "Music person page", "Opens from a singer, composer, lyricist, actor or director in the credits of a song, album or film. Shows their songs, albums and films for each role they really have, chosen with the role chips under the name. A duo or band lists its members when a source names them.",
              path: ["Music", "Person"], reach: .destination("music"), aliases: ["singer page", "composer page", "lyricist page", "actor page", "director page", "artist profile", "music director"], platforms: .mac),
        c("control.music.personRole", "Switch a person's role", "A person who works in more than one role shows a chip for each: for example Actor and Director. The chosen role decides which sections show, and Back returns to it."),
        c("control.music.personPlay", "Play a person", "Plays the top songs of the chosen role, such as a singer's top songs or the songs of an actor's films."),
        c("control.music.personShuffle", "Shuffle a person", "Plays the same songs in a shuffled order."),
        c("control.music.personFollow", "Follow a person", "Keeps the artist in Your library. Press again to unfollow. It appears when your music source has this artist."),
        c("control.music.personRadio", "Start radio from a person", "Starts a radio of songs like the person's top song."),
        c("control.music.personSongPlay", "Play one song of a person", "Plays that song. The queue is replaced only when you press this."),
        c("control.music.personSongOpen", "Open a song from a person page", "Opens the song's page."),
        c("control.music.personShowAll", "Show all of a section", "Expands a list of songs or films on a person page to show every entry."),
        c("control.music.personDidYouMean", "Did you mean another person", "Shown after a name search when two different people share the name. Each choice has a short line, such as a profession or year, to tell them apart."),
    ]
}
