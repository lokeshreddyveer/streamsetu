import SwiftUI

/// The Gallery destination of a film: its own stills and posters as a grid of pictures, each opening a larger view inside the app. Pictures only: no captions,
/// no names. Images load as they scroll into view (the grid is lazy), so a film with many pictures costs nothing until they are seen.
struct MusicFilmGallerySection: View {
    let model: MusicFilmGraphModel
    @State private var viewing: Int?
    /// Stills are wide and posters are tall: each kind gets its own grid, so a row never mixes shapes (no ragged gaps, nothing cropped).
    private let stillColumns = [GridItem(.adaptive(minimum: 280, maximum: 420), spacing: MusicSpace.md, alignment: .top)]
    private let posterColumns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: MusicSpace.md, alignment: .top)]

    var body: some View {
        let images = model.overview?.gallery ?? []
        if images.isEmpty {
            Text(verbatim: model.section(MusicFilmSectionKey.overview).phase == .loaded ? Localized.string("No pictures are available for this film.") : Localized.string("Loading details..."))
                .musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
        } else {
            VStack(alignment: .leading, spacing: MusicSpace.xl) {
                grid(images, kind: .backdrop, columns: stillColumns)
                grid(images, kind: .poster, columns: posterColumns)
            }
            .sheet(isPresented: Binding(get: { viewing != nil }, set: { if !$0 { viewing = nil } })) {
                MusicFilmGalleryViewer(images: images, index: $viewing)
            }
        }
    }
}

extension MusicFilmGallerySection {
    /// One kind of picture as a grid; the index each opens is its place in the whole list, so the viewer steps through everything.
    @ViewBuilder fileprivate func grid(_ images: [MusicFilmGalleryImage], kind: MusicFilmGalleryImage.Kind, columns: [GridItem]) -> some View {
        let items = Array(images.enumerated()).filter { $0.element.kind == kind }
        if !items.isEmpty {
            LazyVGrid(columns: columns, alignment: .leading, spacing: MusicSpace.md) {
                ForEach(items, id: \.element.id) { i, img in
                    Button { viewing = i } label: {
                        MusicCoverImage(thumbs: [MusicThumbnail(url: img.thumbURL, width: kind == .backdrop ? 780 : 500, height: kind == .backdrop ? 439 : 750)],
                                        size: nil, corner: MusicCorner.card, pixelHint: 780)
                            .artwork(of: nil, slot: .still)
                            .aspectRatio(img.aspect, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).hoverHighlight()
                    .accessibilityLabel(Localized.string("Open picture %1$@ of %2$@", String(i + 1), String(images.count)))
                    .atlas("control.music.filmGalleryImage")
                }
            }
        }
    }
}

/// The larger view of one picture, with previous and next.
struct MusicFilmGalleryViewer: View {
    let images: [MusicFilmGalleryImage]
    @Binding var index: Int?

    var body: some View {
        let i = min(max(index ?? 0, 0), max(images.count - 1, 0))
        VStack(spacing: MusicSpace.md) {
            HStack {
                Text(verbatim: Localized.string("%1$@ of %2$@", String(i + 1), String(images.count))).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
                Spacer()
                Button { index = nil } label: { Image(systemName: "xmark") }.musicButton(.glassIcon, size: .regular)
                    .accessibilityLabel(Localized.string("Close")).keyboardShortcut(.cancelAction).atlas("control.music.filmGalleryClose")
            }
            if images.indices.contains(i) {
                let img = images[i]
                MusicCoverImage(thumbs: [MusicThumbnail(url: img.fullURL, width: img.kind == .backdrop ? 1280 : 780, height: img.kind == .backdrop ? 720 : 1170)],
                                size: nil, corner: MusicCorner.card, pixelHint: 1280)
                    .artwork(of: nil, slot: .viewer)
                    .aspectRatio(img.aspect, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(img.id)
            }
            HStack(spacing: MusicSpace.lg) {
                Button { index = MusicFilmGallery.step(i, by: -1, count: images.count) } label: { Image(systemName: "chevron.left") }
                    .musicButton(.glassIcon, size: .regular).keyboardShortcut(.leftArrow, modifiers: [])
                    .accessibilityLabel(Localized.string("Previous picture")).disabled(images.count < 2).atlas("control.music.filmGalleryPrevious")
                Button { index = MusicFilmGallery.step(i, by: 1, count: images.count) } label: { Image(systemName: "chevron.right") }
                    .musicButton(.glassIcon, size: .regular).keyboardShortcut(.rightArrow, modifiers: [])
                    .accessibilityLabel(Localized.string("Next picture")).disabled(images.count < 2).atlas("control.music.filmGalleryNext")
            }
        }
        .padding(MusicSpace.lg)
        .frame(minWidth: 640, idealWidth: 860, minHeight: 480, idealHeight: 620)
    }
}
