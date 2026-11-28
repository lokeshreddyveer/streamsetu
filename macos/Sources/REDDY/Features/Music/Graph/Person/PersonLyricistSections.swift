import SwiftUI

// LYRICIST: songs written, albums, films, composers, singers, frequent collaborators.
extension MusicPersonSectionsView {
    @ViewBuilder func lyricistSection(_ s: MusicPersonSection) -> some View {
        switch s.id {
        case .songsWritten: songList(s)
        case .composers, .singers, .frequentCollaborators: peopleShelf(s)
        default: sharedSection(s)
        }
    }
}
