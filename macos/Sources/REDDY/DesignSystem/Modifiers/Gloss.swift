import SwiftUI

/// The top-lit sheen on chrome and panels. How strong it is comes from the theme: a flat theme gets a faint wash, a glossy one a
/// clear gradient, a diagonal specular streak and a bright hairline along the top edge.
struct GlossSheen: View {
    var cornerRadius: CGFloat = 0
    var streak = true

    var body: some View {
        let sheen = ColorTokens.sheen, edge = ColorTokens.highlight
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [Color.white.opacity(sheen), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.55)))
            if streak && sheen > 0.1 {
                shape.fill(LinearGradient(stops: [.init(color: .clear, location: 0.0), .init(color: Color.white.opacity(sheen * 0.30), location: 0.18),
                                                  .init(color: .clear, location: 0.42), .init(color: .clear, location: 1)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            if edge > 0 {
                shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(edge), Color.white.opacity(edge * 0.15), .clear], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}
