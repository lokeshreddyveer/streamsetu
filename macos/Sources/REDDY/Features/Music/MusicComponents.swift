import SwiftUI

// Building blocks shared by every Music screen. They use the same tokens, surfaces and type as Podcasts and the library, and nothing here animates while idle.

/// A square cover (or a circle, when `corner` is half of `size`), with a quiet placeholder until the picture arrives.
struct MusicArtwork: View {
    let thumbs: [MusicThumbnail]
    let size: CGFloat
    let corner: CGFloat
    /// What the picture stands for: with it a missing cover is looked up (a song borrows its album's cover, a person gets their photo).
    var subject: MusicArtworkSubject?
    init(_ thumbs: [MusicThumbnail], size: CGFloat, corner: CGFloat = 8, subject: MusicArtworkSubject? = nil) {
        self.thumbs = thumbs; self.size = size; self.corner = corner; self.subject = subject
    }
    /// A song's cover; with none of its own it shows its album's, or the film's.
    init(track: MusicTrack, size: CGFloat, corner: CGFloat = 8) { self.init(track.thumbnails, size: size, corner: corner, subject: .derive(track)) }
    var body: some View {
        MusicCoverImage(thumbs: thumbs, size: size, corner: corner).artwork(of: subject)
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(ColorTokens.line, lineWidth: 0.75))
            .accessibilityHidden(true)
    }
}

/// The page frame: optional title row, scrolling body, the same width and padding as the Podcasts pages. It remembers where it was scrolled to,
/// shows a back-to-top button on long pages, and hosts the selection bar of any track list inside it.
struct MusicScreen<Trailing: View, Content: View>: View {
    let title: String
    var trailing: Trailing
    var content: Content
    /// What the remembered scroll position is filed under, when the title alone is not unique (two categories can share a name).
    var scrollKey: String?
    init(title: String, scrollKey: String? = nil, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title; self.scrollKey = scrollKey; self.trailing = trailing(); self.content = content()
    }
    var body: some View {
        MusicOverlayHostView(hub: .shared) {
            MusicPageColumn(memoryKey: "screen:" + (scrollKey ?? title)) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: title).font(Typography.pageTitle).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: MusicSpace.sm)
                    trailing
                }
                // room for the side-panel button that floats at the top right while a song is loaded
                .padding(.trailing, MusicHub.shared.player.current != nil ? MusicSpace.huge + MusicSpace.xs : 0)
                content
            }
        }
    }
}

extension MusicScreen where Trailing == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) { self.title = title; self.trailing = EmptyView(); self.content = content() }
}

struct MusicSectionTitle: View {
    let title: String
    var body: some View { Text(verbatim: title).font(Typography.title).accessibilityAddTraits(.isHeader) }
}

enum MusicLayout {
    /// The grid every page of cards uses: as many 140 to 190 pt columns as fit.
    static let gridColumns = [GridItem(.adaptive(minimum: 140, maximum: 190), spacing: 16, alignment: .top)]
    /// The page frame every page shares: margin and content cap come from `MusicLayoutGrid` (see `MusicPageFrame`).
    static func frame(available: CGFloat) -> MusicPageFrame { MusicPageFrame.resolve(available: available) }
}

extension LayoutDensity {
    /// Cover size and row padding of a Music track row follow the app's density.
    var musicCover: CGFloat { switch self { case .comfortable: 40; case .compact: 36; case .extraCompact: 32 } }
    var musicRowPadding: CGFloat { switch self { case .comfortable: 5; case .compact: 3; case .extraCompact: 2 } }
}

/// Artist names of a song, each its own click target that opens that artist. A name without an id (a local file) is plain text.
struct MusicArtistLinks: View {
    /// A compilation credit ("Various Artists") is a label, never a link.
    private let given: [MusicArtistRef]
    private var artists: [MusicArtistRef] { given.filter { MusicCompilationArtist.isUsableArtist($0) } }
    let providerID: String
    let hub: MusicHub
    var font: Font = Typography.caption
    var rest: Color = ColorTokens.textSecondary
    var hover: Color = ColorTokens.textPrimary

