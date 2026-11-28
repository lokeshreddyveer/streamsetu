import SwiftUI

/// The header of every playlist page (the person's own, a service's, a chart): a large cover, the title (renamed in place when the page allows it), the
/// owner as a link when it has a page, a description clamped to three lines with More and Less, one quiet stat line, and the action row. The colour behind
/// it is the cover's own (`MusicHeroBackdrop`, whose picture is drawn over the surface and so never sets the header's size). It carries no source,
/// provider or credit line.
struct MusicPlaylistHeader<Cover: View, Actions: View>: View {
    let title: String
    var kind = ""
    /// The creator's name and, when they have a page, what opens it.
    var owner: String?
    var onOwner: (() -> Void)?
    var description = ""
    /// For a playlist the person owns and has not described: shows "Add a description" and runs this.
    var onAddDescription: (() -> Void)?
    var stats = ""
    var backdrop: [MusicThumbnail] = []
    /// Set for the person's own playlists: a click on the title edits it, Return saves, Escape cancels.
    var onRename: ((String) -> Void)?
    @ViewBuilder var cover: () -> Cover
    @ViewBuilder var actions: () -> Actions

    @State private var expanded = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var titleFocused: Bool
    @Environment(\.musicLayoutClass) private var layoutClass
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var primaryInk: Color { reduceTransparency ? ColorTokens.textPrimary : MusicInk.onArtwork }
    private var secondaryInk: Color { reduceTransparency ? ColorTokens.textSecondary : MusicInk.onArtworkSecondary }
    private var compact: Bool { layoutClass == .compact }

    var body: some View {
        let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: MusicSpace.md)) : AnyLayout(HStackLayout(alignment: .bottom, spacing: MusicSpace.xl))
        layout {
            cover().shadow(color: MusicInk.scrim(.light), radius: 18, y: 8)
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                if !kind.isEmpty { Text(verbatim: kind.uppercased()).font(Typography.eyebrow).tracking(1.2).foregroundStyle(secondaryInk) }
                titleView
                if let owner, !owner.isEmpty { ownerLine(owner) }
                descriptionView
                if !stats.isEmpty { Text(verbatim: stats).font(Typography.caption).foregroundStyle(secondaryInk).lineLimit(2) }
                MusicGraphFlowLayout(spacing: 10) { actions() }.padding(.top, MusicSpace.xxs)
            }
            if !compact { Spacer(minLength: 0) }
        }
        .padding(MusicSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { MusicHeroBackdrop(thumbs: backdrop) }
        .clipShape(RoundedRectangle(cornerRadius: MusicCorner.cardLarge, style: .continuous))
    }

    // MARK: title

    @ViewBuilder private var titleView: some View {
        if editing {
            TextField("Playlist name", text: $draft)
                .textFieldStyle(.plain).font(Typography.pageTitle).foregroundStyle(primaryInk).focused($titleFocused)
                .onSubmit { commitTitle() }
                .onAppear { titleFocused = true }
                #if os(macOS)
                .onExitCommand { editing = false }
                #endif
                .onChange(of: titleFocused) { _, focused in if !focused, editing { commitTitle() } }
                .accessibilityLabel("Playlist name").atlas("control.music.playlistTitleField")
        } else if onRename != nil {
            Button { draft = title; editing = true; titleFocused = true; MusicDebugLog.log("playlist", "rename in place started") } label: {
                Text(verbatim: title).font(Typography.pageTitle).foregroundStyle(primaryInk).lineLimit(3).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain).help("Click to rename").accessibilityAddTraits(.isHeader).accessibilityHint("Renames the playlist").atlas("control.music.playlistTitleRename")
        } else {
            Text(verbatim: title).font(Typography.pageTitle).foregroundStyle(primaryInk).lineLimit(3).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
        }
    }

    private func commitTitle() {
        let n = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = false
        if !n.isEmpty, n != title { onRename?(n) }
    }

    // MARK: owner

    @ViewBuilder private func ownerLine(_ name: String) -> some View {
        if let onOwner {
            MusicInlineLink(title: name, font: Typography.bodyMedium, label: "Open \(name)", rest: primaryInk.opacity(0.9), hover: primaryInk) { onOwner() }
        } else {
            Text(verbatim: name).font(Typography.bodyMedium).foregroundStyle(primaryInk.opacity(0.9)).lineLimit(1)
        }
    }

    // MARK: description

    @ViewBuilder private var descriptionView: some View {
        if !description.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: description).font(Typography.body).foregroundStyle(primaryInk.opacity(0.9)).lineLimit(expanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 620, alignment: .leading)
                if MusicPlaylistActionRules.descriptionNeedsMore(description, compact: compact) {
                    Button(expanded ? "Less" : "More") { withAnimation(AnimationTokens.standard) { expanded.toggle() } }
                        .buttonStyle(.plain).font(Typography.captionMedium).foregroundStyle(primaryInk)
                        .accessibilityLabel(expanded ? "Show less of the description" : "Show more of the description").atlas("control.music.playlistDescriptionMore")
                }
            }
        } else if let onAddDescription {
            Button("Add a description", action: onAddDescription)
                .buttonStyle(.plain).font(Typography.body).foregroundStyle(secondaryInk).atlas("control.music.playlistAddDescription")
        }
    }
}

/// The small icon buttons of the action row. Shared by the own and the service's playlist page so both look the same.
struct MusicPlaylistIconButton: View {
    let symbol: String
    let label: String
    let atlasID: String
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(MusicTokens.iconLarge) }.atlas("control.music.playlistIconButton")
            .musicButton(.glassIcon, size: .large).disabled(disabled)
            .accessibilityLabel(LocalizedStringKey(label)).help(LocalizedStringKey(label)).atlas(atlasID)
    }
}
