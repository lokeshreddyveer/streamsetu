import SwiftUI

// Small shared pieces for Music's sheets, so a sheet is not made of stock system controls: a capsule search box, a row of choice chips instead of a segmented bar, and
// a menu that looks like a chip. All of them take their colours from the theme (the accent and the surface tokens), so they follow the palette the person chose.

/// A search box in the app's own style: capsule, a quiet icon, and an accent edge while it has focus.
struct MusicSheetField: View {
    let placeholder: String
    @Binding var text: String
    var symbol = "magnifyingglass"
    let atlas: String
    @FocusState private var focused: Bool
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        HStack(spacing: MusicSpace.xs) {
            Image(systemName: symbol).font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textTertiary).accessibilityHidden(true)
            TextField(placeholder, text: $text).textFieldStyle(.plain).musicText(.body).focused($focused).atlas(atlas)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(MusicTokens.iconSmall) }
                    .buttonStyle(.plain).foregroundStyle(ColorTokens.textSecondary).accessibilityLabel(Localized.string("Clear")).atlas("control.music.sheetFieldClear")
            }
        }
        .padding(.horizontal, MusicSpace.sm)
        .frame(height: MusicTokens.hitTarget + MusicSpace.xxs)
        .podcastFieldStyle(focused: focused, accent: accent)
    }
}

/// Two or three choices shown as chips (the chosen one is marked), for what a segmented bar would show.
struct MusicChoiceChips<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: MusicSpace.xs) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                MusicChip(title: o.title, selected: selection == o.value) { selection = o.value }
            }
        }
    }
}

/// A menu with the look of a chip: the name of the choice alone while nothing is chosen, "Name: choice" in the accent colour once something is.
struct MusicMenuChip<Value: Hashable>: View {
    let label: String
    let anyTitle: String
    let options: [(value: Value, title: String)]
    @Binding var selection: Value?
    let atlas: String
    @Environment(\.reddyAccent) private var accent

    private var current: String? { options.first { $0.value == selection }?.title }

    var body: some View {
        Menu {
            Picker(label, selection: $selection) {
                Text(anyTitle).tag(Value?.none)
                ForEach(Array(options.enumerated()), id: \.offset) { _, o in Text(o.title).tag(Optional(o.value)) }
            }.pickerStyle(.inline).atlas("control.music.menuChipChoice")
        } label: {
            HStack(spacing: 5) {
                Text(verbatim: current.map { label + ": " + $0 } ?? label)
                Image(systemName: "chevron.down").font(.system(size: MusicIconSize.tiny, weight: .bold)).accessibilityHidden(true)
            }
            .foregroundStyle(current == nil ? ColorTokens.textSecondary : accent)
            .musicChipSurface()
            .overlay(Capsule().strokeBorder(current == nil ? Color.clear : accent.opacity(0.65), lineWidth: 1))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().atlas("control.music.menuChip")
    }
}

/// A rounded surface that groups a few related controls.
struct MusicSheetCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(MusicSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ColorTokens.elevated.opacity(0.5), in: RoundedRectangle(cornerRadius: MusicCorner.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: MusicCorner.card, style: .continuous).strokeBorder(ColorTokens.line, lineWidth: 0.75))
    }
}
