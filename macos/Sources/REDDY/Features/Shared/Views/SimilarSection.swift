import SwiftUI

/// "More Like This" under a movie or series: titles from the library that share its franchise, director, genre, cast or story, each with the reason it was chosen.
struct SimilarSection: View {
    let item: LibraryItem
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @Environment(AppRouter.self) private var router
    @State private var suggestions: [SimilarSuggestion] = []

    var body: some View {
        // A task on an empty view never runs, so something always exists here: a one-point clear line holds the loading step until there is a row to show.
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 1)
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text("More Like This").font(Typography.heading)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: Spacing.md) {
                            ForEach(suggestions) { s in
                                VStack(alignment: .leading, spacing: 4) {
                                    ReddyPosterCard(model: PosterCardModel(item: s.item, isFavorite: state.isFavorite(s.id), isNew: state.hasNewEpisodes(s.id)), width: 120,
                                                    onOpen: { PlayActions.open(s.item, router: router) },
                                                    onPlay: { if let c = container { PlayActions(container: c, toasts: state.toasts).play(s.item) } })
                                    Text(s.reason).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1).frame(width: 120, alignment: .leading)
                                }
                            }
                        }.padding(.vertical, 4)
                    }
                }
            }
        }
        .task(id: item.id) {
            guard let c = container else { return }
            // The first row comes at once from the catalog; when the provider sends the cast and director, a second, sharper one replaces it.
            let service = SimilarService(catalog: c.catalog)
            let first = await Task.detached { service.suggestions(for: item, extras: nil) }.value
            suggestions = first
            let extras: ProviderExtras? = item.isSeries ? await c.details.extras(series: item.id) : await c.details.extras(movie: item.id)
            if let extras, !extras.cast.isEmpty || !extras.directors.isEmpty {
                suggestions = await Task.detached { service.suggestions(for: item, extras: extras) }.value
            }
        }
    }
}
