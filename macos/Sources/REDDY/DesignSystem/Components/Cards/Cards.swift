import SwiftUI

// MARK: - Poster artwork

enum PosterTint {
    /// Stable hue (0…360) derived from a title, so a missing poster always gets the same quiet colour.
    static func hue(for title: String) -> Double {
        var h: UInt64 = 1469598103934665603
        for b in title.lowercased().utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return Double(h % 360)
    }

    static func color(hue: Double, saturation: Double, lightness: Double) -> Color {
        // HSL → HSB
        let v = lightness + saturation * min(lightness, 1 - lightness)
        let s = v == 0 ? 0 : 2 * (1 - lightness / v)
        return Color(hue: hue / 360, saturation: s, brightness: v)
    }
}

/// Branded placeholder used while artwork loads and when none exists. Original, abstract, no external assets.
struct PosterPlaceholder: View {
    let title: String
    var detail: String? = nil
    var showsTitle = true
    var body: some View {
        let h = PosterTint.hue(for: title)
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [PosterTint.color(hue: h, saturation: 0.25, lightness: 0.29), PosterTint.color(hue: h, saturation: 0.28, lightness: 0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if !showsTitle {
                GeometryReader { g in Image(systemName: "film").font(.system(size: g.size.width * 0.28, weight: .ultraLight)).foregroundStyle(Color.white.opacity(0.22)).frame(maxWidth: .infinity, maxHeight: .infinity) }
                if let detail { Text(detail).font(.system(size: 10, weight: .medium)).foregroundStyle(ColorTokens.textSecondary).lineLimit(1).padding(12) }
            }
            if showsTitle {
                Text(title.uppercased()).font(.system(size: 17, weight: .regular)).tracking(0.7).lineSpacing(0)
                    .lineLimit(4).minimumScaleFactor(0.7).multilineTextAlignment(.leading)
                    .foregroundStyle(ColorTokens.textPrimary.opacity(0.92)).padding(12).padding(.bottom, detail == nil ? 0 : 16)
                    .overlay(alignment: .bottomLeading) { if let detail { Text(detail).font(.system(size: 10, weight: .medium)).foregroundStyle(ColorTokens.textSecondary).lineLimit(1).padding(12) } }
            }
        }
    }
}

/// Real artwork over the placeholder; the placeholder stays visible if the image is missing or fails.
struct PosterArt: View {
    let title: String
    let url: String?
    var detail: String? = nil
    var kind: ArtworkKind = .poster
    /// False on cards that print the title under the picture.
    var showsTitle = true
    /// The title's id: when its artwork lands while the tile is on screen, the real poster fades in over the placeholder.
    var itemID: String? = nil
    @Environment(\.container) private var container
    @State private var landed: String?
    private var shown: String? { url.nilIfEmpty ?? landed }
    var body: some View {
        ZStack {
            PosterPlaceholder(title: title, detail: detail, showsTitle: showsTitle)
            if shown != nil { ArtworkImage(url: shown, kind: kind, showsPlaceholder: false).transition(.opacity) }
        }
        .animation(.easeIn(duration: 0.25), value: shown)
        .onMetadataLanded(for: itemID ?? "") {
            guard url.nilIfEmpty == nil, let id = itemID, let c = container else { return }
            Task.detached { let p = c.metadata.posterURL(for: id); await MainActor.run { if let p, !p.isEmpty { landed = p } } }
        }
    }
}

// MARK: - Poster card

struct PosterCardModel: Identifiable, Hashable {
    let id: String
    let title: String
    var subtitle: String
    let imageURL: String?
    var tag: String?
    var rank: Int?
    var progress: Double?
    var isFavorite = false
    /// A series with an episode the person has not played yet.
    var isNew = false
    /// Watched to the end: a green tick in the corner.
    var isWatched = false
    /// Folder rows: the title keeps room for two lines and the quiet line is always there, so tiles of a row share one height.
    var reservesLines = false
    /// Shown on the placeholder tile of a title without a poster: "2022 · 4K".
    var placeholderDetail: String?
    /// The cleaned name shown under the tile; nil keeps `title`.
    var displayTitle: String?
    /// The rating worth showing (TMDB's when matched, else the provider's if credible; never 0 or 10.0): the star badge, top right.
    var rating: Double?

