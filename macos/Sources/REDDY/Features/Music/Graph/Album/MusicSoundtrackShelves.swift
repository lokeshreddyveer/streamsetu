import SwiftUI

// The related-soundtracks shelf. It starts its own load when it comes near the screen, shows a skeleton of the final card geometry while it loads, shows
// its first cards as soon as they arrive, and draws nothing when it finishes empty. Every card says why it is there in one line.

@MainActor private struct ShelfContext {
    let page: MusicSoundtrackPageModel
    let width: CGFloat
    var hub: MusicHub { page.hub }
    func filmCaption(_ f: MusicSoundtrackFilm?) -> String? {
        guard let f else { return nil }
        return Localized.string("From %@", f.year.map { "\(f.title) (\($0))" } ?? f.title)
    }
    func albumCard(_ a: MusicSoundtrackAlbum) -> some View {
        MusicGraphAlbumCard(title: a.title, subtitle: filmCaption(a.film) ?? a.year.map(String.init), imageRef: a.imageRef, reason: a.reason.words,
                            tag: nil, width: width, entity: a.id) { hub.open(a.id) }
    }
}


struct MusicSoundtrackRelatedSection: View {
    let page: MusicSoundtrackPageModel
    @Environment(\.musicLayoutClass) private var layoutClass

    var body: some View {
        let ctx = ShelfContext(page: page, width: MusicGraphCardWidth.width(for: layoutClass))
        let albums = page.shelves.related
        MusicGraphShelf(title: page.displayHeader?.film != nil || page.displayHeader?.isSoundtrackType == true ? Localized.string("Related soundtracks") : Localized.string("Related albums"), phase: page.phase(MusicSoundtrackKey.related), itemCount: albums.count, itemWidth: ctx.width, textLines: 4,
                        onAppear: { page.ensure(MusicSoundtrackKey.related) }) {
            ForEach(albums, id: \.id) { ctx.albumCard($0) }
        }
    }
}

