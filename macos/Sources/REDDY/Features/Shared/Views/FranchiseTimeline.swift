import SwiftUI

/// The films of a franchise on a line, in the order they came out, numbered and dated. The open film is marked; the others open when chosen.
struct FranchiseTimeline: View {
    let currentID: String
    let movie: Movie
    var poster: CGFloat = 110
    /// On the iPhone a poster is a navigation link, so Back returns here; on the Mac [onOpen] opens the film.
    var useLinks = false
    var onOpen: (LibraryItem) -> Void = { _ in }
    @Environment(\.container) private var container
    @State private var films: [LibraryItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if films.count > 1 {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Timeline").font(.system(size: 20, weight: .bold))
                        Text(summary).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    SetuTimeline(sections: [SetuTimelineSection(id: "franchise", title: nil, nodes: films.map(node))],
                                 litThrough: hereIndex, current: hereIndex, posterWidth: poster) { n, here in
                        if let film = films.first(where: { $0.id == n.id }) { posterView(film, here: here).accessibilityLabel(here ? "\(film.title), the film you are on" : "Open \(film.title)") }
                    }
                }
            }
            // The loader sits on a view that is always there: a task on an empty view never runs.
            Color.clear.frame(height: 0).task(id: movie.id) {
                guard let c = container else { return }
                let service = SimilarService(catalog: c.catalog)
                films = await Task.detached { service.franchise(of: movie) }.value
            }
        }
    }


    private var hereIndex: Int { films.firstIndex { $0.id == currentID } ?? 0 }

    private func node(_ film: LibraryItem) -> SetuTimelineNode {
        SetuTimelineNode(id: film.id, label: film.year.map(String.init) ?? "", title: film.title)
    }

    @ViewBuilder private func posterView(_ film: LibraryItem, here: Bool) -> some View {
        let art = ArtworkImage(url: film.posterURL, kind: .poster, contentMode: .fill, symbol: "film").frame(width: poster, height: poster * 1.5)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(here ? ColorTokens.accent : .white.opacity(0.08), lineWidth: here ? 2 : 1))
            .ratingBadge(film.credibleRating)
        if here { art }
        else if useLinks { NavigationLink(value: film) { art }.buttonStyle(.plain).atlas("control.title.franchise") }
        else { Button { onOpen(film) } label: { art }.buttonStyle(.plain).atlas("control.title.franchise") }
    }

    private var summary: String {
        let years = films.compactMap(\.year)
        return "\(films.count) films" + (years.isEmpty ? "" : "  ·  \(years.min()!) – \(years.max()!)")
    }
}
