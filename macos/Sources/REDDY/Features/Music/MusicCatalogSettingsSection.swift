import SwiftUI

/// Playback tab: the switch for using catalogue sources (JioSaavn, Apple, Spotify and the chart lists) behind the scenes. They never list songs
/// by themselves; they give the right spelling, film and cover so the playable copy is found and checked.
struct MusicCatalogSettingsSection: View {
    let hub: MusicHub
    @State private var on = MusicCatalogRuntime.shared.settingIsOn
    @State private var matches = MusicCanonicalStore.shared.count

    var body: some View {
        MusicSettingsGroup(title: "Catalogue information",
                           footer: "Catalogue sources never appear in Music. Their information is used behind the scenes to find and check the playable copy, spell searches right, and improve covers, albums, films and artists. Matches are kept on this device for 30 days and cleared by the privacy wipe.") {
            MusicToggleRow(title: "Use catalogue sources to improve matching",
                           info: "Use catalogue information to improve matches, covers, albums and artists.",
                           isOn: Binding(get: { on }, set: { v in on = v; MusicCatalogRuntime.shared.setEnabled(v) }))
            MusicValueRow(title: "Remembered matches", value: "\(matches)")
        }
        .onAppear { matches = MusicCanonicalStore.shared.count }
    }
}
