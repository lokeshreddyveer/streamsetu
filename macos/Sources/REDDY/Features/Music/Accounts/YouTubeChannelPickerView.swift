import SwiftUI

/// "Choose a channel": the channels of the signed-in Google account. Library, likes and playlists use the one picked here.
/// Required mode (a new multi-channel sign-in) cannot be dismissed except by picking or by cancelling the sign-in.
struct YouTubeChannelPickerView: View {
    let manager: YouTubeMusicAccountManager
    let required: Bool
    let onClose: () -> Void

    private enum Load { case loading, failed(String), loaded([YTMIdentityRow]) }
    @State private var load = Load.loading
    @State private var picking: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a channel").font(Typography.title).accessibilityAddTraits(.isHeader)
            Text("Your library, likes and playlists will use this channel. You can switch to another one later.")
                .font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
            content
            HStack {
                Spacer()
                if required {
                    Button("Cancel sign in") { manager.cancelPendingSignIn(); onClose() }
                        .musicButton(.secondary).accessibilityLabel("Cancel sign in").atlas("control.music.accountsCancelSignIn")
                } else {
                    Button("Cancel") { onClose() }.musicButton(.secondary).keyboardShortcut(.cancelAction).accessibilityLabel("Close").atlas("control.music.accountsClose")
                }
            }
        }
        .padding(20)
        .frame(minWidth: 380, idealWidth: 420)
        .task { await reload() }
    }

    @ViewBuilder private var content: some View {
        switch load {
        case .loading:
            MusicLoadingIcon(size: MusicIconSize.small).frame(maxWidth: .infinity).padding(.vertical, 18).accessibilityLabel("Loading channels")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: message).font(Typography.body).foregroundStyle(ColorTokens.danger)
                Button("Retry") { Task { await reload() } }.musicButton(.secondary).accessibilityLabel("Try loading the channels again").atlas("control.music.accountsTryLoadingTheChannelsAgain")
            }
        case .loaded(let rows):
            if rows.isEmpty {
                Text("No channels can be selected.").font(Typography.body).foregroundStyle(ColorTokens.textSecondary)
            } else {
                VStack(spacing: 6) { ForEach(rows) { row in rowView(row) } }
            }
        }
    }

    private func rowView(_ r: YTMIdentityRow) -> some View {
        Button { Task { await pick(r) } } label: {
            HStack(spacing: 10) {
                MusicArtwork(r.thumbnail.map { [MusicThumbnail(url: $0)] } ?? [], size: 36, corner: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: r.name).font(Typography.bodyMedium)
                    if let s = r.handle ?? r.email { Text(verbatim: s).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary) }
                }
                Spacer()
                if r.isSelected { Image(systemName: "checkmark").foregroundStyle(ColorTokens.textSecondary).accessibilityLabel("Current channel") }
                if picking == r.selectionKey { MusicLoadingIcon(size: MusicIconSize.small) }
            }
            .padding(8).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(picking != nil)
        .accessibilityLabel("Use channel \(r.name)")
        .accessibilityAddTraits(r.isSelected ? .isSelected : []).atlas("control.music.accountsCurrentChannel")
    }

    private func reload() async {
        load = .loading
        do { load = .loaded(try await manager.channels()) }
        catch { load = .failed(message(error)) }
    }

    private func pick(_ r: YTMIdentityRow) async {
        picking = r.selectionKey
        defer { picking = nil }
        do {
            try await manager.selectChannel(key: r.selectionKey)
            onClose()
        } catch { load = .failed(message(error)) }
    }

    private func message(_ e: Error) -> String { (e as? LocalizedError)?.errorDescription ?? MusicHub.friendlyMessage(e) }
}

/// Presents the sign-in window and the channel picker for the account manager. Apply it ONCE, high in the Music view tree.
struct YouTubeMusicAccountSheets: ViewModifier {
    @Bindable var manager: YouTubeMusicAccountManager

    func body(content: Content) -> some View {
        content
            .sheet(item: $manager.signInRequest) { req in
                YouTubeSignInView(manager: manager, addAccount: req.addAccount) { manager.signInRequest = nil }
            }
            .sheet(isPresented: Binding(get: { manager.pickerMode != nil }, set: { if !$0, manager.pickerMode == .optional { manager.pickerMode = nil } })) {
                YouTubeChannelPickerView(manager: manager, required: manager.pickerMode == .required) { manager.pickerMode = nil }
                    .interactiveDismissDisabled(manager.pickerMode == .required)
            }
    }
}

private struct AccountSheetsHost: ViewModifier {
    func body(content: Content) -> some View {
        if let m = YouTubeMusicAccountBuiltIns.manager { content.modifier(YouTubeMusicAccountSheets(manager: m)) } else { content }
    }
}

extension View {
    /// Adds the YouTube Music sign-in window and channel picker. Does nothing when the account layer is not attached.
    func youTubeMusicAccountSheets() -> some View { modifier(AccountSheetsHost()) }
}
