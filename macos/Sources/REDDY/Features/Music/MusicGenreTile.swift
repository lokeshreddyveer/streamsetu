import SwiftUI

// Category tiles: a mood, genre or language drawn as a cover with its name on it. The designed fallback shows on the first frame, so a tile is
// never an empty box; the real cover fades in when it arrives. Used by Explore and by the empty Search page.

// MARK: - Layout maths (pure)

enum MusicCategoryTileLayout {
    /// Tiles are 16:10.
    static let aspect: CGFloat = 1.6
    static let minTileWidth: CGFloat = 150
    static let spacing: CGFloat = MusicSpace.sm
    /// Room between the tile edge and its name.
    static let inset: CGFloat = MusicSpace.sm
    static let maxLines = 2

    /// Most columns a layout class shows.
    static func maxColumns(for cls: MusicLayoutClass) -> Int {
        switch cls { case .compact: 3; case .medium: 4; case .expanded: 5; case .wide: 6 }
    }

    /// Columns for a grid `width` points wide: as many tiles of at least `minTileWidth` as fit, from 2 up to the class limit. Before the width is known the class decides.
    static func columns(width: CGFloat, cls: MusicLayoutClass) -> Int {
        guard width.isFinite, width > 0 else { return min(max(MusicLayoutGrid.columns(for: cls), 2), maxColumns(for: cls)) }
        let fit = Int(((width + spacing) / (minTileWidth + spacing)).rounded(.down))
        return min(max(fit, 2), maxColumns(for: cls))
    }

    static func tileWidth(width: CGFloat, columns: Int) -> CGFloat {
        guard columns > 0 else { return 0 }
        return max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
    }

    /// A careful over-estimate of how many lines `name` needs in a tile `tileWidth` wide (average glyph about 0.6 em, wide scripts 1 em).
    static func lines(for name: String, tileWidth: CGFloat, pointSize: CGFloat = MusicTypeRole.card.pointSize) -> Int {
        let inner = max(1, tileWidth - inset * 2)
        var lines = 1, used: CGFloat = 0
        for word in name.split(separator: " ", omittingEmptySubsequences: true) {
            let w = CGFloat(word.unicodeScalars.reduce(0) { $0 + (isWide($1) ? 1.0 : 0.6) }) * pointSize
            let gap = used == 0 ? 0 : 0.3 * pointSize
            if used + gap + w <= inner { used += gap + w }
            else if w <= inner { lines += 1; used = w }
            else { // a word longer than a line breaks across lines
                let extra = Int((w / inner).rounded(.up))
                lines += used == 0 ? extra - 1 : extra; used = w.truncatingRemainder(dividingBy: inner)
            }
        }
        return lines
    }

    static func fitsTwoLines(_ name: String, tileWidth: CGFloat) -> Bool { lines(for: name, tileWidth: tileWidth) <= maxLines }

    private static func isWide(_ s: Unicode.Scalar) -> Bool {
        (0x1100...0x11FF).contains(s.value) || (0x2E80...0xA4CF).contains(s.value) || (0xAC00...0xD7AF).contains(s.value) || (0xF900...0xFAFF).contains(s.value)
    }
}

/// The designed look of a tile before (or without) a cover: a gradient from the app accent turned by a stable hue per name, and a large soft glyph.
enum MusicCategoryFallback {
    /// Degrees of hue turn applied to the accent, from -70 to +70, the same for the same name on every launch.
    static func hueTurn(for name: String) -> Double { MusicCoverTint.hue(for: MusicCategory.normalise(name)) * 140 - 70 }

    static func glyph(for kind: MusicCategoryKind) -> MusicGlyph {
        switch kind { case .genre: .note; case .mood: .waveform; case .language: .lyrics }
    }

    /// Where the glyph sits (a corner chosen by the name), as fractions of the tile.
    static func glyphCorner(for name: String) -> (x: CGFloat, y: CGFloat) {
        switch MusicCoverTint.hash(name) % 3 { case 0: (0.78, 0.3); case 1: (0.7, 0.36); default: (0.84, 0.26) }
    }
}

extension MusicA11yLabels {
    static func browseCategory(_ name: String) -> String { Localized.string("Browse %@", name) }
    static var browseCategoryHint: String { Localized.string("Opens songs and playlists for this category") }
}

// MARK: - Width reading

private struct MusicGridWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

extension View {
    /// Writes the view's width into `width` whenever it changes by more than half a point.
    func musicReadWidth(_ width: Binding<CGFloat>) -> some View {
        background(GeometryReader { Color.clear.preference(key: MusicGridWidthKey.self, value: $0.size.width) })
            .onPreferenceChange(MusicGridWidthKey.self) { if abs($0 - width.wrappedValue) > 0.5 { width.wrappedValue = $0 } }
    }
}

// MARK: - Tile

