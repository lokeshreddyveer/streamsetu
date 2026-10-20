import SwiftUI

/// Profiles, so each person has their own favourites, collections, history and resume points.
struct ProfilesView: View {
    @Environment(\.container) private var container

    var body: some View {
        Form {
            if let service = container?.profiles {
                Section {
                    ProfilesList(service: service)
                } footer: {
                    Text("Everyone uses the same playlists. Each profile keeps its own favourites, collections, watch history and resume points. A kids profile keeps the folders you locked in Privacy hidden, and needs its PIN to leave. Sync carries the first profile only, so it pauses while another profile is in use. Your provider's limit on simultaneous streams still applies to everyone together.")
                }.listRowBackground(ColorTokens.surface)
            }
        }
        .navigationTitle("Profiles").themed("Profiles")
    }
}
