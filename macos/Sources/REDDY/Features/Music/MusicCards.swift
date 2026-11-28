import SwiftUI

// Cards: a cover with a title and a line under it. Geometry comes from `MusicCardGeometry` so skeletons and shelves match the final card exactly.

/// Pure card geometry. The skeleton, the shelf paging maths and the card itself read these numbers, so a placeholder never differs from the
/// card that replaces it.
enum MusicCardGeometry {
    /// Width of a card in a shelf when the caller gives none.
    static let defaultWidth: CGFloat = MusicCardSize.standard.width
    /// Artwork scale on hover; the layout box never changes (the scaled cover is clipped to its own frame).
    static let hoverScale: CGFloat = 1.03
    /// Corner of a round (artist) cover: larger than half of any card side, so it is always a circle.
    static let roundCorner: CGFloat = 400
    static let coverToText: CGFloat = MusicSpace.xs
    static let textSpacing: CGFloat = MusicSpace.xxs
    /// Line boxes are the type role's point size times this leading.
    static let leading: CGFloat = 1.3
    static var titleLineHeight: CGFloat { (MusicTypeRole.card.pointSize * leading).rounded(.up) }
    static var subtitleLineHeight: CGFloat { (MusicTypeRole.caption.pointSize * leading).rounded(.up) }
    /// Height of the title and subtitle block (one line each; a longer title may grow the card, a placeholder never does).
    static var textBlockHeight: CGFloat { titleLineHeight + textSpacing + subtitleLineHeight }

    static func coverSide(width: CGFloat) -> CGFloat { max(0, width) }
    static func height(width: CGFloat) -> CGFloat { coverSide(width: width) + coverToText + textBlockHeight }
    /// Gap between cards in a shelf.
    static let shelfSpacing: CGFloat = MusicSpace.sm
    /// Distance from one card's leading edge to the next.
    static func step(width: CGFloat) -> CGFloat { width + shelfSpacing }
}

/// Card widths by use. The artwork class asked of the artwork service follows the kind of card (`MusicCard.artworkClass`).
enum MusicCardSize: CaseIterable, Sendable {
    case compact, standard, large
    var width: CGFloat {
        switch self {
        case .compact: 128
        case .standard: 150
        case .large: 190
        }
    }
}

