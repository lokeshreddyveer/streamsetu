import SwiftUI

/// Dialog surface: smoked glass, hairline edge, accessible close control.
struct ReddyDialog<Content: View>: View {
    let title: String
    var width: CGFloat = 560
    var onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.system(size: 18, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 26, height: 26)
                        .background(Color.white.opacity(0.07), in: Circle()).contentShape(Circle())
                }
                .buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel("Close dialog")
            }
            .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 14)
            content.padding(.horizontal, 22).padding(.bottom, 22)
        }
        .frame(width: width)
        .background(GlassBackground(radius: 12))
        .background(ColorTokens.background.opacity(0.01))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.55), radius: 40, y: 20)
    }
}
