import SwiftUI

// The two places the shell adds beside Listen Now, Search and Library. The pages themselves live in MusicExploreView.swift and MusicRadioView.swift;
// both show only what the person's own sources and library already hold.

/// Explore: charts and new releases for a country, languages, and every mood and genre as a cover tile.
struct MusicExplorePage: View {
    @Bindable var hub: MusicHub
    var body: some View { MusicExploreView(hub: hub) }
}

/// What the Radio page offers a start from: the playing song, liked songs and recently played songs, each once.
enum MusicRadioSeeds {
    static let perGroup = 6

    static func unique(_ tracks: [MusicTrack], excluding: Set<String> = [], limit: Int = perGroup) -> [MusicTrack] {
        var seen = excluding, out: [MusicTrack] = []
        for t in tracks where seen.insert(t.uid).inserted {
            out.append(t)
            if out.count == limit { break }
        }
        return out
    }
}

/// Radio: start an endless mix from a song, an artist or a genre you already know. Nothing is invented; with no songs yet, the page says how to get some.
struct MusicRadioPage: View {
    @Bindable var hub: MusicHub
    var body: some View { MusicRadioView(hub: hub) }
}
