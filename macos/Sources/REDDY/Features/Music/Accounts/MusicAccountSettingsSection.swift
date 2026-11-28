import SwiftUI

/// Settings for the YouTube Music account: saved accounts, sign in, add, sign out, and where new likes and playlists go.
/// Nothing here signs in by itself.
struct MusicAccountSettingsSection: View {
    let hub: MusicHub

    var body: some View {
        if let manager = YouTubeMusicAccountBuiltIns.manager { Inner(hub: hub, manager: manager) }
    }

    private struct Inner: View {
        let hub: MusicHub
        let manager: YouTubeMusicAccountManager
        @State private var confirmRemove: YTMAccountSummary?
        @State private var policy = MusicLibrarySourceStore().policy

        private var historyOn: Bool { hub.registry.isEnabled("ytmusic-history") }

        var body: some View {
            VStack(alignment: .leading, spacing: MusicTokens.settingsGroupSpacing) {
                accountsGroup
                if manager.isSignedIn { placementGroup }
            }
            .confirmationDialog("Remove from this app?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }),
                                titleVisibility: .visible, presenting: confirmRemove) { acct in
                Button("Remove", role: .destructive) { manager.remove(acct.id) }.atlas("control.music.accountsRemove")
                Button("Cancel", role: .cancel) {}.atlas("control.music.accountsCancel")
            } message: { acct in Text("\(acct.name) is removed from this list only. Your Google account is not affected.") }
        }

        private var accountsGroup: some View {
            MusicSettingsGroup(title: "YouTube Music", footer: "Sign-in happens in a window that shows Google's own page. The session stays on this device, in the Keychain.") {
                if manager.accounts.isEmpty { MusicNote(text: "No accounts saved.") }
                ForEach(manager.accounts) { acct in accountRow(acct) }
                MusicSettingsActions {
                    if manager.active == nil {
                        Button("Sign in with Google") { manager.requestSignIn(addAccount: false) }.accessibilityLabel(Text("Sign in to YouTube Music with Google")).atlas("control.music.accountsSignInToYoutubeMusicWith")
                    }
                    Button("Add account") { manager.requestSignIn(addAccount: true) }.accessibilityLabel(Text("Add another Google account")).atlas("control.music.accountsAddAnotherGoogleAccount")
                    if manager.active?.hasMultipleChannels == true, !manager.selectionRequired {
                        Button("Switch channel") { manager.pickerMode = .optional }.accessibilityLabel(Text("Switch YouTube channel")).atlas("control.music.accountsSwitchYoutubeChannel")
                    }
                    if manager.active != nil { Button("Sign out") { manager.signOut() }.accessibilityLabel(Text("Sign out of YouTube Music")).atlas("control.music.accountsSignOutOfYoutubeMusic") }
                }
                if manager.selectionRequired { MusicNote(text: "Choose a channel to finish signing in.", tone: .warning) }
                if let e = manager.errorMessage { MusicNote(text: e, tone: .bad) }
                if hub.registry.provider(id: "ytmusic-history") != nil {
                    MusicToggleRow(title: "Add plays to my YouTube history", info: "Tells Google which songs you played, under your account. Off by default.",
                                   isOn: Binding(get: { historyOn }, set: { hub.registry.setEnabled($0, id: "ytmusic-history") })).disabled(!manager.isSignedIn)
                }
            }
        }

        private func accountRow(_ a: YTMAccountSummary) -> some View {
            MusicSettingsRow(title: a.name, detail: a.subtitle) {
                HStack(spacing: Spacing.sm) {
                    if a.isActive { Text("Signed in").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary) }
                    else { Button("Switch") { switchTo(a) }.musicButton().accessibilityLabel(Text(verbatim: Localized.string("Switch to %@", a.name))).atlas("control.music.accountsSwitch") }
                    Button { confirmRemove = a } label: { Image(systemName: "xmark").frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle()) }
                        .buttonStyle(.plain).foregroundStyle(ColorTokens.textTertiary).accessibilityLabel(Text(verbatim: Localized.string("Remove %@ from this app", a.name))).atlas("control.music.accountsInneraccountrowButton")
                }
            }
        }

        private var placementGroup: some View {
            MusicSettingsGroup(title: "Where new things go", footer: "Likes and new playlists can stay on this device or be saved to your YouTube Music account. Existing items are not moved.") {
                MusicPickerRow(title: "Likes", selection: $policy.likes, options: MusicPlacement.allCases.map { ($0, $0.title) })
                MusicPickerRow(title: "New playlists", selection: $policy.playlists, options: MusicPlacement.allCases.map { ($0, $0.title) })
            }
            .onChange(of: policy) { _, new in MusicLibrarySourceStore().policy = new }
        }

        private func switchTo(_ a: YTMAccountSummary) {
            Task {
                do { try await manager.switchAccount(to: a.id) }
                catch { manager.errorMessage = (error as? LocalizedError)?.errorDescription ?? MusicHub.friendlyMessage(error) }
            }
        }
    }
}
