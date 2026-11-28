import Foundation

/// Atlas entries for the film info in Music: the actor page and the actor portraits of the compact film panel.
enum AtlasMusicFilm {
    static let all: [AtlasEntry] = [
        .make("screen.music.actor", .screen, "Music with an actor", "Opens from an actor in a film's cast. Shows the soundtrack albums of the actor's films that your music source has, with the film year and role, and a few songs from them.",
              path: ["Music", "Actor"], reach: .destination("music"), aliases: ["actor songs", "film cast music", "more with actor"], platforms: .mac),
        .make("control.music.filmActor", .control, "Open an actor", "In the film panel beside the player, a round portrait of a cast member. It opens that actor's page of soundtrack albums and songs.",
              path: ["Music", "Film info"], platforms: .mac)
    ]
}