/// A cover with a title and a line under it. In a shelf it is 150 pt wide; in a grid it fills its cell. Given the item it stands for, it also gets
/// the full right-click menu, a play button that appears on hover or focus, and can be dragged onto a playlist or the queue.
/// Hover scales the artwork about 3 percent inside its own frame and draws a stroke; nothing resizes and no resting shadow is cast.
struct MusicCard: View {
    let title: String
    var subtitle: String?
    var thumbs: [MusicThumbnail] = []
    var round = false
    var width: CGFloat? = MusicCardGeometry.defaultWidth
    var entity: MusicEntity?
    var hub: MusicHub?
    /// What the card stands for, so a missing picture can be found (a person's photo, a film's poster, an album's cover). Without one it is taken from
    /// `entity`, or from the title when the card is round (a person).
    var subject: MusicArtworkSubject?
    /// A cover of the card's own (a playlist's composed 2x2); it takes the place of the picture and keeps the card's frame, hover and focus look.
    var coverOverride: AnyView?
    /// What the hover disc and the menu's Play do when that is more than playing the entity alone (a song on a shelf plays on through the shelf).
    var playAction: (() -> Void)?
    let action: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool
    @FocusState private var playFocused: Bool
    @Environment(\.reddyAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(title: String, subtitle: String? = nil, thumbs: [MusicThumbnail], round: Bool = false, width: CGFloat? = MusicCardGeometry.defaultWidth,
         entity: MusicEntity? = nil, hub: MusicHub? = nil, subject: MusicArtworkSubject? = nil, coverOverride: AnyView? = nil, playAction: (() -> Void)? = nil,
         action: @escaping () -> Void) {
        self.title = title; self.subtitle = subtitle; self.thumbs = thumbs; self.round = round; self.width = width
        self.entity = entity; self.hub = hub; self.subject = subject; self.coverOverride = coverOverride; self.playAction = playAction; self.action = action
    }

    private var theHub: MusicHub { hub ?? .shared }
    private var showsPlay: Bool { entity != nil && !round }
    private var playVisible: Bool { hovering || focused || playFocused }
    private var corner: CGFloat { round ? MusicCardGeometry.roundCorner : MusicCorner.card }
    /// The class the artwork service sizes this cover for.
    var artworkClass: MusicArtworkClass { round ? .artistPortrait : .tile }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: corner, style: .continuous) }
    /// Picks the fallback colour per item, so items that share one cover (or have none) still differ.
    private var fallbackSeed: String { title + "|" + (subtitle ?? "") }

    var body: some View {
        card
            .contextMenu { if let entity { MusicCardMenu(entity: entity, hub: theHub, play: playAction) } }
            .musicDrag(entity)
            .onHover { hovering = $0 }.atlas("control.music.sharedPartsMusiccardbodyContextMenu")
    }

    private var resolvedSubject: MusicArtworkSubject? {
        if let subject { return subject }
        if let entity { return .derive(entity) }
        return round ? .personNamed(title) : nil
    }

    private var cover: some View {
        Group {
            if let coverOverride { coverOverride }
            else { MusicCoverImage(thumbs: thumbs, artworkClass: artworkClass, corner: corner, seed: fallbackSeed, initials: round ? MusicArtistPortrait.initials(title) : nil, subject: resolvedSubject) }
        }
            .aspectRatio(1, contentMode: .fit)
            .scaleEffect(hovering && !reduceMotion ? MusicCardGeometry.hoverScale : 1)
            .clipShape(shape)
            .overlay(shape.strokeBorder(ColorTokens.line, lineWidth: 0.75))
            .musicHoverLift(hovering, cornerRadius: corner)
            .overlay(shape.strokeBorder(accent, lineWidth: 2).opacity(focused ? 1 : 0).allowsHitTesting(false))
            .musicAnimation(.hover, reduce: reduceMotion, value: hovering)
            .musicAnimation(.focus, reduce: reduceMotion, value: focused)
    }

    private var card: some View {
        Button(action: action) {
            VStack(alignment: round ? .center : .leading, spacing: MusicCardGeometry.coverToText) {
                cover
                VStack(alignment: round ? .center : .leading, spacing: MusicCardGeometry.textSpacing) {
                    Text(verbatim: title).musicText(.card).lineLimit(2).multilineTextAlignment(round ? .center : .leading).foregroundStyle(ColorTokens.textPrimary)
                    if let subtitle, !subtitle.isEmpty {
                        Text(verbatim: subtitle).musicText(.caption).lineLimit(1).foregroundStyle(ColorTokens.textSecondary)
                    }
                }
                .frame(minHeight: MusicCardGeometry.textBlockHeight, alignment: .top)
            }
            .frame(width: width, alignment: round ? .center : .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: round ? .center : .leading)
            .frame(minHeight: MusicTokens.hitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .overlay(alignment: .top) {
            if showsPlay {
                Color.clear.aspectRatio(1, contentMode: .fit)
                    .overlay(alignment: .bottomTrailing) { playButton.padding(MusicSpace.sm) }
            }
        }
        .accessibilityLabel(subtitle.map { "\(title), \($0)" } ?? title).atlas("control.music.sharedPartsMusiccardcardButton")
    }

    /// The play affordance: a solid accent disc with a hairline edge. No shadow (the old per-card shadow cost a blur pass for every card on screen).
    private var playButton: some View {
        Button {
            guard let entity else { return }
            if let playAction { playAction() } else if case .track(let t) = entity { theHub.play([t], at: 0) } else { Task { await MusicEntityActions.play(entity, hub: theHub) } }
        } label: {
            Image(systemName: "play.fill").font(MusicTokens.iconMedium).foregroundStyle(ColorTokens.onAccent(accent))
                .frame(width: MusicTokens.hitTarget + MusicSpace.xs, height: MusicTokens.hitTarget + MusicSpace.xs)
                .background(accent, in: Circle())
                .overlay(Circle().strokeBorder(MusicInk.hairlineOnArtwork, lineWidth: 0.75))
                .overlay(Circle().strokeBorder(accent, lineWidth: 2).padding(-MusicSpace.xxs).opacity(playFocused ? 1 : 0))
                .contentShape(Circle())
        }
        .buttonStyle(.plain).focused($playFocused)
        .opacity(playVisible ? 1 : 0)
        .allowsHitTesting(playVisible)
        .musicAnimation(.hover, reduce: reduceMotion, value: playVisible)
        .accessibilityLabel("Play \(title)").musicTooltip("Play").atlas("control.music.cardPlay")
    }
}

extension MusicCard {
    init(album a: MusicAlbum, hub: MusicHub, width: CGFloat? = MusicCardGeometry.defaultWidth, subtitle: String? = nil) {
        self.init(title: MusicNativeNames.shared.album(title: a.title, provider: a.providerID, id: a.id) ?? a.title, subtitle: subtitle ?? MusicHeroText.cardCredit(a.artists), thumbs: a.thumbnails, width: width, entity: .album(a), hub: hub) { hub.open(.album(a)) }
    }
    init(artist a: MusicArtist, hub: MusicHub, width: CGFloat? = MusicCardGeometry.defaultWidth, subtitle: String? = nil) {
        self.init(title: MusicNativeNames.shared.artist(MusicArtistRef(id: a.id, name: a.name), provider: a.providerID) ?? a.name, subtitle: subtitle ?? Localized.string("Artist"), thumbs: MusicArtistPortrait.portraits(a.thumbnails), round: true, width: width, entity: .artist(a), hub: hub) { hub.open(.artist(a)) }
    }
    init(playlist p: MusicPlaylist, hub: MusicHub, width: CGFloat? = MusicCardGeometry.defaultWidth) {
        self.init(title: p.name, subtitle: MusicPlaylistCaption.line(p), thumbs: p.thumbnails, width: width, entity: .playlist(p), hub: hub) { MusicEntityActions.open(.playlist(p), hub: hub) }
    }
    init(track t: MusicTrack, queue: [MusicTrack] = [], hub: MusicHub, width: CGFloat? = MusicCardGeometry.defaultWidth) {
        let shown = MusicDisplayTitle.display(for: t)
        let start = {
            let plan = MusicCard.startPlan(t, queue: queue)
            hub.play(plan.tracks, at: plan.index)
        }
        self.init(title: shown?.title ?? t.title, subtitle: MusicHeroText.cardCredit(t.artists), thumbs: t.thumbnails, width: width, entity: .track(t), hub: hub,
                  playAction: start, action: start)
    }
    /// What a song card plays: its shelf from this song, or the song alone when the shelf does not hold it.
    nonisolated static func startPlan(_ t: MusicTrack, queue: [MusicTrack]) -> (tracks: [MusicTrack], index: Int) {
        if let i = queue.firstIndex(where: { $0.uid == t.uid }) { (queue, i) } else { ([t], 0) }
    }
    /// A card for any search or browse result.
    /// `queue` is the songs of the shelf the card sits on, so a song played from a shelf continues with the next song there instead of stopping.
    init(result r: MusicBrowseItem, queue: [MusicTrack] = [], hub: MusicHub, width: CGFloat? = MusicCardGeometry.defaultWidth) {
        switch r {
        case .album(let a): self.init(album: a, hub: hub, width: width)
        case .artist(let a): self.init(artist: a, hub: hub, width: width)
        case .playlist(let p): self.init(playlist: p, hub: hub, width: width)
        case .track(let t): self.init(track: t, queue: queue, hub: hub, width: width)
        }
    }
}

/// The menu of a card: a song gets the full song menu, anything else the album, playlist or artist menu.
struct MusicCardMenu: View {
    let entity: MusicEntity
    let hub: MusicHub
    /// The card's own Play (a song plays on through its shelf); without one a song plays alone.
    var play: (() -> Void)?
    var body: some View {
        switch entity {
        case .track(let t):
            Button("Play", systemImage: "play.fill") { if let play { play() } else { hub.play([t], at: 0) } }.atlas("control.music.sharedPartsPlay")
            MusicTrackMenuContent(track: t, hub: hub)
        case .album(let a): MusicCardMenuContent(item: .album(a), hub: hub)
        case .playlist(let p): MusicCardMenuContent(item: .playlist(p), hub: hub)
        case .artist(let a): MusicCardMenuContent(item: .artist(a), hub: hub)
        }
    }
}

extension View {
    /// Makes the view draggable as `entity`; nothing is dragged when there is none.
    @ViewBuilder func musicDrag(_ entity: MusicEntity?) -> some View {
        if let entity { self.onDrag { entity.dragProvider() } } else { self }
    }
}


/// A list of cards in an adaptive grid, for the "show all" view of a shelf and for result groups.
struct MusicCardGrid<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { LazyVGrid(columns: MusicLayout.gridColumns, alignment: .leading, spacing: 18) { content } }
}


/// The second line of a playlist's card or row: how many songs it holds, else its own description. Never the source's name or the account that made it ("JioSaavn", a user handle).
enum MusicPlaylistCaption {
    static func line(_ p: MusicPlaylist) -> String {
        if let n = p.trackCount, n > 0 { return Localized.plural(n, one: "%@ song", other: "%@ songs") }
        let text = MusicSourceText.clean(p.summary) ?? ""
        return text.isEmpty ? Localized.string("Playlist") : text
    }
}
