import SwiftUI

// COMPOSER / MUSIC DIRECTOR: popular compositions, soundtracks, albums, films, singers collaborated with, lyricists collaborated with, related composers.
extension MusicPersonSectionsView {
    @ViewBuilder func composerSection(_ s: MusicPersonSection) -> some View {
        switch s.id {
        case .popularCompositions: songList(s)
        case .soundtracks: albumShelf(s)
        case .films: filmShelf(s)
        case .singersWorkedWith, .lyricistsWorkedWith, .relatedComposers: peopleShelf(s)
        default: sharedSection(s)
        }
    }
}
