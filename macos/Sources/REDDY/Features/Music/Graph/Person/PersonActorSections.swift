import SwiftUI

// ACTOR: filmography, popular movies, movie soundtracks, popular songs from their movies, co-stars, directors worked with, related cinema.
extension MusicPersonSectionsView {
    @ViewBuilder func actorSection(_ s: MusicPersonSection) -> some View {
        switch s.id {
        case .filmography: MusicFilmographyGrid(hub: hub, section: s, memoryKey: memoryKey, cardWidth: cardWidth)
        case .popularMovies, .relatedCinema: filmShelf(s)
        case .movieSoundtracks: albumShelf(s)
        case .songsFromMovies: songList(s)
        case .coStars, .directorsWorkedWith: peopleShelf(s)
        default: sharedSection(s)
        }
    }
}
