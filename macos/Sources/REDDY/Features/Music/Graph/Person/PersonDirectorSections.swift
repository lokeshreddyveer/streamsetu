import SwiftUI

// DIRECTOR: filmography, film soundtracks, composers collaborated with, frequent cast, related films.
extension MusicPersonSectionsView {
    @ViewBuilder func directorSection(_ s: MusicPersonSection) -> some View {
        switch s.id {
        case .filmSoundtracks: albumShelf(s)
        case .composersCollaborated, .frequentCast: peopleShelf(s)
        case .relatedFilms: filmShelf(s)
        default: sharedSection(s)
        }
    }
}
