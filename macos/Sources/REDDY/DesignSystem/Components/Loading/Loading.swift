import SwiftUI

/// The shimmer of a loading placeholder: the motion kit's (still with Reduce Motion, stops off screen).
struct Shimmer: ViewModifier {
    func body(content: Content) -> some View { content.brandShimmer() }
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
        BrandLoader(size: 48, label: label)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