    init(item: LibraryItem, rank: Int? = nil, progress: Double? = nil, isFavorite: Bool = false, isNew: Bool = false, isWatched: Bool = false) {
        id = item.id; title = item.title
        subtitle = [item.quietLine.isEmpty ? nil : item.quietLine, item.isSeries ? "Series" : nil].compactMap { $0 }.joined(separator: " · ")
        imageURL = item.posterURL
        rating = RatingRule.credible({ switch item { case .movie(let m): m.rating; case .series(let s): s.rating } }())
        placeholderDetail = ArtworkTile.Content.detail(year: item.year, quality: item.isSeries ? "Series" : MetadataNormalizer.qualityLabel(MetadataNormalizer.normalize(item.title)))
        tag = item.isSeries ? "SERIES" : MetadataNormalizer.qualityLabel(MetadataNormalizer.normalize(item.title)).flatMap { ["4K", "FHD"].contains($0) ? $0 : nil }
        self.rank = rank; self.progress = progress; self.isFavorite = isFavorite; self.isNew = isNew; self.isWatched = isWatched
    }
}

/// A poster with two separate actions: the card opens details, and the coral Play pill starts playback.
/// The buttons are siblings, so Play never bubbles into the details action. Play shows on hover and on keyboard focus.
struct ReddyPosterCard: View {
    let model: PosterCardModel
    var width: CGFloat = 150
    var onOpen: () -> Void
    var onPlay: () -> Void
    @State private var hovering = false
    @State private var landedRating: Double?
    @Environment(\.container) private var container
    @FocusState private var focus: Field?
    @Environment(\.reddyAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum Field { case detail, play }

    private var height: CGFloat { (width * 1.45).rounded() }
    private var showPlay: Bool { hovering || focus != nil }
    private var shownRating: Double? { model.rating ?? landedRating }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button(action: onOpen) { label }
                .buttonStyle(.plain).focused($focus, equals: .detail)
                .accessibilityLabel("View details for \(model.title)")
            Button(action: onPlay) {
                HStack(spacing: 5) { Image(systemName: "play.fill").font(.system(size: 9)); Text("Play").font(.system(size: 11, weight: .semibold)) }
                    .foregroundStyle(.white).padding(.horizontal, 12).frame(height: 28)
                    .background(accent, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.22)))
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
            }
            .buttonStyle(.plain).focused($focus, equals: .play)
            .offset(x: 10, y: height - 38)
            .opacity(showPlay ? 1 : 0).offset(y: showPlay || reduceMotion ? 0 : 3)
            .allowsHitTesting(showPlay)
            .accessibilityLabel("Play \(model.title)")
        }
        .frame(width: width, alignment: .leading)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : AnimationTokens.quick, value: showPlay)
        .prioritizesArtwork((model.imageURL ?? "").isEmpty || model.rating == nil ? [model.id] : [])          // a tile without a poster or a rating that is on screen is matched first
        .onMetadataLanded(for: model.id) {
            guard model.rating == nil, let c = container else { return }
            let id = model.id
            Task.detached { let r = c.metadata.ratingValue(for: id); await MainActor.run { if let r { withAnimation(.easeIn(duration: 0.25)) { landedRating = r } } } }
        }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                PosterArt(title: model.title, url: model.imageURL, detail: model.placeholderDetail, showsTitle: false, itemID: model.id)
                if model.isNew {
                    Text("NEW").font(.system(size: 8, weight: .heavy)).tracking(0.6).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 3)
                        .background(accent, in: RoundedRectangle(cornerRadius: 3)).padding(8).accessibilityLabel("New episode")
                }
                if let r = model.rank {
                    Text("\(r)").font(.system(size: 27, weight: .heavy)).foregroundStyle(Color.white.opacity(0.62)).padding(.leading, 10).padding(.top, 4)
                }
                // Top right, in a fixed order: the tag (SERIES, 4K) then the rating, so they never overlap.
                HStack(spacing: 4) {
                    if let t = model.tag {
                        Text(t).font(.system(size: 8, weight: .semibold)).tracking(0.5).padding(.horizontal, 5).padding(.vertical, 3)
                            .background(Color(hex: 0x080A0D, opacity: 0.78), in: RoundedRectangle(cornerRadius: 3))
                    }
                    if let r = shownRating { RatingBadge(value: r) }
                }
                .frame(maxWidth: .infinity, alignment: .trailing).padding(8)
                HStack(spacing: 4) {
                    DownloadCornerBadge(titleID: model.id)
                    if model.isWatched {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).symbolRenderingMode(.palette).foregroundStyle(.white, Color(red: 0.2, green: 0.72, blue: 0.4))
                            .shadow(color: .black.opacity(0.5), radius: 3).accessibilityLabel("Watched")
                    }
                }
                .padding(7).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                if model.isFavorite { Image(systemName: "heart.fill").font(.system(size: 9)).foregroundStyle(accent).padding(6).background(.black.opacity(0.55), in: Circle()).frame(maxWidth: .infinity, alignment: .trailing).padding(.top, model.tag == nil ? 6 : 30).padding(.trailing, 6) }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(focus != nil ? accent : (hovering ? Color.white.opacity(0.28) : Color.white.opacity(0.07)), lineWidth: focus != nil ? 2 : 1))
            .shadow(color: .black.opacity(hovering ? 0.55 : 0.18), radius: hovering ? 18 : 6, y: hovering ? 10 : 3)
            .scaleEffect(hovering && !reduceMotion ? 1.035 : 1, anchor: .center)
            .animation(reduceMotion ? nil : AnimationTokens.hover, value: hovering)
            .overlay(alignment: .bottom) { if let p = model.progress, p > 0 { ProgressBar(fraction: p).padding(8) } }

            Text(model.displayTitle ?? model.title).font(.system(size: 11, weight: .medium)).lineLimit(model.reservesLines ? 2 : 1, reservesSpace: model.reservesLines).truncationMode(.tail).padding(.top, 7)
            Text(model.subtitle.isEmpty && model.reservesLines ? " " : model.subtitle).font(.system(size: 10)).foregroundStyle(ColorTokens.textSecondary).lineLimit(1).padding(.top, 3)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Rails and headings

struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var actionTitle: String?
    var action: (() -> Void)?
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Typography.heading)
                if let subtitle { Text(subtitle).font(.system(size: 10)).foregroundStyle(ColorTokens.textTertiary) }
            }
            Spacer()
            if let actionTitle, let action { Button(actionTitle, action: action).buttonStyle(.plain).font(Typography.captionMedium).foregroundStyle(.tint) }
        }
    }
}

struct ReddyRail<Item: Identifiable, Card: View>: View where Item.ID: Hashable {
    let title: String
    var caption: String?
    /// Shelves with the "All time top / Trending this week" pair: the view that is on, and what a tap does.
    var mode: SMShelfMode? = nil
    var onMode: ((SMShelfMode) -> Void)? = nil
    /// Opens the full list (genre shelves): the title and a "See all" button.
    var onSeeAll: (() -> Void)? = nil
    let items: [Item]
    @ViewBuilder let card: (Item, Int) -> Card
    @State private var index = 0
    private let step = 3

    var body: some View {
        VStack(alignment: .leading, spacing: HomeLayout.headerGap) {
            ShelfHeader(shelfTitle: title, title: Text(title.loc).font(.system(size: 16, weight: .semibold)).tracking(-0.2).accessibilityAddTraits(.isHeader), caption: caption, mode: mode, onMode: onMode,
                        trailing: HStack(spacing: 6) {
                            if let onSeeAll { Button(action: onSeeAll) { SeeAllLabel() }.buttonStyle(.plain).accessibilityHint(Text("Shows all \(title) titles")) }
                            arrow("chevron.left", "Scroll \(title) left", disabled: index == 0) { index = max(0, index - step) }
                            arrow("chevron.right", "Scroll \(title) right", disabled: index >= items.count - 1) { index = min(items.count - 1, index + step) }
                        })
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: HomeLayout.tileGap) {
                        // The first screenful of cards rises in one after another the first time the row appears.
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in card(item, i + 1).staggeredAppear(i).id(item.id) }
                    }.scrollTargetLayout().padding(.vertical, 12).padding(.horizontal, 6)      // room for the hover lift and shadow (taken back below, so the first card lines up with the heading)
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .padding(.vertical, -9).padding(.horizontal, -6)
                .onChange(of: index) { _, i in if items.indices.contains(i) { withAnimation(.smooth(duration: 0.5)) { proxy.scrollTo(items[i].id, anchor: .leading) } } }
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel(title)
    }

    private func arrow(_ symbol: String, _ label: String, disabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(disabled ? ColorTokens.textTertiary : ColorTokens.textSecondary).disabled(disabled).accessibilityLabel(label).atlas("control.shelf.scrollArrow")
    }
}

