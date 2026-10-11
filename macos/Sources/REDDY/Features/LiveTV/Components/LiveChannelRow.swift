import SwiftUI

/// One compact row in the channel list: logo, name, what's on now.
struct LiveChannelRow: View {
    let channel: Channel
    let nowNext: [EPGProgram]?
    let isPlaying: Bool
    var isSelected = false
    let isFavorite: Bool
    var onFavorite: () -> Void
    @Environment(\.reddyAccent) private var accent
    @Environment(\.reddyDensity) private var density
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ChannelLogo(url: channel.logoURL, name: channel.name, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(channel.name).font(Typography.rowMedium).lineLimit(1).truncationMode(.tail)
                    if let q = channel.resolutionHint { QualityBadge(text: q) }
                }
                if let p = nowNext?.first(where: { $0.isLive() }) {
                    Text(p.title).font(.system(size: 10)).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
                } else if nowNext != nil {
                    Text("No guide data").font(.system(size: 10)).foregroundStyle(ColorTokens.textTertiary)
                } else {
                    Text(channel.categoryName ?? " ").font(.system(size: 10)).foregroundStyle(ColorTokens.textTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if isPlaying { Image(systemName: "waveform").font(.system(size: 11)).foregroundStyle(accent) }
            Button(action: onFavorite) { Image(systemName: isFavorite ? "heart.fill" : "heart").font(.system(size: 11)).foregroundStyle(isFavorite ? accent : ColorTokens.textSecondary).frame(width: 22, height: 22).contentShape(Rectangle()) }.accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
                .buttonStyle(.plain).opacity(isFavorite || hovering ? 1 : 0)
                .accessibilityLabel(isFavorite ? "Remove \(channel.name) from favorites" : "Add \(channel.name) to favorites")
        }
        .padding(.horizontal, 10).frame(height: density.channelRowHeight)
        .background(isPlaying || isSelected ? Color.white.opacity(0.05) : hovering ? Color.white.opacity(0.03) : .clear, in: RoundedRectangle(cornerRadius: LayoutTokens.radiusSmall, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
    }
}
