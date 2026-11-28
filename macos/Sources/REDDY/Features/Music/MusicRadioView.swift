import SwiftUI

// Radio: stations, not songs. A "Start a station" field on top, the station that is playing, the person's own stations, stations made from what they
// play, stations from the lists of their country and the ones played lately. Nothing here is a fixed list: the sections are worked out off the main
// thread from a trigger value (RD-1) and kept in state, and every name comes from the person's history or from what a source returned.

struct MusicRadioView: View {
    @Bindable var hub: MusicHub
    /// The one country of the whole Music screen: Listen Now, Explore and Radio read and set the same value, so a change on one shows on the others.
    @State private var choice = MusicRegionChoice.shared
    @State private var model = MusicRadioModel()
    @State private var startingID: String?
    @State private var editing: RadioStation?
    @Environment(\.musicLayoutClass) private var layoutClass

    private var region: String { choice.region }
    private var radio: RadioService { hub.radio }
    private var cardSize: MusicCardSize {
        switch layoutClass { case .compact: .compact; case .medium: .standard; case .expanded, .wide: .large }
    }

    var body: some View {
        let derived = model.derived
        let trigger = MusicRadioModel.trigger(hub: hub, region: region)
        let own = radio.stations.filter { $0.derivedID == nil }
        let recent = Array(radio.recentlyPlayed.prefix(12))
        MusicScreen(title: Localized.string("Radio"), trailing: { regionMenu }) {
            MusicRadioSeedField(hub: hub) { seeds in start(RadioService.makeStation(seeds: seeds)) }
            MusicNowOnRadioCard(hub: hub)
            if !own.isEmpty { shelf(Localized.string("Your stations"), nil, own, saved: true) }
            if derived.hasPersonal {
                shelf(Localized.string("Made for you"), Localized.string("From what you play"), derived.all.filter { $0.derivedID?.hasPrefix("region:") != true }, saved: false)
            }
            if !derived.regional.isEmpty {
                shelf(Localized.string("Based on your region"), region.isEmpty ? nil : MusicDiscoveryRegion.name(region), derived.regional, saved: false)
            }
            if !recent.isEmpty { shelf(Localized.string("Recently played stations"), nil, recent, saved: true) }
            if own.isEmpty, recent.isEmpty, !derived.hasPersonal, derived.regional.isEmpty { emptyState }
        }
        .task(id: trigger) { await model.refresh(hub: hub, trigger: trigger) }
        .sheet(item: $editing) { st in MusicRadioEditor(hub: hub, stationID: st.id) }
    }

    /// A new person: no stations, no history. The field above starts one; the country's lists below fill in as soon as a source answers.
    @ViewBuilder private var emptyState: some View {
        if model.loadingRegion {
            MusicEmptyState(glyph: .radio, title: Localized.string("Finding stations for your region"), compact: true)
        } else {
            MusicEmptyState(glyph: .radio, title: Localized.string("Start your first station"),
                            message: Localized.string("Type an artist, a song, a genre or a language above. Stations made from what you play appear here as you listen."),
                            compact: true)
        }
    }

    @ViewBuilder private func shelf(_ title: String, _ subtitle: String?, _ stations: [RadioStation], saved: Bool) -> some View {
        if !stations.isEmpty {
            MusicShelf(title: title, subtitle: subtitle) {
                ForEach(stations) { st in
                    RadioStationCard(hub: hub, station: st, width: cardSize.width, busy: startingID == st.id, menu: saved ? { menu(for: st) } : nil) { start(st) }
                }
            }
            .cardWidth(cardSize.width)
        }
    }

    private func menu(for st: RadioStation) -> AnyView {
        AnyView(Group {
            Button("Rename…", systemImage: "pencil") { editing = st }.atlas("control.music.radioRename")
            Button("Edit what it follows…", systemImage: "slider.horizontal.3") { editing = st }.atlas("control.music.radioEditSeeds")
            Button("Make a copy", systemImage: "plus.square.on.square") { radio.duplicate(st.id) }.atlas("control.music.radioDuplicate")
            Divider()
            Button("Delete station", systemImage: "trash", role: .destructive) { radio.delete(st.id) }.atlas("control.music.radioDelete")
        })
    }

    private var regionMenu: some View {
        MusicCountryPicker(region: region) { code in
            if choice.set(code) { MusicAnnouncer.shared.announce(Localized.string("Showing %@", MusicDiscoveryRegion.name(code))) }
        }
    }

    private func start(_ st: RadioStation) {
        guard startingID == nil else { return }
        startingID = st.id
        Task {
            // The cards ignore other clicks while one station starts, so a start that never answers must not hold them for good.
            let release = Task { try? await Task.sleep(for: .seconds(25)); if startingID == st.id { startingID = nil } }
            let ok = await radio.start(st)
            MusicDebugLog.log("radio", "start from page \(st.name) ok=\(ok)")
            release.cancel()
            if startingID == st.id { startingID = nil }
        }
    }
}
