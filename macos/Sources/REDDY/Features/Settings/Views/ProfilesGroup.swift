import SwiftUI

/// Settings: profiles, so each person has their own favourites, collections, history and resume points.
struct ProfilesGroup: View {
    @Environment(\.container) private var container
    var body: some View {
        if let service = container?.profiles {
            SettingsGroup(title: "Profiles", footer: "Everyone uses the same playlists. Each profile keeps its own favourites, collections, watch history and resume points. A kids profile keeps the folders you locked in Privacy hidden, and needs its PIN to leave. Sync (iCloud and on this network) carries the first profile only, so it pauses while another profile is in use. Your provider's limit on simultaneous streams still applies to everyone together.") {
                ProfilesList(service: service)
            }
        }
    }
}
