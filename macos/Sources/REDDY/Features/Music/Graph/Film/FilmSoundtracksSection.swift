import SwiftUI

/// The albums that are this film's music: matched ones only. An inferred match says how it was made; a dubbed edition says its language and sits
/// after the originals. Hidden when the film has none (the page then shows one quiet line, see `MusicFilmPage`).
struct MusicFilmSoundtracksSection: View {
    let model: MusicFilmGraphModel
    let hub: MusicHub
    /// Which shelves this draws: all, all but the background score (the Albums tab, when the Score tab has it), or only the score (the Score tab).
    enum Part { case all, withoutScore, scoreOnly }
    var part: Part = .all
    /// The language switcher's choice: the film's own albums, one dubbed edition, or everything.
    var filter: MusicFilmLanguageFilter = .all
    @Environment(\.musicLayoutClass) private var cls

    var body: some View {
        let section = model.section(MusicFilmSectionKey.soundtracks)
        let inLanguage = model.originalAlbums.filter { filter.matches(dubLanguage: $0.dubLanguage) }
        let originals = part == .scoreOnly ? [] : inLanguage.filter { model.edition(of: $0) != .score }
        let scores = part == .withoutScore ? [] : inLanguage.filter { model.edition(of: $0) == .score }
        let dubbed = part == .scoreOnly ? [] : model.dubbedAlbums.filter { filter.matches(dubLanguage: $0.dubLanguage) }
        let width = MusicGraphCardWidth.width(for: cls)
        MusicGraphShelf(title: Localized.string("Soundtrack albums"), phase: section.phase, itemCount: originals.count, itemWidth: width) {
            ForEach(originals) { a in card(a, width: width) }
        }
        MusicGraphShelf(title: Localized.string("Background score"), phase: section.phase, itemCount: scores.count, itemWidth: width) {
            ForEach(scores) { a in card(a, width: width) }
        }
        MusicGraphShelf(title: Localized.string("Dubbed versions"), phase: section.phase, itemCount: dubbed.count, itemWidth: width) {
            ForEach(dubbed) { a in card(a, width: width) }
        }
    }

    private func card(_ a: MusicFilmAlbumItem, width: CGFloat) -> some View {
        MusicGraphAlbumCard(title: a.name, subtitle: MusicFilmWording.albumCaption(a, edition: model.edition(of: a)), imageRef: a.imageRef, reason: MusicFilmWording.matchNote(a.matchEvidence),
                            tag: MusicGraphTag(status: a.status, forFilmLink: true), width: width, entity: a.album) { hub.open(a.album) }
    }
}