    init(artists: [MusicArtistRef], providerID: String, hub: MusicHub, font: Font = Typography.caption,
         rest: Color = ColorTokens.textSecondary, hover: Color = ColorTokens.textPrimary) {
        self.given = artists; self.providerID = providerID; self.hub = hub; self.font = font; self.rest = rest; self.hover = hover
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(artists.prefix(3).enumerated()), id: \.offset) { i, a in
                if a.id.isEmpty { Text(verbatim: MusicNativeNames.shared.artist(a, provider: providerID) ?? a.name).font(font).foregroundStyle(rest) }
                else { MusicInlineLink(title: MusicNativeNames.shared.artist(a, provider: providerID) ?? a.name, font: font, label: Localized.string("Open artist %@", a.name), rest: rest, hover: hover) { hub.openArtist(hub.artist(from: a, providerID: providerID), role: .singer) } }
                if i < min(artists.count, 3) - 1 { Text(verbatim: ", ").font(font).foregroundStyle(rest) }
            }
            if artists.count > 3 { Text(verbatim: "…").font(font).foregroundStyle(rest) }
        }
        .lineLimit(1)
    }
}

/// The artist line under a song's title anywhere in Music: every real artist is a link to their page, a song with no usable artist ids keeps its plain
/// line. One place for it, so the rows, the players and the panels all behave the same.
struct MusicTrackArtistLine: View {
    let track: MusicTrack
    let hub: MusicHub
    var font: Font = Typography.caption
    var rest: Color = ColorTokens.textSecondary
    var hover: Color = ColorTokens.textPrimary
    var body: some View {
        if track.artists.contains(where: { !$0.id.isEmpty && MusicCompilationArtist.isUsableArtist($0) }) {
            MusicArtistLinks(artists: track.artists, providerID: track.providerID, hub: hub, font: font, rest: rest, hover: hover)
        } else {
            Text(verbatim: track.displayArtistLine).font(font).foregroundStyle(rest).lineLimit(1)
        }
    }
}

/// A line of text that opens something: underlined on hover, secondary colour at rest.
struct MusicInlineLink: View {
    let title: String
    var font: Font = Typography.caption
    var label: String
    var rest: Color = ColorTokens.textSecondary
    var hover: Color = ColorTokens.textPrimary
    /// False when the thing has no id to open (an album with an empty id): the name is then plain text, never a link to somebody else's page.
    var isLink = true
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        if !isLink {
            Text(verbatim: title).font(font).lineLimit(1).foregroundStyle(rest)
        } else {
        Button(action: action) {
            Text(verbatim: title).font(font).underline(hovering).lineLimit(1)
                .foregroundStyle(hovering ? hover : rest)
        }
        .buttonStyle(.plain).onHover { hovering = $0 }.accessibilityLabel(LocalizedStringKey(label)).atlas("control.music.sharedPartsMusicinlinelinkbodyButton")
        }
    }
}

/// What a track list asks of each row: which columns to show, and how a click behaves while picking rows.
struct MusicRowOptions {
    var columns = MusicTrackColumns.standard
    /// Which optional columns any row of the list has data for; a column nobody has data for is not drawn.
    var cellData = MusicTrackCells.Data.all
    var selecting = false
    var isSelected = false
    /// Handles a click while a selection exists or a modifier key is held; returns true when it took the click.
    var handleClick: ((MusicTrack, MusicTrackSelection.Click) -> Bool)?
    var onAppear: (() -> Void)?
    var onDisappear: (() -> Void)?
    /// Set on the rows of a chart: resolving, version note and unavailable states, and the tap that resolves the row first.
    var chart: MusicChartRowHooks?
    /// A quiet text at the end of the row (the play count in the Most played order). Nil for every other list.
    var trailingDetail: String?
}

