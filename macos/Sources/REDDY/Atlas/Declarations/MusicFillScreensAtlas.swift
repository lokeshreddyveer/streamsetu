import Foundation

// Atlas entries for the filled screens: the connected shelves, typed links on every song surface, entity search, smart playlists, grouped downloads.
// `AtlasMusicFillScreens.all` is added to `Atlas.declared` by the Atlas patch.
enum AtlasMusicFillScreens {
    static let all: [AtlasEntry] = [
        .make("screen.music.facet", .screen, "Language, era, region or genre page", "Opens from a language, era, region or genre tile or link. Shows the music directors, singers, lyricists, film stars, films and soundtracks of it, plus whatever your graph has tagged with it.",
              path: ["Music", "Explore", "Languages and eras"], reach: .destination("music"), aliases: ["hindi page", "telugu page", "tamil page", "1950s page", "era page"], platforms: .mac),
        .make("screen.music.smartPlaylist", .screen, "Smart playlist", "On Repeat, Recently added, Never played or Forgotten favourites: a list built on this Mac from what you play and save. Play it, shuffle it or save it as a playlist.",
              path: ["Music", "Your library", "Playlists", "Made for you"], reach: .destination("music"), aliases: ["on repeat", "recently added", "never played", "forgotten favourites"], platforms: .mac),
        .make("control.music.songMenusGoToMenu", .control, "Go to", "In every song menu, a submenu that opens the song, its albums, each artist, the film, the music director, the singers, the lyricist and the actors, each on its own page.",
              path: ["Music", "Song menu", "Go to"], aliases: ["go to film", "go to music director", "open the singer", "open the album"], platforms: .mac),
        .make("control.music.songMenusGoToConnected", .control, "Go to a connected page", "An item of the Go to submenu: opens the page of that song, album, artist, film or person.",
              path: ["Music", "Song menu", "Go to"], aliases: ["go to artist", "go to actor", "go to lyricist"], platforms: .mac),
        .make("control.music.songMenusFindCredits", .control, "Find film and music director", "In the Go to submenu while the film, music director and cast of a song are still unknown: asks the sources for them and the submenu fills in.",
              path: ["Music", "Song menu", "Go to"], aliases: ["find credits"], platforms: .mac),
        .make("control.music.rowContextLink", .control, "Music director, film or actor link on a song row", "Under the artists of a song row: the music director, the film and the lead actors as links; each opens its own page.",
              path: ["Music", "Song rows"], aliases: ["film link", "music director link", "cast link"], platforms: .mac),
        .make("control.music.nowPlayingTitleLink", .control, "Now Playing song title", "The title in the Now Playing panel is a link: it opens the song page with its albums, artists by role and film.",
              path: ["Music", "Now Playing"], aliases: ["open the playing song"], platforms: .mac),
        .make("control.music.nowPlayingLinkChip", .control, "Now Playing link chip", "Chips under the Now Playing title for the film, music director, singers, lyricist, actors and albums of the playing song; each opens that page.",
              path: ["Music", "Now Playing"], aliases: ["playing film", "playing music director"], platforms: .mac),
        .make("control.music.searchEntityFilter", .control, "Search type filter", "Chips above the connected search results: All, People, Music directors, Singers, Lyricists, Actors, Films, Soundtracks, Albums, Songs and Playlists.",
              path: ["Music", "Search", "Filters"], aliases: ["filter search by film", "filter search by singer"], platforms: .mac),
        .make("control.music.searchDidYouMean", .control, "Did you mean", "When a search looks misspelled, the closest known name appears as a link; choosing it searches for that name.",
              path: ["Music", "Search"], aliases: ["spelling suggestion"], platforms: .mac),
        .make("control.music.searchBestMatchRadio", .control, "Start radio from the best match", "On the Best match card of a person or film: starts a radio from the songs credited to them or from the film.",
              path: ["Music", "Search", "Best match"], aliases: ["radio from the singer", "radio from the composer"], platforms: .mac),
        .make("control.music.radioEntityStart", .control, "Start radio from a name or film", "On the Radio page: starts a radio seeded by a music director, singer, actor or soundtrack. The station says what it plays.",
              path: ["Music", "Radio", "From names and films"], aliases: ["music director radio", "singer radio", "actor radio", "soundtrack radio"], platforms: .mac),
        .make("control.music.downloadsGroupOpen", .control, "Open a downloads group", "On the Downloads page, the film or album heading above its downloaded songs opens that film or album page.",
              path: ["Music", "Downloads"], aliases: ["downloaded album", "downloaded film"], platforms: .mac),
        .make("control.music.smartPlaylistHide", .control, "Hide a smart playlist", "Hides a smart playlist (On Repeat, Recently added, Never played or Forgotten favourites) from Your library for good.",
              path: ["Music", "Your library", "Playlists", "Made for you"], aliases: ["dismiss on repeat"], platforms: .mac),
        .make("control.music.smartPlaylistSave", .control, "Save a smart playlist as a playlist", "Saves the songs of the smart playlist you are viewing as a normal playlist in Your library.",
              path: ["Music", "Your library", "Playlists", "Made for you"], aliases: ["keep on repeat"], platforms: .mac),
        .make("control.music.facetSearch", .control, "Search for the language or era", "On a language, era, region or genre page: opens a search for its name.",
              path: ["Music", "Explore", "Languages and eras"], aliases: [], platforms: .mac),
        .make("control.music.queueRemoveAutoplayGroup", .control, "Remove autoplay songs", "In the queue, removes the songs autoplay added as one group. Undo (the toast, or Command-Z) brings them back.",
              path: ["Music", "Queue"], aliases: ["clear autoplay", "remove suggested songs"], platforms: .mac)
    ]
}
