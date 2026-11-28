import Foundation

/// Atlas entries for the artist page pills of Music: Songs, Albums, Films, Collaborators, Timeline, Your listening, About, the radio modes and the More menu.
enum AtlasMusicArtistPage {
    private static func c(_ id: String, _ title: String, _ summary: String, _ path: [String], _ aliases: [String]) -> AtlasEntry {
        .make("control.music." + id, .control, title, summary, path: path, aliases: aliases, platforms: .mac)
    }

    static let all: [AtlasEntry] = [
        c("artistPill", "Switch an artist page section", "On a person's page, the pills under the name (Overview, Songs, Albums, Films, Collaborators, Timeline, Your listening, About) switch what the page shows. A pill appears only when the person has something for it in the chosen role.", ["Music", "Artist"], ["artist tabs", "artist sections", "artist navigation"]),
        c("artistSongSearch", "Search an artist's songs", "In the Songs section of an artist page, a search box that narrows the list by song name, singers or film.", ["Music", "Artist", "Songs"], ["find artist song", "search songs by artist"]),
        c("artistSongLanguage", "Filter an artist's songs by language", "In the Songs section, shows only the songs in one language.", ["Music", "Artist", "Songs"], ["songs in telugu", "songs by language"]),
        c("artistSongDecade", "Filter an artist's songs by decade", "In the Songs section, shows only the songs of one decade.", ["Music", "Artist", "Songs"], ["songs of the 90s", "songs by decade"]),
        c("artistSongFilm", "Filter an artist's songs by film", "In the Songs section, shows only the songs from one film.", ["Music", "Artist", "Songs"], ["songs from a movie", "songs by film"]),
        c("artistSongSort", "Sort an artist's songs", "In the Songs section, sorts by title, newest, oldest, longest or, when you have played some of them, most played by you.", ["Music", "Artist", "Songs"], ["order songs", "sort by year"]),
        c("artistSongsPlay", "Play these songs", "In the Songs section, plays the songs left after your search and filters, in the list's order. At most 50 are queued; the page says how many match.", ["Music", "Artist", "Songs"], ["play filtered songs", "play all of these"]),
        c("artistSongsShuffle", "Shuffle these songs", "In the Songs section, shuffles the songs left after your search and filters. At most 50 are picked at random from them.", ["Music", "Artist", "Songs"], ["shuffle filtered songs", "shuffle these"]),
        c("artistSongsMore", "Show more songs", "In the Songs section, shows the next hundred songs of a long list.", ["Music", "Artist", "Songs"], ["more songs", "load more songs"]),
        c("artistYearClear", "Clear the year filter", "Removes the year chosen on the career timeline, so the Songs, Albums and Films lists show every year again.", ["Music", "Artist"], ["clear year", "remove year filter"]),
        c("artistAlbumType", "Filter albums by type", "In the Albums section, shows albums, soundtracks, singles and EPs, compilations or scores only.", ["Music", "Artist", "Albums"], ["soundtracks only", "singles only", "discography type"]),
        c("artistAlbumDecade", "Filter albums by decade", "In the Albums section, shows only the albums of one decade.", ["Music", "Artist", "Albums"], ["albums by decade"]),
        c("artistAlbumLayout", "Albums as grid or list", "In the Albums section, switches between a grid of covers and a plain list.", ["Music", "Artist", "Albums"], ["discography layout", "grid view", "list view"]),
        c("artistAlbumRow", "Open an album from the list", "In the Albums list view, opens the album or soundtrack.", ["Music", "Artist", "Albums"], ["open album"]),
        c("artistAlbumsMore", "Show more albums", "In the Albums section, shows the next sixty albums.", ["Music", "Artist", "Albums"], ["more albums"]),
        c("artistFilmIndustry", "Filter films by industry", "In the Films section, shows only the films of one film industry, such as Tollywood or Bollywood, worked out from the film's language.", ["Music", "Artist", "Films"], ["tollywood", "bollywood", "film industry"]),
        c("artistFilmDecade", "Filter films by decade", "In the Films section, shows only the films of one decade.", ["Music", "Artist", "Films"], ["films by decade"]),
        c("artistFilmsMore", "Show more films", "In the Films section, shows the next films of a long list.", ["Music", "Artist", "Films"], ["more films"]),
        c("artistCombine", "Combine with a collaborator", "In the Collaborators section, opens Combine with this artist and the chosen collaborator already picked, to find the songs the two made together.", ["Music", "Artist", "Collaborators"], ["songs together", "artist pair", "a and b songs"]),
        c("artistTimelineYear", "Open a year of the timeline", "In the Timeline section, shows only that year's songs, albums or films.", ["Music", "Artist", "Timeline"], ["career year", "filter by year"]),
        c("artistListeningMore", "Show more unplayed songs", "In Your listening, shows more of the artist's songs you have not played yet.", ["Music", "Artist", "Your listening"], ["more unplayed"]),
        c("artistAwardsMore", "Show more awards", "In the About section, shows more of the awards listed for the person.", ["Music", "Artist", "About"], ["more awards"]),
        c("artistExplore", "Explore songs by language or decade", "On the Overview of an artist page, opens the Songs section already filtered to a language or a decade.", ["Music", "Artist"], ["songs by language", "songs by decade", "explore catalog"]),
        c("artistRadioModes", "Radio modes", "In the header of an artist page, a menu of radio modes: artist essentials, deep cuts, the complete catalog, one language or decade, film music, recent songs, a kind of recording such as live or remixes, or songs you liked.", ["Music", "Artist", "Radio"], ["artist radio", "deep cuts", "essentials"]),
        c("artistRadioMode", "Start one radio mode", "Starts the chosen mode as a shuffled queue of at most 50 recordings of the artist.", ["Music", "Artist", "Radio"], ["artist essentials", "deep cuts radio", "catalog shuffle"]),
        c("artistMore", "More actions for an artist", "The ellipsis menu in an artist page header, with Play next, Add to queue, Create playlist, Copy link, Share and hiding the artist from recommendations.", ["Music", "Artist", "More"], ["artist menu", "more options"]),
        c("artistPlayNext", "Play the artist's top songs next", "In the artist's More menu, puts up to ten top songs next in the queue without interrupting what is playing.", ["Music", "Artist", "More"], ["queue artist next"]),
        c("artistAddToQueue", "Add the artist's top songs to the queue", "In the artist's More menu, adds up to ten top songs to the end of the queue.", ["Music", "Artist", "More"], ["queue artist songs"]),
        c("artistFavorite", "Favorite an artist", "In the header of an artist page, marks the person as a favorite on this Mac, or removes the mark. It is separate from Follow, needs no streaming account and changes nothing else.", ["Music", "Artist"], ["favourite artist", "heart artist", "like artist"]),
        c("artistCreatePlaylist", "Create a playlist from the artist", "In the artist's More menu, makes a new playlist of the artist's top songs (at most 50) in your library.", ["Music", "Artist", "More"], ["artist playlist", "save artist songs", "make playlist"]),
        c("artistCopyLink", "Copy the artist's link", "In the artist's More menu, copies a link to the artist to the clipboard.", ["Music", "Artist", "More"], ["share artist link", "copy artist link"]),
        c("artistShare", "Share the artist", "In the artist's More menu, opens the system share menu with a link to the artist.", ["Music", "Artist", "More"], ["share artist", "send artist"]),
        c("artistWebsite", "Open the artist's official website", "In the About section, opens the website the person lists as their own, in your browser.", ["Music", "Artist", "About"], ["artist website", "official site"]),
        c("artistMilestone", "Open a career milestone", "In the Timeline section, opens the album or film a milestone names, such as the earliest album or film found.", ["Music", "Artist", "Timeline"], ["career milestone", "earliest album", "earliest film"]),
        c("artistSongType", "Filter an artist's songs by type", "In the Songs section, shows only live, acoustic, remix, instrumental or featured songs. A type is offered only when the graph states it for some of the songs.", ["Music", "Artist", "Songs"], ["live songs", "acoustic songs", "remixes", "featured appearances"]),
        c("artistSongYearFrom", "Songs from a year", "In the Songs section, shows only songs released in this year or later.", ["Music", "Artist", "Songs"], ["songs since year", "year range start"]),
        c("artistSongYearTo", "Songs up to a year", "In the Songs section, shows only songs released in this year or earlier.", ["Music", "Artist", "Songs"], ["songs until year", "year range end"]),
        c("artistSongLiked", "Only songs you liked", "In the Songs section, shows only the artist's songs that you liked on this Mac.", ["Music", "Artist", "Songs"], ["liked songs of artist", "my liked songs"]),
        c("artistFilmCredit", "Filter films by credit", "In the Films section, shows only the films where the person has one credit, such as actor, director or music director.", ["Music", "Artist", "Films"], ["films as actor", "films as director", "films by credit"]),
        c("artistFilmDirector", "Filter films by director", "In the Films section, shows only the films one director made, from the director the graph states for each film. Offered only when the films have more than one director.", ["Music", "Artist", "Films"], ["films by director", "director filter"]),
        c("artistFilmGenre", "Filter films by genre", "In the Films section, shows only the films of one genre, from the genre the graph states for each film.", ["Music", "Artist", "Films"], ["films by genre", "genre filter"]),
        c("artistTopPlayed", "Play one of your most played songs", "In Your listening, plays a song from the most played list, followed by the rest of that list.", ["Music", "Artist", "Your listening"], ["play most played", "top played songs"]),
        c("artistFilmSoundtrack", "Films with a soundtrack", "In the Films section, shows only the films whose soundtrack album is in the artist's catalog.", ["Music", "Artist", "Films"], ["films with songs", "soundtrack films"]),
        c("combineOpenFilm", "Open a film from Combine", "In Combine, opens the page of a film that the combined songs come from.", ["Music", "Combine"], ["combine film", "films together"]),
        c("artistExclude", "Exclude or include an artist in recommendations", "In the artist's More menu, keeps the artist out of Home, radio and autoplay suggestions, or lets them back in. Songs you search for or open yourself still play.", ["Music", "Artist", "More"], ["hide artist", "block artist", "stop recommending"])
    ]
}
