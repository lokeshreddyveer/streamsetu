import SwiftUI

/// Pick how Music behaves right now. Each card says what changes; ending a mode puts back what it changed.
struct MusicListeningModeSheet: View {
    let hub: MusicHub
    let close: () -> Void
    @State private var modes = MusicListeningModes.shared
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            HStack {
                Text(Localized.string("Listening mode")).font(MusicTokens.sheetTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.musicButton(.glassIcon, size: .regular)
                    .accessibilityLabel(Localized.string("Close")).keyboardShortcut(.cancelAction).atlas("control.music.modesClose")
            }
            Text(Localized.string("A mode changes how the whole app behaves, not only what plays. Your own settings come back when the mode ends.")).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: MusicSpace.sm)], spacing: MusicSpace.sm) {
                    ForEach(MusicListeningMode.allCases) { m in
                        let on = modes.mode == m
                        Button { modes.set(m, hub: hub) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack { Image(systemName: m.symbol).foregroundStyle(on ? accent : ColorTokens.textSecondary); Text(verbatim: m.title).font(Typography.bodyMedium); Spacer(minLength: 0)
                                    if on { Image(systemName: "checkmark.circle.fill").foregroundStyle(accent) } }
                                Text(verbatim: m.detail).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(MusicSpace.sm).frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
                            .background(RoundedRectangle(cornerRadius: MusicCorner.card).fill(on ? accent.opacity(0.14) : ColorTokens.surface))
                            .overlay(RoundedRectangle(cornerRadius: MusicCorner.card).strokeBorder(on ? accent.opacity(0.6) : ColorTokens.line, lineWidth: 1))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : []).atlas("control.music.modesChoose")
                    }
                }
            }
        }
        .padding(MusicSpace.lg)
        .frame(minWidth: 620, idealWidth: 700, minHeight: 560)
    }
}