struct MusicCategoryArtTile: View {
    let category: MusicCategory
    let action: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool
    @Environment(\.reddyAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: MusicCorner.card, style: .continuous) }

    var body: some View {
        Button(action: action) {
            Color.clear
                .aspectRatio(MusicCategoryTileLayout.aspect, contentMode: .fit)
                .overlay { MusicCategoryArt(category: category).scaleEffect(hovering && !reduceMotion ? MusicCardGeometry.hoverScale : 1) }
                .overlay { scrim }
                .overlay(alignment: .bottomLeading) { label }
                .clipShape(shape)
                .overlay(shape.strokeBorder(ColorTokens.line, lineWidth: 0.75))
                .musicHoverLift(hovering, cornerRadius: MusicCorner.card)
                .overlay(shape.strokeBorder(accent, lineWidth: 2).opacity(focused ? 1 : 0).allowsHitTesting(false))
                .frame(minHeight: MusicTokens.hitTarget)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focused($focused).focusEffectDisabled()
        .onHover { hovering = $0 }
        .musicAnimation(.hover, reduce: reduceMotion, value: hovering)
        .musicAnimation(.focus, reduce: reduceMotion, value: focused)
        .musicTooltip(verbatim: Localized.string(category.name))
        .accessibilityLabel(MusicA11yLabels.browseCategory(Localized.string(category.name)))
        .accessibilityHint(MusicA11yLabels.browseCategoryHint)
        .atlas("control.music.categoryTile")
    }


    private var scrim: some View {
        LinearGradient(colors: [MusicInk.clear, MusicInk.scrim(.strong)], startPoint: .center, endPoint: .bottom).allowsHitTesting(false)
    }

    /// The name is never cut with an ellipsis: it wraps (the grid is sized so two lines are enough) and may shrink a little before it would need a third.
    private var label: some View {
        Text(verbatim: Localized.string(category.name))
            .musicText(.card).fontWeight(.semibold)
            .foregroundStyle(MusicInk.onArtwork)
            .multilineTextAlignment(.leading).lineLimit(MusicCategoryTileLayout.maxLines).minimumScaleFactor(0.8)
            .fixedSize(horizontal: false, vertical: true)
            .padding(MusicCategoryTileLayout.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The picture of a category: the designed fallback from the first frame, and the real cover fading in over it when it arrives.
struct MusicCategoryArt: View {
    let category: MusicCategory
    @State private var image: MusicDecodedImage?
    @Environment(\.reddyAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        // The fallback sets the size and the picture is drawn over it, so a picture that fills a square cannot grow the tile and cover its neighbours' clicks.
        fallback
            .overlay { if let image { Image(decorative: image.cg, scale: 1).resizable().scaledToFill().transition(.opacity).allowsHitTesting(false) } }
            .clipped()
            .task(id: category.id) { await loadCover() }
    }

    private var fallback: some View {
        LinearGradient(colors: [accent.opacity(0.95), accent.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .hueRotation(.degrees(MusicCategoryFallback.hueTurn(for: category.name)))
            .overlay {
                GeometryReader { g in
                    let p = MusicCategoryFallback.glyphCorner(for: category.name)
                    MusicIcon(glyph: MusicCategoryFallback.glyph(for: category.kind), size: g.size.height * 0.9, tint: .custom(MusicInk.onArtworkFaint))
                        .position(x: g.size.width * p.x, y: g.size.height * p.y)
                        .rotationEffect(.degrees(MusicCoverTint.hue(for: category.name) * 40 - 20))
                }
            }
            .accessibilityHidden(true)
    }

    private func loadCover() async {
        let px = MusicArtworkClass.tile.pixels(scale: displayScale)
        let service = MusicArtworkService.shared
        if let url = MusicGenreArtwork.shared.cachedURL(for: category), let hit = service.cachedImage(url, targetPixelSize: px) { image = hit; return }
        guard let url = await MusicGenreArtwork.shared.cover(for: category), !Task.isCancelled else { return }
        if let hit = service.cachedImage(url, targetPixelSize: px) { image = hit; return }
        let img = await service.load(url, targetPixelSize: px)
        guard !Task.isCancelled, let img else { return }
        withAnimation(MusicMotion.animation(.artwork, reduce: reduceMotion)) { image = img }
    }
}

// MARK: - Grid

/// Every category as a lazy grid of tiles. Columns follow the layout class and the width the grid is given; covers for the tiles just below the
/// visible edge are looked up and warmed (bounded), and stop when the grid leaves the screen.
struct MusicCategoryGrid: View {
    let categories: [MusicCategory]
    var owner = "explore.categories"
    let open: (MusicCategory) -> Void
    @State private var width: CGFloat = 0
    @Environment(\.musicLayoutClass) private var cls
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let cols = MusicCategoryTileLayout.columns(width: width, cls: cls)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: MusicCategoryTileLayout.spacing, alignment: .top), count: cols),
                  spacing: MusicCategoryTileLayout.spacing) {
            ForEach(Array(categories.enumerated()), id: \.element.id) { i, c in
                MusicCategoryArtTile(category: c) { open(c) }.onAppear { warmAhead(of: i) }
            }
        }
        .musicReadWidth($width)
        .onDisappear { MusicArtworkPrefetcher.shared.cancel(owner: owner) }
    }

    private func warmAhead(of index: Int) {
        guard index + 1 < categories.count else { return }
        let next = Array(categories[(index + 1)...].prefix(MusicArtworkPrefetcher.defaultWindow))
        MusicGenreArtwork.shared.warm(next)
        let urls = next.compactMap { MusicGenreArtwork.shared.cachedURL(for: $0) }
        MusicArtworkPrefetcher.shared.prefetch(addresses: urls, artworkClass: .tile, scale: displayScale, priority: .low, owner: owner)
    }
}
