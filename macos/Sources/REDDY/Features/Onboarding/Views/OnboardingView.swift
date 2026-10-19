import SwiftUI

/// Shown only while no playlist exists: one panel, the same Add playlist form used everywhere else.
struct OnboardingView: View {
    @Environment(AppState.self) private var state
    @Environment(AppRouter.self) private var router
    @Environment(\.container) private var container
    @State private var restore = ICloudRestore()

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 14) {
                BrandIcon(size: 84)
                Text("StreamSetu").font(.system(size: 26, weight: .heavy)).foregroundStyle(.white)
                Text("Add a playlist").font(Typography.title)
                Text("StreamSetu plays the playlists and logins you already have. Nothing is included with the app.").font(Typography.row).foregroundStyle(ColorTokens.textSecondary)
                FirstRunSteps().padding(.vertical, 4)
                AddSourceForm { added in state.reload(); state.switchPlaylist(added.id); router.navigate(.home, .shortcut(.discover)) }
                Divider()
                HStack(spacing: 10) {
                    SecondaryButton(title: restore.phase == .looking ? "Looking…" : "Restore from iCloud", symbol: "icloud.and.arrow.down") {
                        if let container { Task { await restore.start(container: container, state: state) } }
                    }.disabled(restore.phase == .looking)
                    if restore.phase == .looking { ProgressView().controlSize(.small) }
                }
                if restore.phase != .idle {
                    Text(restore.detail).font(Typography.caption).foregroundStyle(restore.phase == .nothingFound ? ColorTokens.warning : ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24).frame(width: 520, alignment: .leading).background(GlassBackground(radius: 12))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(ColorTokens.background)
    }
}
