import SwiftUI

// The page of a language, era, region or genre: music directors, singers and soundtracks of it, films, a way to start a radio, and the graph's own
// works tagged with it. Built from the same starter roster and the facet's incoming edges, so a language or era page is full before any history exists.

struct MusicFacetPage: View {
    let hub: MusicHub
    let route: MusicEntityRoute
    @State private var lease: MusicEntityLease?
    @State private var model = MusicFillModel()

    var body: some View {
        let entity = lease?.model
        let name = entity?.name ?? ""
        MusicPageScaffold(hub: hub) {
            MusicPageHeader(title: name.isEmpty ? Localized.string("Loading %1$@", MusicEntityScaffoldPage.label(for: route.page)) : name,
                            kind: MusicEntityScaffoldPage.label(for: route.page), subtitle: "") {
                if !name.isEmpty {
                    Button { MusicFillRuntime.shared.search(name, hub: hub) } label: { Label(Localized.string("Search %@", name), systemImage: "magnifyingglass") }
                        .musicButton(.secondary, size: .compact).accessibilityLabel(Localized.string("Search %@", name)).atlas("control.music.facetSearch")
                }
            }
            ForEach(model.shelves) { MusicFillShelfView(shelf: $0, hub: hub, phase: model.phase) }
        }
        .onAppear { if lease == nil { lease = MusicEntityRuntime.shared.center.acquire(route.id) } }
        .onDisappear { lease?.release(); lease = nil }
        .task(id: name) {
            guard !name.isEmpty else { return }
            let page = route.page, id = route.id, w = MusicFillWording.localized
            model.load(key: id.rawValue + name) { store in await MusicFacetShelves.build(id: id, name: name, page: page.rawValue, store: store, wording: w) }
        }
        .atlasScreen("screen.music.facet")
    }
}