/// One track as a row: cover (or number), title, artists (each a link), optional album, an "in your playlists" mark, length, like and a menu.
/// Clicking plays `queue` from this track; with Cmd or Shift held, or while picking rows, it selects instead.
struct MusicTrackRow: View {
    let track: MusicTrack
    var index: Int?
    let queue: [MusicTrack]
    let hub: MusicHub
    var hostRemove: (label: String, action: () -> Void)?
    var fromPlaylist: UUID?
    var options = MusicRowOptions()
    @Environment(\.reddyAccent) private var accent
    @Environment(\.reddyDensity) private var density
    @State private var hovering = false
    @FocusState private var focused: Bool
    /// True only while focus came from the keyboard; a click never draws the ring.
    @State private var keyboardFocus = false

    init(track: MusicTrack, index: Int?, queue: [MusicTrack], hub: MusicHub,
         hostRemove: (label: String, action: () -> Void)? = nil, fromPlaylist: UUID? = nil, options: MusicRowOptions = MusicRowOptions()) {
        self.track = track; self.index = index; self.queue = queue; self.hub = hub
        self.hostRemove = hostRemove; self.fromPlaylist = fromPlaylist; self.options = options
    }

    /// The widest the title column grows when artist and album columns sit beside it.
    static let titleColumnMax: CGFloat = 340

    private var isCurrent: Bool { hub.player.current?.uid == track.uid }
    /// The clean title for a video-style upload; nil (the title as it is) for the person's own library and for titles without noise. The raw title is the tooltip.
    private var display: MusicDisplayTitle.Result? { MusicDisplayTitle.display(for: track) }
    private var liked: Bool { hub.library.isLiked(track) }
    private var blocked: Bool { hub.library.isBlacklisted(track) }
    private var chartUnavailable: Bool { options.chart?.status.phase == .unavailable }
    private var failureReason: String? { hub.player.failureReason(for: track.uid) }
    private var failed: Bool { failureReason != nil }
    private var cols: MusicTrackColumns { options.columns }
    private var showsArtistColumn: Bool { cols.has(.artist) && options.cellData.artist }
    private var showsAlbumColumn: Bool { cols.has(.album) && options.cellData.album }
    private var showsDurationColumn: Bool { cols.has(.duration) && options.cellData.duration }
    private var creditedArtists: [MusicArtistRef] { MusicTrackCells.artists(of: track) }
    private var inPlaylists: [String] {
        let names = MusicMembershipCache.shared.names(for: track.uid, in: hub.library.playlists)
        guard let own = fromPlaylist.flatMap({ hub.library.playlist(id: $0)?.name }) else { return names }
        return names.filter { $0 != own }
    }

