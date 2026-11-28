import SwiftUI

/// The Back pill of a page that was opened from another page (an artist, album, playlist, film). The main screens do not have one. It names where it goes back to: the section
/// when the page was opened straight from it, else just "Back". It floats at the top left of the page with nothing behind it: no fill, only a thin outline, and a faint wash on hover.
/// ⌘[ does the same from anywhere.
struct MusicPageBackLink: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: MusicSpace.xxs) {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold)).accessibilityHidden(true)
                Text(verbatim: title).musicText(.card).lineLimit(1)
            }
            .foregroundStyle(hovering ? ColorTokens.textPrimary : ColorTokens.textSecondary)
            .padding(.horizontal, MusicSpace.sm).frame(height: 30)
            .background(hovering ? ColorTokens.line : Color.clear, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).strokeBorder(ColorTokens.lineStrong, lineWidth: 1))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(Localized.string("Back")).musicTooltip(verbatim: "Back (⌘[)")
        .atlas("control.music.backPill")
        .padding(.top, MusicSpace.sm).padding(.leading, MusicSpace.xl)
    }
}
