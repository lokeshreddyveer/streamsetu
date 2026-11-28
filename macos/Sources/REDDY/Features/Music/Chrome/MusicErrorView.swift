import SwiftUI

/// The app's one network watch for Music: started the first time an error view needs it, and nothing before.
@MainActor
enum MusicNetwork {
    static let watch: NetworkWatch = { let w = NetworkWatch(); w.start(); return w }()
}

/// What a failed page shows. Offline says so in one friendly sentence and retries by itself on the 2, 4, 8, 15, 30 second ladder; any other
/// failure shows the raw text, smaller and muted, because that is what a bug report needs.
struct MusicErrorView: View {
    let message: String
    let offline: Bool
    let retry: @MainActor () -> Void
    @State private var retrier = MusicOfflineRetry(watch: MusicNetwork.watch)
    @Environment(\.reddyAccent) private var accent

    init(message: String, retry: @escaping @MainActor () -> Void) {
        self.message = message; self.retry = retry
        self.offline = message == MusicFriendlyErrors.unreachable
    }

    init(error: Error, retry: @escaping @MainActor () -> Void) {
        self.message = MusicFriendlyErrors.message(for: error); self.retry = retry
        self.offline = MusicFriendlyErrors.isOffline(error)
    }

    var body: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: offline ? "wifi.slash" : "exclamationmark.triangle")
                .font(MusicTokens.iconLarge).foregroundStyle(ColorTokens.textTertiary)
                .frame(width: 56, height: 56).background(ColorTokens.elevated, in: Circle()).accessibilityHidden(true)
            Text(LocalizedStringKey(offline ? MusicFriendlyErrors.offlineTitle : MusicFriendlyErrors.genericTitle)).font(Typography.heading)
            if offline {
                Text(LocalizedStringKey(MusicFriendlyErrors.unreachable)).font(Typography.body).foregroundStyle(ColorTokens.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            } else if !message.isEmpty {
                Text(verbatim: message).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary).multilineTextAlignment(.center).frame(maxWidth: 380).textSelection(.enabled)
            }
            Button("Try Again") { retrier.reset(); retry() }
                .musicButton(.secondary).padding(.top, MusicSpace.xs)
                .accessibilityHint(Text("Loads this page again")).atlas("control.music.musicTryAgain")
        }
        .frame(maxWidth: .infinity).padding(.vertical, Spacing.xxl).padding(.horizontal, Spacing.lg)
        .accessibilityElement(children: .contain)
        .onAppear { if offline { retrier.arm(retry: retry) } }
        .onDisappear { retrier.cancel() }
    }
}