    var body: some View {
        HStack(spacing: 10) {
            if options.selecting { checkbox }
            HStack(spacing: 12) {
                leading
                titleBlock
                if showsArtistColumn {
                    MusicArtistLinks(artists: creditedArtists, providerID: track.providerID, hub: hub, font: Typography.row)
                        .frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
                }
                if showsAlbumColumn { albumColumn.frame(minWidth: 80, maxWidth: .infinity, alignment: .leading) }
                if !showsArtistColumn && !showsAlbumColumn { Spacer(minLength: 8) }
                trailing
            }
            .contentShape(Rectangle())
            .onTapGesture { activate() }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel([track.title, MusicTrackCells.artistLine(of: track), options.chart.map { $0.versions.count > 1 ? Localized.plural($0.versions.count, one: "%@ version", other: "%@ versions") : "" } ?? ""].filter { !$0.isEmpty }.joined(separator: ", "))
            .accessibilityHint(options.selecting ? "Selects this track" : "Plays this track").atlas("control.music.sharedPartsMusictrackrowbodyOnTapGesture")

            Button { MusicEntityActions.toggleLike(track, hub: hub) } label: {
                Image(systemName: liked ? "heart.fill" : "heart").font(MusicTokens.iconMedium).foregroundStyle(liked ? accent : ColorTokens.textSecondary)
                    .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel(liked ? "Unlike" : "Like").atlas("control.music.sharedPartsMusictrackrowbodyButton")

            Menu { menuItems } label: {
                Image(systemName: "ellipsis").font(MusicTokens.iconMedium).foregroundStyle(ColorTokens.textSecondary).frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(ColorTokens.textSecondary).accessibilityLabel("More actions for \(track.title)").atlas("control.music.sharedPartsMoreActionsFor")
        }
        .padding(.horizontal, 8).padding(.vertical, density.musicRowPadding)
        .background(options.isSelected ? accent.opacity(MusicTokens.flashFill) : .clear, in: RoundedRectangle(cornerRadius: MusicTokens.radiusRow, style: .continuous))
        .overlay { if MusicRowMarkerState.showsFocusRing(focused: focused, keyboard: keyboardFocus) { RoundedRectangle(cornerRadius: MusicTokens.radiusRow, style: .continuous).strokeBorder(accent, lineWidth: 1.5).allowsHitTesting(false) } }
        .opacity(blocked || chartUnavailable ? 0.45 : 1)
        .help(options.chart?.status.reason ?? "")
        .hoverHighlight()
        .onHover { hovering = $0 }
        .focusable().focusEffectDisabled().focused($focused)
        .onChange(of: focused) { _, now in keyboardFocus = now && !hovering }
        .onKeyPress(.return) { keyboardFocus = true; activate(); return .handled }
        .onKeyPress(.space) { keyboardFocus = true; activate(); return .handled }
        .onDrag { MusicEntity.track(track).dragProvider() }
        .contextMenu { menuItems }
        .onAppear { options.onAppear?() }
        .onDisappear { options.onDisappear?() }.atlas("control.music.sharedPartsMusictrackrowbodyContextMenu")
    }

    private var checkbox: some View {
        Image(systemName: options.isSelected ? "checkmark.circle.fill" : "circle")
            .font(MusicTokens.iconLarge).foregroundStyle(options.isSelected ? accent : ColorTokens.textTertiary)
            .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).accessibilityHidden(true)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(verbatim: display?.title ?? track.title).font(Typography.bodyMedium).fontWeight(isCurrent ? .semibold : nil).lineLimit(1).foregroundStyle(isCurrent ? accent : ColorTokens.textPrimary)
                    .help(display?.raw ?? "")
                if let c = options.chart, c.versions.count > 1 { MusicChartVersionChip(hooks: c) }
                if track.explicit { Image(systemName: "e.square.fill").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textTertiary).accessibilityLabel("Explicit") }
                if let c = options.chart { MusicChartRowAccessory(status: c.status) }
                if failed { Image(systemName: "exclamationmark.triangle.fill").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.danger).help(failureReason ?? "").accessibilityLabel(failureReason ?? "Could not be played. See Music Settings, About, for the reason.") }
                if failed, options.chart == nil {
                    Button(Localized.string("Find another version")) { MusicDebugLog.log("playlist", "find another version for \(track.uid)"); hub.chooseAudioSource(for: track) }
                        .buttonStyle(.plain).font(Typography.captionMedium).foregroundStyle(accent).accessibilityLabel("Find another version of this song").atlas("control.music.playlistFindAnotherVersion")
                }
            }
            if !showsArtistColumn, !creditedArtists.isEmpty {
                MusicArtistLinks(artists: creditedArtists, providerID: track.providerID, hub: hub)
            }
            if let sub = display?.subtitle, !sub.isEmpty, MusicCatalogNames.film(for: track) == nil {
                Text(verbatim: sub).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary).lineLimit(1)
            } else if showsArtistColumn && showsAlbumColumn {
                // A table row already has its artist and album columns: no second line, so the title sits on the same line as the other columns.
                EmptyView()
            } else {
                // music director, film and cast as links; one reserved line, so the row does not change height when the graph answers
                MusicTrackContextLine(track: track, hub: hub, fallbackFilm: MusicCatalogNames.film(for: track))
            }
        }
        // With artist and album columns the title keeps a generous but bounded share, so the other columns are not squeezed to a stub beside a wide empty title.
        .frame(minWidth: 120, maxWidth: showsArtistColumn || showsAlbumColumn ? Self.titleColumnMax : nil, alignment: .leading)
        .layoutPriority(1)
    }

    @ViewBuilder private var albumColumn: some View {
        if let al = track.album, !al.title.isEmpty {
            MusicInlineLink(title: al.title, font: Typography.row, label: "Open album \(al.title)", isLink: al.hasPage) { hub.open(.album(hub.album(from: al, providerID: track.providerID))) }
        } else { Text(verbatim: "") }
    }

    @ViewBuilder private var trailing: some View {
        let lists = inPlaylists
        if let detail = options.trailingDetail {
            Text(verbatim: detail).font(Typography.caption).monospacedDigit().foregroundStyle(ColorTokens.textTertiary).lineLimit(1).fixedSize()
        }
        if !lists.isEmpty {
            Image(systemName: "music.note.list").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textTertiary)
                .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget)
                .help(Localized.string("In your playlists: %@", lists.prefix(5).joined(separator: ", ")))
                .accessibilityLabel(Localized.plural(lists.count, one: "In %@ of your playlists", other: "In %@ of your playlists"))
        }
        if cols.has(.duration), let text = MusicTrackCells.durationText(ms: track.durationMs, columnShown: showsDurationColumn) {
            Text(verbatim: text).font(Typography.timestamp).monospacedDigit().foregroundStyle(ColorTokens.textTertiary).frame(width: 48, alignment: .trailing)
        }
    }

    @ViewBuilder private var leading: some View {
        let size = density.musicCover
        if let index {
            ZStack {
                if hovering { Image(systemName: "play.fill").font(MusicTokens.iconSmall).foregroundStyle(accent) }
                else if isCurrent { MusicCurrentRowGlyph(isPlaying: hub.player.isPlaying) }
                else { Text(verbatim: "\(options.chart?.status.rank ?? index + 1)").font(Typography.timestamp).foregroundStyle(ColorTokens.textTertiary) }
            }
            .frame(width: 28)
        } else {
            MusicArtwork(track: track, size: size, corner: MusicTokens.radiusRow)
                .overlay {
                    if isCurrent || hovering {
                        RoundedRectangle(cornerRadius: MusicTokens.radiusRow, style: .continuous).fill(MusicTokens.scrim)
                        if isCurrent && !hovering { MusicCurrentRowGlyph(isPlaying: hub.player.isPlaying) }
                        else { Image(systemName: "play.fill").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textPrimary) }
                    }
                }
        }
    }

    private func activate() {
        if options.selecting || MusicClickModifiers.current != .plain {
            let kind = MusicClickModifiers.current
            if options.handleClick?(track, kind) == true { return }
        }
        play()
    }

    private func play() {
        if let chart = options.chart { chart.play(); return }
        if let i = queue.firstIndex(where: { $0.uid == track.uid }) { hub.play(queue, at: i) } else { hub.play([track], at: 0) }
    }

    @ViewBuilder private var menuItems: some View {
        Button("Play", systemImage: "play.fill") { play() }.atlas("control.music.sharedPartsPlay")
        if let c = options.chart, c.versions.count > 1 { Menu(Localized.string("Choose version"), systemImage: "rectangle.stack") { MusicChartVersionButtons(hooks: c) }.atlas("control.music.chartChooseVersionMenu") }
        MusicTrackMenuContent(track: track, hub: hub, hostRemove: hostRemove, fromPlaylist: fromPlaylist)
    }
}

