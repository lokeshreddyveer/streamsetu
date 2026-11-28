import Foundation

/// Atlas entries for the controls of the rewritten Listen Now. The controls that survived keep their old ids (control.music.homePlayRecent, homeShuffleLiked,
/// homeStartRadio, homeOpenLibrary, homeContinueCard, homeHeroPlay, homeHeroOpen); only the new controls are declared here.
enum AtlasMusicHomeRewrite {
    private static func c(_ id: String, _ title: String, _ summary: String, _ path: [String]) -> AtlasEntry {
        .make(id, .control, title, summary, path: path, platforms: .mac)
    }

    static let all: [AtlasEntry] = [
        c("control.music.homeRefresh", "Refresh Listen Now", "The round glass button beside the greeting at the top of Music, Listen Now (Command R does the same): draws a new shuffle of the page, with a new hero, new mixes and new picks from what you play. The page keeps its place while it recomposes.", ["Music", "Listen Now"]),
        c("control.music.homeTile", "Listen Now tile", "A cover tile on a shelf of Music, Listen Now. A song or a mix plays when you click it; an album, artist, playlist or film opens. Point at it for the play button; right-click for the menu.", ["Music", "Listen Now"]),
        c("control.music.homeTilePlay", "Play a mix", "The round play button that appears on a mix tile in Made for you when you point at it: plays the whole mix. Right-click the tile to shuffle it, play it next or add it to the queue.", ["Music", "Listen Now", "Made for you"]),
        c("control.music.homeWelcomeExplore", "Explore charts", "On the welcome card of Music, Listen Now, shown while you have not played anything yet: opens Explore with the charts.", ["Music", "Listen Now"]),
        c("control.music.homeWelcomeRadio", "Start a radio", "On the welcome card of Music, Listen Now, shown while you have not played anything yet: opens Radio to start a station.", ["Music", "Listen Now"]),
        c("control.music.homeWelcomeImport", "Import or open a link", "On the welcome card of Music, Listen Now, shown while you have not played anything yet: opens the import sheet, where you can bring in a playlist or paste a music link.", ["Music", "Listen Now"]),
        c("control.music.homeTopTrackRow", "Top track row", "A song in the Your top tracks list of Music, Listen Now: click the cover or the title to play the list from this song. The artist names open the artist, and on a wide window the album name opens the album.", ["Music", "Listen Now", "Your top tracks"]),
        c("control.music.homeTopTrackLike", "Like a top track", "The heart at the end of a row in Your top tracks on Music, Listen Now: likes or unlikes the song.", ["Music", "Listen Now", "Your top tracks"]),
        c("control.music.homeTopTrackMore", "More actions for a top track", "The three dots at the end of a row in Your top tracks on Music, Listen Now: the song menu (play next, add to queue, add to a playlist, go to artist or album).", ["Music", "Listen Now", "Your top tracks"]),
        c("control.music.homeMoreExplore", "Explore more: Explore", "The capsule at the foot of Music, Listen Now that opens Explore.", ["Music", "Listen Now"]),
        c("control.music.homeMoreRadio", "Explore more: Radio", "The capsule at the foot of Music, Listen Now that opens Radio.", ["Music", "Listen Now"]),
        c("control.music.homeMoreLibrary", "Explore more: Your Library", "The capsule at the foot of Music, Listen Now that opens Your Library.", ["Music", "Listen Now"]),
    ]
}
