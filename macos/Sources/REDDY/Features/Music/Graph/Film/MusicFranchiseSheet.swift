import SwiftUI

/// Every film of a franchise in release order, each opening its own page. Only films a source says belong to it are listed.
struct MusicFranchiseSheet: View {
    let hub: MusicHub
    let film: MusicEntityID
    let fallbackName: String
    let close: () -> Void
    @State private var franchise: MusicFranchise?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            HStack {
                Text(verbatim: franchise?.name ?? fallbackName).font(MusicTokens.sheetTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.musicButton(.glassIcon, size: .regular)
                    .accessibilityLabel(Localized.string("Close")).keyboardShortcut(.cancelAction).atlas("control.music.franchiseClose")
            }
            if !loaded { MusicLoadingIcon(size: MusicIconSize.small).frame(maxWidth: .infinity, minHeight: 80) }
            else if let f = franchise {
                Text(Localized.plural(f.films.count, one: "%@ film in this franchise", other: "%@ films in this franchise")).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(f.films) { m in
                            Button { close(); hub.open(m.id) } label: {
                                HStack {
                                    Text(verbatim: m.name).font(Typography.bodyMedium).lineLimit(1)
                                    Spacer()
                                    if let y = m.year { Text(verbatim: String(y)).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).monospacedDigit() }
                                    if m.current { Image(systemName: "checkmark").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textSecondary) }
                                }.frame(minHeight: MusicTokens.hitTarget).contentShape(Rectangle())
                            }.buttonStyle(.plain).hoverHighlight().disabled(m.current).atlas("control.music.franchiseFilm")
                        }
                    }
                }
            } else {
                Text(Localized.string("No other films of this franchise are known yet.")).musicText(.secondary).foregroundStyle(ColorTokens.textTertiary)
            }
        }
        .padding(MusicSpace.lg)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 320)
        .task {
            franchise = await MusicFranchise.load(for: film, store: MusicEntityRuntime.shared.center.store.graph)
            loaded = true
        }
    }
}
