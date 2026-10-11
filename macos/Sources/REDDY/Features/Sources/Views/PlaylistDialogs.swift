import SwiftUI

struct AddPlaylistDialog: View {
    @Environment(AppState.self) private var state
    @Environment(AppRouter.self) private var router

    var body: some View {
        ReddyDialog(title: "Add playlist", width: 520, onClose: { router.modal = nil }) {
            AddSourceForm { added in
                state.reload()
                state.switchPlaylist(added.id)
                router.modal = nil
            }
        }
    }
}

struct AboutDialog: View {
    @Environment(AppRouter.self) private var router
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

    var body: some View {
        ReddyDialog(title: "About StreamSetu", width: 420, onClose: { router.modal = nil }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) { BrandIcon(size: 72); Text("Version \(version)").font(Typography.rowMedium); Spacer() }
                    .padding(.bottom, 4)
                Text("StreamSetu is a player. It does not include, sell or link to any channels, movies or series — it plays the playlists and logins you add yourself.")
                    .font(Typography.row).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true)
                Divider().overlay(ColorTokens.line)
                Label("Your library, history and favorites are stored only on this Mac.", systemImage: "internaldrive")
                Label("Logins are kept in your Keychain. Nothing is sent to us — there is no telemetry.", systemImage: "lock.shield")
                Label("Formats AVPlayer can't play (such as MKV) use the bundled libmpv engine (GPL).", systemImage: "play.rectangle")
            }
            .font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
        }
    }
}
