import SwiftUI

/// Mac: a person's titles in a sheet over the title page. Opening one closes the sheet and shows that title.
struct PersonSheet: View {
    let person: PersonRoute
    let close: () -> Void
    @Environment(AppRouter.self) private var router
    @Environment(AppState.self) private var state
    @Environment(\.container) private var container

    var body: some View {
        ZStack(alignment: .topTrailing) {
            PersonTitlesList(name: person.name) { e in
                var model = PosterCardModel(item: e.item, progress: nil, isFavorite: state.isFavorite(e.item.id), isNew: false, isWatched: state.isWatched(e.item.id))
                if !e.otherLanguages.isEmpty { model.subtitle = "Also in " + e.otherLanguages.joined(separator: ", ") }
                return ReddyPosterCard(model: model, width: 130, onOpen: { close(); PlayActions.open(e.item, router: router) },
                                       onPlay: { if let c = container { close(); PlayActions(container: c, toasts: state.toasts).play(e.item) } })
            }
            IconButton(symbol: "xmark", help: "Close") { close() }.padding(12)
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}
