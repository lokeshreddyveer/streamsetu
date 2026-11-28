import SwiftUI

/// The title-bar account menu: who is signed in, other saved accounts to switch to, add account, switch channel, sign out.
/// Signed out it offers "Sign in with Google". Shows nothing when the account layer is not attached.
struct MusicAccountMenu: View {
    let hub: MusicHub
    /// The sidebar is collapsed to icons: show the avatar only.
    var compact = false

    var body: some View {
        if let manager = YouTubeMusicAccountBuiltIns.manager { Inner(hub: hub, manager: manager, compact: compact) }
    }

    private struct Inner: View {
        let hub: MusicHub
        let manager: YouTubeMusicAccountManager
        var compact = false

        private var others: [YTMAccountSummary] { manager.accounts.filter { !$0.isActive } }

        var body: some View {
            Menu {
                if let a = manager.active, !manager.selectionRequired {
                    Text(verbatim: a.name)
                    if let s = a.subtitle { Text(verbatim: s) }
                    Divider()
                } else if manager.selectionRequired {
                    Button("Choose a channel") { manager.pickerMode = .required }.atlas("control.music.accountsChooseAChannel")
                    Divider()
                } else {
                    Text("Not signed in")
                    Divider()
                }
                ForEach(others) { acct in
                    Button { switchTo(acct) } label: { Text(verbatim: "Switch to \(acct.name)") }.atlas("control.music.accountsSwitchTo")
                }
                if !others.isEmpty { Divider() }
                if manager.active == nil {
                    Button("Sign in with Google") { manager.requestSignIn(addAccount: false) }.atlas("control.music.accountsSignInWithGoogle")
                }
                Button("Add account") { manager.requestSignIn(addAccount: true) }.atlas("control.music.accountsAddAccount")
                if manager.active?.hasMultipleChannels == true, !manager.selectionRequired {
                    Button("Switch channel") { manager.pickerMode = .optional }.atlas("control.music.accountsSwitchChannel")
                }
                if manager.active != nil { Button("Sign out") { manager.signOut() }.atlas("control.music.accountsSignOut") }
                if !manager.accounts.isEmpty {
                    Divider()
                    Menu("Remove account") {
                        ForEach(manager.accounts) { acct in Button(acct.name) { MusicSidebarDialogs.shared.removingAccount = acct }.atlas("control.music.accountsInnerbodyButton") }
                    }.atlas("control.music.accountsRemoveAccount")
                }
            } label: { label }
            .menuStyle(.borderlessButton)
            .modifier(AccountMenuSizing(compact: compact))
            .help(manager.active?.name ?? "Sign in")
            .accessibilityLabel(manager.active.map { "YouTube Music account, \($0.name)" } ?? "YouTube Music account, not signed in")
            .atlas("control.music.accountsChooseAChannel")
            // The two dialogs this menu raises are presented by the Music shell (`MusicSidebarDialogsHost`): the open sidebar of auto-hide goes away with its views.
        }

        @ViewBuilder private var label: some View {
            HStack(spacing: 10) {
                if let a = manager.active, let t = a.thumbnail {
                    MusicArtwork([MusicThumbnail(url: t)], size: 28, corner: 14)
                } else {
                    Image(systemName: "person.crop.circle").font(.system(size: 24)).foregroundStyle(ColorTokens.textSecondary).frame(width: 28, height: 28)
                }
                if !compact {
                    Text(verbatim: manager.active?.name ?? "Sign in").font(Typography.bodyMedium).foregroundStyle(ColorTokens.textPrimary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(ColorTokens.textTertiary)
            }
            .padding(.horizontal, compact ? 0 : 12).frame(height: 44)
            .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }

        private func switchTo(_ acct: YTMAccountSummary) {
            Task {
                do { try await manager.switchAccount(to: acct.id) }
                catch { manager.errorMessage = (error as? LocalizedError)?.errorDescription ?? MusicHub.friendlyMessage(error) }
            }
        }
    }
}

/// Collapsed: the avatar at its own size. Expanded: the whole row of the sidebar, so the name has room and the whole row is the target.
private struct AccountMenuSizing: ViewModifier {
    let compact: Bool
    func body(content: Content) -> some View {
        if compact { content.fixedSize() } else { content.frame(maxWidth: .infinity) }
    }
}