// MARK: - Hero

// MARK: - Other cards

/// 16:9 card for resumable items: the image is exactly `width` × `width·9/16`, the text sits beneath it, and the card is
/// never wider or taller than its own content, so neighbours in a rail can't overlap.
struct LandscapeCard: View {
    let title: String
    var subtitle: String?
    let imageURL: String?
    var progress: Double?
    var width: CGFloat = LayoutTokens.landscapeCard.width
    var itemID: String? = nil
    var rating: Double? = nil
    @State private var hovering = false
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottom) {
                PosterArt(title: title, url: imageURL, kind: .backdrop, showsTitle: false, itemID: itemID)
                if let rating { RatingBadge(value: rating).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(8) }
                Image(systemName: "play.fill").font(.system(size: 13)).foregroundStyle(.white)
                    .frame(width: 34, height: 34).background(accent, in: Circle()).shadow(color: .black.opacity(0.4), radius: 8, y: 3)
                    .scaleEffect(hovering ? 1 : 0.85).opacity(hovering ? 1 : 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let progress, progress > 0 { ProgressBar(fraction: progress).padding(8) }
            }
            .frame(width: width, height: (width * 9 / 16).rounded())
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(hovering ? Color.white.opacity(0.28) : Color.white.opacity(0.07)))
            .shadow(color: .black.opacity(hovering ? 0.55 : 0.18), radius: hovering ? 18 : 6, y: hovering ? 10 : 3)
            .scaleEffect(hovering ? 1.03 : 1)
            .animation(AnimationTokens.hover, value: hovering)
            Text(title).font(.system(size: 13, weight: .medium)).lineLimit(2).truncationMode(.tail).multilineTextAlignment(.leading)
                .frame(width: width, alignment: .leading).padding(.top, 7)
            if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(ColorTokens.textSecondary).lineLimit(1).truncationMode(.tail).frame(width: width, alignment: .leading).padding(.top, 3) }
        }
        .frame(width: width, alignment: .topLeading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Compact live-channel tile, a fixed 200 × 76 pt so a row of them lines up and long names wrap to two lines instead of squeezing.
struct ChannelCard: View {
    let channel: Channel
    var nowTitle: String?
    var progress: Double?
    var width: CGFloat = 200
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ChannelLogo(url: channel.logoURL, name: channel.name, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name).font(.system(size: 13, weight: .medium)).lineLimit(2).truncationMode(.tail).multilineTextAlignment(.leading)
                if let sub = nowTitle ?? channel.categoryName, !sub.isEmpty { Text(sub).font(.system(size: 11)).foregroundStyle(ColorTokens.textSecondary).lineLimit(1).truncationMode(.tail) }
                if let progress { ProgressBar(fraction: progress, height: 2) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).frame(width: width, height: 76, alignment: .leading)
        .surface()
        .overlay(RoundedRectangle(cornerRadius: LayoutTokens.radiusPanel, style: .continuous).strokeBorder(hovering ? Color.white.opacity(0.3) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
