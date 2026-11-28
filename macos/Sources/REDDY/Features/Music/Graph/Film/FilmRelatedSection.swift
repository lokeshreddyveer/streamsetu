import SwiftUI

/// Connected shelves: related films with the reason for each, other forms of the film (dubbed editions and other names, only where the graph states
/// them), more films by the director, more music from the composer, and soundtracks of the cast's other films. Each shelf loads when it comes
/// near the screen and is hidden when it finds nothing.
struct MusicFilmRelatedSection: View {
    let model: MusicFilmGraphModel
    let hub: MusicHub
    @Environment(\.musicLayoutClass) private var cls

    var body: some View {
        let width = MusicGraphCardWidth.width(for: cls)
        LazyVStack(alignment: .leading, spacing: MusicSpace.lg) {
            versions
            MusicGraphShelf(title: Localized.string("Related films"), phase: model.section(MusicFilmSectionKey.related).phase, itemCount: model.related.count, itemWidth: width,
                            posterAspect: MusicGraphCardMetrics.posterAspect, textLines: 3, onAppear: { model.loadLazy(MusicFilmSectionKey.related) }) {
                ForEach(model.related) { f in filmCard(f, width: width) }
            }
            MusicGraphShelf(title: Localized.string("More films by the director"), phase: model.section(MusicFilmSectionKey.directorFilms).phase, itemCount: model.directorFilms.count,
                            itemWidth: width, posterAspect: MusicGraphCardMetrics.posterAspect, textLines: 3, onAppear: { model.loadLazy(MusicFilmSectionKey.directorFilms) }) {
                ForEach(model.directorFilms) { f in filmCard(f, width: width) }
            }
            MusicGraphShelf(title: Localized.string("More music from the composer"), phase: model.section(MusicFilmSectionKey.composerMusic).phase, itemCount: model.composerMusic.count,
                            itemWidth: width, textLines: 3, onAppear: { model.loadLazy(MusicFilmSectionKey.composerMusic) }) {
                ForEach(model.composerMusic) { a in albumCard(a, width: width, reason: a.via.map { Localized.string("Music by %1$@", $0) }) }
            }
            MusicGraphShelf(title: Localized.string("Soundtracks with this cast"), phase: model.section(MusicFilmSectionKey.castMusic).phase, itemCount: model.castMusic.count,
                            itemWidth: width, textLines: 3, onAppear: { model.loadLazy(MusicFilmSectionKey.castMusic) }) {
                ForEach(model.castMusic) { a in albumCard(a, width: width, reason: a.via.map { Localized.string("With %1$@", $0) }) }
            }
        }
    }

    /// Dubbed editions and other names of this film, from real edges and aliases only. Two films of one title are never listed here.
    @ViewBuilder private var versions: some View {
        let v = model.versions
        if !v.isEmpty {
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                Text(verbatim: Localized.string("Also known as and dubbed versions")).font(Typography.title).accessibilityAddTraits(.isHeader)
                ForEach(v) { item in
                    switch item.kind {
                    case .dubbedAlbum:
                        Button { if let a = item.album { hub.open(a) } } label: {
                            Label(item.language.map { Localized.string("%1$@ soundtrack, dubbed in %2$@", item.text, $0) } ?? Localized.string("%@ soundtrack, dubbed", item.text), systemImage: "waveform")
                        }
                        .musicButton(.tertiary, size: .compact, accentText: true).atlas("control.music.filmDubbedVersion")
                    case .alias:
                        Text(verbatim: item.language.map { Localized.string("%1$@ (%2$@)", item.text, $0) } ?? item.text)
                            .musicText(.body).foregroundStyle(ColorTokens.textSecondary)
                    }
                }
            }
        }
    }

    private func filmCard(_ f: MusicFilmRelatedItem, width: CGFloat) -> some View {
        MusicGraphFilmCard(title: f.name, year: f.year, subtitle: nil, imageRef: f.imageRef, reason: MusicFilmWording.reasonLine(f.reasons), width: width, entity: f.film) { hub.open(f.film) }
    }

    private func albumCard(_ a: MusicFilmAlbumItem, width: CGFloat, reason: String?) -> some View {
        MusicGraphAlbumCard(title: a.name, subtitle: MusicFilmWording.albumCaption(a, edition: a.film != nil ? model.edition(of: a) : nil), imageRef: a.imageRef, reason: reason, width: width, entity: a.album) { hub.open(a.album) }
    }
}
