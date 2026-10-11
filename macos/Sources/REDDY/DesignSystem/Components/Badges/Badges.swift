import SwiftUI

struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(.white).frame(width: 5, height: 5)
            Text("LIVE").font(Typography.micro)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(ColorTokens.live, in: Capsule())
        .foregroundStyle(.white)
    }
}

struct QualityBadge: View {
    let text: String
    var body: some View {
        Text(text).font(Typography.micro)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ColorTokens.borderStrong))
            .foregroundStyle(ColorTokens.textSecondary)
    }
}

struct CountBadge: View {
    let count: Int
    var body: some View {
        Text(count.formatted()).font(Typography.captionMedium)
            .padding(.horizontal, 7).padding(.vertical, 1)
            .background(Color.white.opacity(0.08), in: Capsule())
            .foregroundStyle(ColorTokens.textSecondary)
    }
}

struct ProgressBar: View {
    let fraction: Double
    var height: CGFloat = 3
    @Environment(\.reddyAccent) private var accent
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule().fill(accent).frame(width: g.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: height)
    }
}
