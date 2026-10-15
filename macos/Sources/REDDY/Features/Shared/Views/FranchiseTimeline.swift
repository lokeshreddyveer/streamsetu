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
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(Array(films.enumerated()), id: \.element.id) { i, film in
                                column(i, film)
                            }
                        }.padding(.vertical, 4)
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

    private func column(_ i: Int, _ film: LibraryItem) -> some View {
        let here = film.id == currentID
        return VStack(spacing: 10) {
            posterView(film, here: here)
                .scaleEffect(here ? 1 : 0.94, anchor: .bottom)
                .opacity(here ? 1 : 0.85)
                .shadow(color: here ? Color.accentColor.opacity(0.45) : .clear, radius: 14, y: 4)
                .accessibilityLabel(here ? "\(film.title), the film you are on" : "Open \(film.title)")
            rail(i, here: here)
            VStack(spacing: 2) {
                Text(film.year.map(String.init) ?? "").font(.system(size: 13, weight: .semibold)).foregroundStyle(here ? Color.accentColor : .primary)
                Text(film.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
            }.frame(width: poster)
        }
        .frame(width: poster + 20)
    }

    /// One piece of the line through the numbered dots; the part up to the open film is lit.
    private func rail(_ i: Int, here: Bool) -> some View {
        let lit = Color.accentColor, dim = Color.secondary.opacity(0.3)
        return ZStack {
            HStack(spacing: 0) {
                Rectangle().fill(i == 0 ? .clear : (i <= hereIndex ? lit : dim)).frame(height: 3)
                Rectangle().fill(i == films.count - 1 ? .clear : (i < hereIndex ? lit : dim)).frame(height: 3)
            }
            Text("\(i + 1)").font(.system(size: 11, weight: .bold)).foregroundStyle(i <= hereIndex ? Color.white : .secondary)
                .frame(width: here ? 28 : 22, height: here ? 28 : 22)
                .background(Circle().fill(i <= hereIndex ? lit : Color.secondary.opacity(0.25)))
                .overlay(Circle().strokeBorder(.background, lineWidth: 3))
        }.frame(height: 28)
    }

    @ViewBuilder private func posterView(_ film: LibraryItem, here: Bool) -> some View {
        let art = ArtworkImage(url: film.posterURL, kind: .poster, contentMode: .fill, symbol: "film").frame(width: poster, height: poster * 1.5)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(here ? Color.accentColor : .white.opacity(0.08), lineWidth: here ? 2 : 1))
        if here { art }
        else if useLinks { NavigationLink(value: film) { art }.buttonStyle(.plain) }
        else { Button { onOpen(film) } label: { art }.buttonStyle(.plain) }
    }

    private var summary: String {
        let years = films.compactMap(\.year)
        return "\(films.count) films" + (years.isEmpty ? "" : "  ·  \(years.min()!) – \(years.max()!)")
    }
}
