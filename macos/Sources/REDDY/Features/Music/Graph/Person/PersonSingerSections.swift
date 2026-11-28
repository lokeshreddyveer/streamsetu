import SwiftUI

// SINGER: top songs, albums, singles, film songs, collaborations, composers worked with, languages performed, related artists, playlists, radio.
extension MusicPersonSectionsView {
    @ViewBuilder func singerSection(_ s: MusicPersonSection) -> some View {
        switch s.id {
        case .topSongs, .filmSongs, .playbackSongs: songList(s)
        case .albums, .singles: albumShelf(s)
        case .collaborations, .composersWorkedWith, .relatedArtists: peopleShelf(s)
        case .languages: languageChips(s)
        case .playlists: playlistShelf(s)
        case .radio: radioCard(s)
        default: EmptyView()
        }
    }

    /// The languages the person sang in, with how many songs each. Pressing one shows only that language's songs and albums on this page; pressing it again
    /// shows everything.
    func languageChips(_ s: MusicPersonSection) -> some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            MusicSectionTitle(title: MusicPersonWording.sectionTitle(.languages, name: name))
            MusicChipFlow(spacing: MusicSpace.xs) {
                ForEach(s.entries) { e in
                    let on = languageFilter != nil && languageFilter == e.lang
                    Button {
                        if let go = exploreLanguage, let code = MusicPersonReader.languageCode(e.lang) { go(code) } else { languageFilter = on ? nil : e.lang }
                    } label: {
                        Text(verbatim: e.count.map { "\(e.name) · \($0)" } ?? e.name).musicText(.caption)
                    }
                    .musicButton(on ? .primary : .tertiary, size: .compact)
                    .accessibilityLabel(Localized.string("Show only %@", e.name)).accessibilityAddTraits(on ? .isSelected : [])
                    .atlas("control.music.personLanguageFilter")
                }
            }
        }
    }

    func playlistShelf(_ s: MusicPersonSection) -> some View {
        shelf(s) { e in
            MusicGraphAlbumCard(title: e.name, subtitle: e.count.map { Localized.string("%d songs here", $0) }, imageRef: MusicPersonImage.address(e.imageRef), width: cardWidth, entity: e.id) { hub.open(e.id) }
        }
    }

    /// "Start radio from <the top song>" on the existing radio engine.
    func radioCard(_ s: MusicPersonSection) -> some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            MusicSectionTitle(title: MusicPersonWording.sectionTitle(.radio, name: name))
            Button { Task { await playback.radio(MusicPersonPlaySource.choose(data)) } } label: {
                Label(MusicPersonWording.startRadioFrom(name), systemImage: "dot.radiowaves.left.and.right")
            }
            .musicButton(.secondary, size: .large).accessibilityLabel(MusicPersonWording.startRadioFrom(name)).atlas("control.music.personRadio")
        }
    }
}
