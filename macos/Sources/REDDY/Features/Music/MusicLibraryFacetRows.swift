import SwiftUI

// The "Genres" and "Languages" rows above a Library list: one chip per facet with its count, or one menu per row when the page is narrow.
// Choosing a chip filters the list, choosing it again (or "All") shows everything. Every chip is a button, so Tab and Space reach and press them.

struct MusicLibraryFacetRows: View {
    let facets: MusicFacetSet
    @Binding var selection: MusicFacetSelection
    var narrow: Bool

    /// A row with one choice only cannot narrow anything, so it shows only while that choice is the one picked.
    private func visible(_ list: [MusicLibraryFacet], picked: String?) -> Bool { list.count >= 2 || (list.count == 1 && picked != nil) }

    var body: some View {
        let showGenres = visible(facets.genres, picked: selection.genre)
        let showLanguages = visible(facets.languages, picked: selection.language)
        if showGenres || showLanguages {
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                if showGenres { row(title: Localized.string("Genres"), symbol: "guitars", list: facets.genres, picked: $selection.genre) }
                if showLanguages { row(title: Localized.string("Languages"), symbol: "character.bubble", list: facets.languages, picked: $selection.language) }
            }
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder private func row(title: String, symbol: String, list: [MusicLibraryFacet], picked: Binding<String?>) -> some View {
        if narrow {
            Menu {
                Picker(title, selection: Binding(get: { picked.wrappedValue ?? "" }, set: { picked.wrappedValue = $0.isEmpty ? nil : $0 })) {
                    Text(Localized.string("All")).tag("")
                    ForEach(list) { f in Text(verbatim: label(f)).tag(f.key) }
                }.atlas("control.music.libraryFacetPicker")
                .pickerStyle(.inline)
            } label: {
                let current = list.first { $0.key == picked.wrappedValue }
                Label(current.map { title + ": " + $0.name } ?? title, systemImage: symbol).musicText(.body)
                    .padding(.horizontal, MusicSpace.sm).frame(height: MusicButtonMetrics.height(.regular))
                    .background(ColorTokens.elevated, in: Capsule())
            }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel(Text(verbatim: title)).atlas("control.music.libraryFacetMenu")
        } else {
            HStack(spacing: MusicSpace.xs) {
                Label(title, systemImage: symbol).musicText(.caption).foregroundStyle(ColorTokens.textTertiary).fixedSize()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: MusicSpace.xxs) {
                        ForEach(list) { f in
                            MusicChip(title: label(f), selected: picked.wrappedValue == f.key) {
                                picked.wrappedValue = picked.wrappedValue == f.key ? nil : f.key
                            }
                            .accessibilityLabel(Text(verbatim: Localized.string("%1$@: %2$@", title, label(f))))
                        }
                    }
                    .padding(.vertical, 1)
                }
                .atlasCovers("control.music.libraryFacetChip")
            }
        }
    }

    private func label(_ f: MusicLibraryFacet) -> String { f.name + " · " + f.count.formatted() }
}
