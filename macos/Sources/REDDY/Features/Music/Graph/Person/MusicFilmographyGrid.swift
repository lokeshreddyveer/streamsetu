import SwiftUI

/// The filmography as a grid of poster cards with decade and language filters. The filters live in page memory, so Back returns to the same view of it.
/// Filters are offered only when the films span more than one decade or language (a single choice would filter nothing).
struct MusicFilmographyGrid: View {
    let hub: MusicHub
    let section: MusicPersonSection
    let memoryKey: String
    let cardWidth: CGFloat
    @State private var filter: MusicFilmographyFilter
    @State private var showAll = false

    init(hub: MusicHub, section: MusicPersonSection, memoryKey: String, cardWidth: CGFloat) {
        self.hub = hub; self.section = section; self.memoryKey = memoryKey; self.cardWidth = cardWidth
        _filter = State(initialValue: MusicFilmographyFilter(memory: MusicPageMemoryCenter.shared.memory(for: memoryKey).filters))
    }

    private static let firstScreen = 24

    var body: some View {
        let decades = MusicFilmographyFilter.decades(in: section.entries), languages = MusicFilmographyFilter.languages(in: section.entries)
        let films = filter.apply(to: section.entries)
        let shown = showAll ? films : Array(films.prefix(Self.firstScreen))
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            MusicSectionTitle(title: MusicPersonWording.sectionTitle(.filmography, name: ""))
            if !decades.isEmpty || !languages.isEmpty {
                HStack(spacing: MusicSpace.xs) {
                    MusicChip(title: MusicPersonWording.filterAll, selected: !filter.isActive) { set(.none) }
                    ForEach(decades, id: \.self) { d in
                        MusicChip(title: MusicPersonWording.filterDecade(d), selected: filter.decade == d) { var f = filter; f.decade = f.decade == d ? nil : d; set(f) }
                    }
                    ForEach(languages, id: \.self) { l in
                        MusicChip(title: MusicPersonReader.languageName(l), selected: filter.language == l) { var f = filter; f.language = f.language == l ? nil : l; set(f) }
                    }
                }
            }
            MusicCardGrid { ForEach(shown) { e in MusicPersonFilmCard(hub: hub, entry: e, width: cardWidth) } }
            if films.count > shown.count {
                Button(MusicPersonWording.showAll(max(films.count, section.total))) { showAll = true }
                    .musicButton(.secondary).atlas("control.music.personShowAll")
            }
        }
    }

    private func set(_ f: MusicFilmographyFilter) {
        filter = f; showAll = false
        MusicPageMemoryCenter.shared.update(memoryKey) { f.write(to: &$0.filters) }
    }
}
