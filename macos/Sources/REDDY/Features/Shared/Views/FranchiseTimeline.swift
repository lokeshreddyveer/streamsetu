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
        Group {
            if films.count > 1 {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Timeline").font(.system(size: 17, weight: .bold))
                        Text(summary).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(Array(films.enumerated()), id: \.element.id) { i, film in
                                let here = film.id == currentID
                                VStack(alignment: .leading, spacing: 6) {
                                    posterView(film, here: here).accessibilityLabel(here ? "\(film.title), the film you are on" : "Open \(film.title)")
                                    ZStack(alignment: .leading) {
                                        Rectangle().fill(.secondary.opacity(0.5)).frame(width: poster + 12, height: 2)
                                        Circle().fill(here ? Color.accentColor : .secondary).frame(width: here ? 14 : 9, height: here ? 14 : 9)
                                    }.frame(height: 14)
                                    Text("\(i + 1)  ·  \(film.year.map(String.init) ?? "?")").font(.system(size: 12, weight: here ? .bold : .regular)).foregroundStyle(here ? .primary : .secondary)
                                    Text(here ? "You are here" : film.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).frame(width: poster, alignment: .leading)
                                }
                            }
                        }.padding(.vertical, 2)
                    }
                }
            }
        }
        .task(id: movie.id) {
            guard let c = container else { return }
            let service = SimilarService(catalog: c.catalog)
            films = await Task.detached { service.franchise(of: movie) }.value
        }
    }

    @ViewBuilder private func posterView(_ film: LibraryItem, here: Bool) -> some View {
        let art = ArtworkImage(url: film.posterURL, kind: .poster, contentMode: .fill, symbol: "film").frame(width: poster, height: poster * 1.5)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(here ? Color.accentColor : .white.opacity(0.08), lineWidth: here ? 2 : 1))
        if here { art }
        else if useLinks { NavigationLink(value: film) { art }.buttonStyle(.plain) }
        else { Button { onOpen(film) } label: { art }.buttonStyle(.plain) }
    }

    private var summary: String {
        let years = films.compactMap(\.year)
        return "\(films.count) films" + (years.isEmpty ? "" : "  ·  \(years.min()!) – \(years.max()!)")
    }
}
