import SwiftUI

struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1
    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { g in
                    LinearGradient(colors: [.clear, .white.opacity(0.09), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.6)
                        .offset(x: phase * g.size.width * 1.6)
                }.clipped()
            )
            .onAppear { withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 } }
    }
}

struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat = 16
    var radius: CGFloat = LayoutTokens.radiusSmall
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous).fill(ColorTokens.card)
            .frame(width: width, height: height).modifier(Shimmer())
    }
}

struct LoadingView: View {
    var label: String = "Loading…"
    var body: some View {
        VStack(spacing: Spacing.md) { ProgressView().controlSize(.large); Text(label).foregroundStyle(ColorTokens.textSecondary) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PosterSkeletonGrid: View {
    var count = 12
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: LayoutTokens.posterSize.width), spacing: Spacing.xl)], spacing: Spacing.xl) {
            ForEach(0..<count, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonBlock(height: LayoutTokens.posterSize.height, radius: LayoutTokens.radius)
                    SkeletonBlock(width: 120, height: 12)
                }
            }
        }
    }
}
