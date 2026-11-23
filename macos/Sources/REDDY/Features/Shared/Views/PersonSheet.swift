import SwiftUI

/// Mac: a person's page inside the title page's own window (with Back), or in the search page's sheet. Opening one closes the sheet and shows that title.
struct PersonSheet: View {
    let person: PersonRoute
    let close: () -> Void
    @Environment(AppRouter.self) private var router
    @Environment(AppState.self) private var state
    @Environment(\.container) private var container

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { close() } label: { Label("Back", systemImage: "chevron.left").font(.subheadline.weight(.semibold)) }.buttonStyle(.plain).foregroundStyle(.tint)
                    .keyboardShortcut(.cancelAction).accessibilityLabel("Back")
                Spacer()
            }.padding(.horizontal, 16).padding(.top, 12)
            PersonPage(route: person) { item in close(); PlayActions.open(item, router: router) }
        }
    }
}
