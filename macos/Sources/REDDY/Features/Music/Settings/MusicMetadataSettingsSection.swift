import SwiftUI

/// Plugins & Sources > Metadata sources: one switch per open source that fills in credits, cast and links. Each row's (i) says what is sent and to whom.
/// The sources start on after the Music consent (Discogs and OMDb start off); a switch only stops that source, and playback never waits for any of them.
struct MusicMetadataSettingsSection: View {
    let hub: MusicHub
    @State private var revision = 0

    private var switches: MusicMetadataSwitches { MusicMetadataSwitches.shared }
    private var onCount: Int { _ = revision; return MusicMetadataSourceNotes.all.filter { switches.isOn($0.id) }.count }

    var body: some View {
        MusicSettingsGroup(title: "Metadata sources", count: MusicSettingsCount.text(onCount, of: MusicMetadataSourceNotes.all.count),
                           footer: "Credits, cast and links for songs, albums and films come from these open sources. Each one has its own switch. Nothing about what you play is sent.") {
            ForEach(MusicMetadataSourceNotes.all) { s in
                MusicToggleRow(title: s.title, detail: s.detail, info: s.note,
                               isOn: Binding(get: { _ = revision; return switches.isOn(s.id) }, set: { switches.set($0, s.id); revision += 1 }))
                    .atlasCovers("control.music.metadataSource")
            }
            MusicToggleRow(title: "Find pictures online", atlas: "control.music.artworkOnline",
                           detail: "Photos, posters and covers, found by name and title only.",
                           info: "Photos of people, film posters and album covers from Wikipedia, Wikidata, TMDB, IMDb, Deezer, Apple Music and JioSaavn. Only names and titles are sent, never what you play.",
                           isOn: Binding(get: { _ = revision; return MusicEntityArtwork.onlineEnabled },
                                         set: { UserDefaults.standard.set($0, forKey: MusicEntityArtwork.onlineKey); revision += 1 }))
        }
    }
}

extension MusicMetadataSwitches {
    /// The one set of switches the app reads (Settings writes it; the enrichment gate reads it).
    static let shared = MusicMetadataSwitches()
}
