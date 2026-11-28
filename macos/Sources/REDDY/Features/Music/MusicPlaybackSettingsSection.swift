import SwiftUI

/// The audio cache: whether played songs are kept, how much room they may take, and clearing them.
struct MusicPlaybackSettingsSection: View {
    let hub: MusicHub
    @State private var usedBytes: Int64 = 0
    @State private var confirmClear = false

    private var settings: MusicSettings { hub.library.settings }

    var body: some View {
        MusicSettingsGroup(title: "Audio cache", footer: "Played songs start instantly and play offline. The oldest are removed first when the limit is reached.") {
            MusicToggleRow(title: "Keep played songs", isOn: Binding(get: { settings.cacheEnabled }, set: { hub.library.settings.cacheEnabled = $0 }))
            MusicSliderRow(title: "Size limit", value: Binding(get: { Double(settings.cacheLimitMB) }, set: { hub.library.settings.cacheLimitMB = Int($0.rounded()) }),
                           range: Double(MusicSettings.minCacheMB)...5_000, step: 50, valueText: Self.sizeText(Int64(settings.cacheLimitMB) * 1_048_576))
                .disabled(!settings.cacheEnabled)
            MusicSettingsRow(title: "Used") {
                HStack(spacing: Spacing.sm) {
                    Text(verbatim: Self.sizeText(usedBytes)).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                    Button("Clear cache") { confirmClear = true }.musicButton().disabled(usedBytes == 0).atlas("control.music.settingsPlaybackClearCache")
                }
            }
        }
        .onAppear { refreshUsage() }
        .confirmationDialog("Clear the audio cache?", isPresented: $confirmClear) {
            Button("Clear cache", role: .destructive) {
                hub.player.audioCache?.clear()
                refreshUsage()
            }.atlas("control.music.settingsPlaybackClearCache")
        } message: {
            Text("Cached songs are removed from this device. Downloads are not affected.")
        }
    }

    private func refreshUsage() { usedBytes = hub.player.audioCache?.usedBytes ?? 0 }

    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
