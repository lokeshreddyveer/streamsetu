import SwiftUI

// The Mac title page's building blocks: a cinematic hero, one clear Play, round actions, a tidy details grid, rails that fade at their
// edges instead of clipping, and skeletons with the same geometry as the real content. Movie and series pages share all of it.

#if os(macOS)
// MARK: dialog host

/// The window the title page opens in: the app window less a margin, so it never overflows a small window and never sprawls on a large one.
struct TitleDialogHost<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        GeometryReader { g in
            let s = TitlePageLogic.dialogSize(window: g.size)
            content.frame(width: s.width, height: s.height)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(ColorTokens.glassEdge.opacity(0.7), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.55), radius: 40, y: 20)
                .accessibilityAddTraits(.isModal)
                .position(x: g.size.width / 2, y: g.size.height / 2)
        }
    }
}

enum TitleDialogMotion {
    /// Opens with a short rise and fade; closes with a plain fade. Reduce Motion: fades only.
    static var transition: AnyTransition {
        let still = BrandMotion.reduced(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        return still ? .opacity : .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.965)), removal: .opacity)
    }
}

#endif

// MARK: buttons

/// The round glass button of the hero: Favourite, Watch Later, Trailer, Download, Share, More, Close.
struct HeroCircleStyle: ButtonStyle {
    var active = false
    var size: CGFloat = 44
    @Environment(\.reddyAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(active ? accent : Color.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.black.opacity(0.42)))
            .overlay(Circle().fill(Color.white.opacity(hover ? 0.14 : 0)))
            .overlay(Circle().strokeBorder(active ? accent.opacity(0.9) : Color.white.opacity(0.2), lineWidth: active ? 1.5 : 1))
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.93 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.7 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hover)
            .onHover { hover = $0 }
    }
}

struct HeroCircleButton: View {
    let symbol: String
    let help: String
    var active = false
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).symbolEffect(.bounce, value: active) }
            .buttonStyle(HeroCircleStyle(active: active))
            .help(help).accessibilityLabel(help).atlas("screen.title.movie")
    }
}

/// The one primary button: a capsule in the accent, with a thin progress line along its lower edge when there is something to resume.
struct TitlePlayPill: View {
    let label: TitlePageLogic.PlayLabel
    var enabled = true
    /// Fills the width it is given (the phone's Play button) instead of its own size.
    var expand = false
    let action: () -> Void
    @Environment(\.reddyAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isFocused) private var focused

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "play.fill").font(.system(size: 15, weight: .bold))
                Text(label.title).font(.system(size: 16, weight: .bold))
                if let d = label.detail { Text(d).font(.system(size: 13, weight: .medium)).opacity(0.85) }
            }
            .lineLimit(1).fixedSize()
            .foregroundStyle(.white)
            .padding(.horizontal, 22).frame(minWidth: 168, maxWidth: expand ? .infinity : nil, minHeight: 48)
            .background(accent)
            .overlay(LinearGradient(colors: [Color.white.opacity(0.2), .clear], startPoint: .top, endPoint: .center).allowsHitTesting(false))
            .overlay(alignment: .bottomLeading) {
                if let f = label.fraction {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.black.opacity(0.28))
                            Rectangle().fill(Color.white.opacity(0.95)).frame(width: g.size.width * f)
                        }
                    }.frame(height: 3).allowsHitTesting(false)
                }
            }
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(focused ? 0.95 : 0.22), lineWidth: focused ? 2 : 1))
            .shadow(color: accent.opacity(0.4), radius: 14, y: 5)
        }
        .buttonStyle(.brandPress)
        .focusEffectDisabled()
        .disabled(!enabled).opacity(enabled ? 1 : 0.5)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: label)
        .accessibilityLabel(label.detail.map { "\(label.title), \($0)" } ?? label.title)
        .accessibilityHint(label.fraction == nil ? "Starts playback" : "Continues where you stopped")
        .accessibilitySortPriority(10).atlas("screen.title.movie")
    }
}

// MARK: hero

/// The picture behind the title. Always a designed surface: the title's own colour at first, then the backdrop, or with none a blurred wash of the poster. Never an empty box.
struct TitleHeroBackground: View {
    let art: HeroArtwork
    let title: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let hue = ArtworkTile.Content(title: title, detail: nil).hue / 360
        let wash = art.wash.map { TitlePalette.wash($0) }
        ZStack {
            LinearGradient(colors: [wash.map { Color(red: $0.r, green: $0.g, blue: $0.b) } ?? Color(hue: hue, saturation: 0.38, brightness: 0.36), Color(hue: hue, saturation: 0.4, brightness: 0.1)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let b = art.backdrop {
                Image(decorative: b, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).clipped().transition(.opacity)
            } else if let p = art.poster {
                Image(decorative: p, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).scaleEffect(1.25).blur(radius: 38).saturation(1.3).opacity(0.85).clipped().transition(.opacity)
            }
            // legibility: darker where the title sits (left), and a melt into the page at the bottom
            LinearGradient(colors: [Color.black.opacity(0.62), Color.black.opacity(0.18), .clear], startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .clear, location: 0.28), .init(color: ColorTokens.background.opacity(0.78), location: 0.78), .init(color: ColorTokens.background, location: 1)], startPoint: .top, endPoint: .bottom)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: art.backdrop != nil)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: art.poster != nil)
        .accessibilityHidden(true)
    }
}

/// Year, seasons, runtime, then the age rating and quality as small outlined badges and the star rating. One sentence for VoiceOver.
struct TitleChipsRow: View {
    let chips: [TitlePageLogic.Chip]
    let rating: Double?
    let spoken: String

    var body: some View {
        HStack(spacing: 10) {
            ForEach(chips) { c in
                if c.badge {
                    Text(c.text).font(.system(size: 11, weight: .bold)).foregroundStyle(Color.white.opacity(0.92))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.white.opacity(0.55), lineWidth: 1))
                } else {
                    Text(c.text).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.white.opacity(0.88))
                }
            }
            if let rating {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill").font(.system(size: 12))
                    Text(String(format: "%.1f", rating)).font(.system(size: 14, weight: .semibold))
                }.foregroundStyle(ColorTokens.warning)
            }
        }
        .lineLimit(1)
        .frame(minHeight: 22)
        .accessibilityElement(children: .ignore).accessibilityLabel(spoken.isEmpty ? "No details yet" : spoken)
        .accessibilityHidden(spoken.isEmpty)
    }
}

// MARK: sections and rails

struct TitleSectionHeader: View {
    let title: String
    var count: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 19, weight: .bold)).accessibilityAddTraits(.isHeader)
            if let count { Text(count).font(.system(size: 12, weight: .semibold)).foregroundStyle(ColorTokens.textSecondary) }
        }
    }
}

private struct HScrollMetrics: Equatable { var offset: CGFloat; var width: CGFloat }
private struct HScrollKey: PreferenceKey {
    static let defaultValue = HScrollMetrics(offset: 0, width: 0)
    static func reduce(value: inout HScrollMetrics, nextValue: () -> HScrollMetrics) { value = nextValue() }
}

/// A horizontal row that never clips at an edge: where more lies beyond a side, that side fades out. A row that fits does not fade at all.
struct FadingHScroll<Content: View>: View {
    var fade: CGFloat = 32
    @ViewBuilder let content: Content
    @State private var offset: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var viewport: CGFloat = 0
    private let space = "fadingHScroll"

    var body: some View {
        let e = TitlePageLogic.fadeEdges(offset: offset, content: contentWidth, viewport: viewport)
        let f = viewport > 0 ? min(0.45, fade / viewport) : 0
        ScrollView(.horizontal, showsIndicators: false) {
            content
                .background(GeometryReader { g in Color.clear.preference(key: HScrollKey.self, value: HScrollMetrics(offset: g.frame(in: .named(space)).minX, width: g.size.width)) })
        }
        .coordinateSpace(name: space)
        .background(GeometryReader { g in Color.clear.onAppear { viewport = g.size.width }.onChange(of: g.size.width) { _, w in viewport = w } })
        .onPreferenceChange(HScrollKey.self) { offset = $0.offset; contentWidth = $0.width }
        .modifier(ExactScrollEdges(offset: $offset, contentWidth: $contentWidth, viewport: $viewport))
        .mask(LinearGradient(stops: [.init(color: e.leading ? .clear : .black, location: 0), .init(color: .black, location: f), .init(color: .black, location: 1 - f), .init(color: e.trailing ? .clear : .black, location: 1)], startPoint: .leading, endPoint: .trailing))
        .animation(.easeOut(duration: 0.15), value: e.leading).animation(.easeOut(duration: 0.15), value: e.trailing)
    }
}

/// Where the system can say exactly how far a row has scrolled and how big it is (iOS 18, macOS 15), it does; elsewhere the measured values stand.
private struct ExactScrollEdges: ViewModifier {
    @Binding var offset: CGFloat
    @Binding var contentWidth: CGFloat
    @Binding var viewport: CGFloat
    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content.onScrollGeometryChange(for: [CGFloat].self) { g in [-(g.contentOffset.x + g.contentInsets.leading), g.contentSize.width, g.containerSize.width] } action: { _, v in
                offset = v[0]; contentWidth = v[1]; viewport = v[2]
            }
        } else { content }
    }
}

/// The look of one choice in a row of chips (versions, seasons): the chosen one is tinted and marked.
struct TitleChoiceLabel: View {
    let text: String
    var selected = false
    var badge: String? = nil
    @Environment(\.reddyAccent) private var accent
    @State private var hover = false

    var body: some View {
        HStack(spacing: 7) {
            if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(accent) }
            Text(text).font(.system(size: 14, weight: selected ? .semibold : .medium)).lineLimit(1)
            if let badge { Text(badge).font(.system(size: 10, weight: .bold)).foregroundStyle(accent).padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(accent.opacity(0.16))) }
        }
        .foregroundStyle(ColorTokens.textPrimary)
        .padding(.horizontal, 14).frame(minHeight: 40)
        .background(Capsule().fill(selected ? accent.opacity(0.16) : (hover ? ColorTokens.elevated : ColorTokens.card)))
        .overlay(Capsule().strokeBorder(selected ? accent : (hover ? ColorTokens.borderStrong : ColorTokens.border), lineWidth: selected ? 1.5 : 1))
        .contentShape(Capsule())
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

struct TitleChoiceChip: View {
    let text: String
    var selected = false
    var badge: String? = nil
    let action: () -> Void
    var body: some View { Button(action: action) { TitleChoiceLabel(text: text, selected: selected, badge: badge) }.buttonStyle(.plain).atlas("screen.title.series") }
}

/// The other versions of the title, as one row of chips.
struct TitleVersionsSection: View {
    let versions: [OtherLanguages.Version]
    /// iPhone and iPad: a version is a value-based navigation link (Back returns here). Mac: `open` is called.
    var useLinks = false
    var open: (LibraryItem) -> Void = { _ in }

    var body: some View {
        if versions.count > 1 {
            VStack(alignment: .leading, spacing: 12) {
                TitleSectionHeader(title: "Versions", count: "\(versions.count)")
                FadingHScroll {
                    HStack(spacing: 10) {
                        ForEach(versions) { v in
                            Group {
                                if useLinks && !v.isCurrent { NavigationLink(value: v.item) { TitleChoiceLabel(text: v.versionText, selected: false) }.buttonStyle(.plain).atlas("control.title.version") }
                                else { TitleChoiceChip(text: v.versionText, selected: v.isCurrent) { if !v.isCurrent { open(v.item) } } }
                            }
                                .accessibilityLabel(v.accessibilityLabel).accessibilityHint(v.isCurrent ? "The version you are on" : "Opens this version")
                                .accessibilityAddTraits(v.isCurrent ? .isSelected : [])
                        }
                    }.padding(.vertical, 3).padding(.horizontal, 1)
                }
            }
        }
    }
}

/// Synopsis with a clean More / Less, and the tagline above it when there is one.
struct MacSynopsis: View {
    let text: String
    var tagline: String? = nil
    @State private var open = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let tagline { Text(tagline).font(.system(size: 14, weight: .semibold)).italic().foregroundStyle(ColorTokens.textSecondary) }
            Text(text).font(.system(size: 15)).lineSpacing(4).foregroundStyle(ColorTokens.textPrimary.opacity(0.9))
                .lineLimit(open ? nil : 4).fixedSize(horizontal: false, vertical: true)
            if text.count > 230 {
                Button { if reduceMotion { open.toggle() } else { withAnimation(.smooth(duration: 0.25)) { open.toggle() } } } label: {
                    HStack(spacing: 4) { Text(open ? "Less" : "More"); Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .bold)) }
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.tint)
                }.buttonStyle(.plain).accessibilityLabel(open ? "Show less" : "Read more").atlas("screen.title.movie")
            }
        }
    }
}

/// The facts as a two-column grid: quiet labels, readable values; people and the folder are links.
struct TitleDetailsGrid: View {
    let rows: [DetailRow]
    let onPerson: (PersonRoute) -> Void
    let onFolder: (() -> Void)?
    var useLinks = false
    @Environment(\.dynamicTypeSize) private var type

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("DETAILS").font(.system(size: 11, weight: .bold)).tracking(0.8).foregroundStyle(ColorTokens.textTertiary).padding(.bottom, 10).accessibilityAddTraits(.isHeader)
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                if i > 0 { Divider().overlay(ColorTokens.line).padding(.vertical, 9) }
                if type.isAccessibilitySize { VStack(alignment: .leading, spacing: 3) { label(r); value(r) } }
                else { HStack(alignment: .firstTextBaseline, spacing: 12) { label(r).frame(width: 82, alignment: .leading); value(r).frame(maxWidth: .infinity, alignment: .leading) } }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ColorTokens.card.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(ColorTokens.line))
        .accessibilityElement(children: .contain)
    }

    private func label(_ r: DetailRow) -> some View { Text(r.label).font(.system(size: 12.5)).foregroundStyle(ColorTokens.textSecondary) }

    @ViewBuilder private func value(_ r: DetailRow) -> some View {
        switch r.value {
        case .text(let t): Text(t).font(.system(size: 13.5)).fixedSize(horizontal: false, vertical: true)
        case .people(let people):
            FlowLayout(spacing: 6) {
                ForEach(Array(people.enumerated()), id: \.offset) { i, p in
                    Group {
                        if useLinks { NavigationLink(value: p) { Text(p.name + (i < people.count - 1 ? "," : "")).font(.system(size: 13.5, weight: .medium)).foregroundStyle(.tint) }.atlas("screen.person") }
                        else { Button { onPerson(p) } label: { Text(p.name + (i < people.count - 1 ? "," : "")).font(.system(size: 13.5, weight: .medium)).foregroundStyle(.tint) }.atlas("screen.person") }
                    }
                        .buttonStyle(.plain).accessibilityLabel(p.name).accessibilityHint("Opens this person's films").accessibilityAddTraits(.isLink).atlas("screen.person")
                }
            }
        case .folder(let name, _):
            if let onFolder {
                Button(action: onFolder) { HStack(spacing: 4) { Text(name).font(.system(size: 13.5, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading); Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)) }.foregroundStyle(.tint) }
                    .buttonStyle(.plain).accessibilityHint("Opens the folder").atlas("control.title.folderPath")
            } else { Text(name).font(.system(size: 13.5)) }
        }
    }
}

/// Round photos with name and role in one row that fades at its edges. Opens the in-window person page.
struct TitleCastRail: View {
    let cast: [TitlePageModel.CastEntry]
    let onPerson: (PersonRoute) -> Void
    @ScaledMetric(relativeTo: .caption) private var photo: CGFloat = 80
    @Environment(\.dynamicTypeSize) private var type

    var body: some View {
        if !cast.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                TitleSectionHeader(title: "Cast")
                FadingHScroll {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(cast) { p in CastCell(person: p, size: photo, lines: type.isAccessibilitySize ? 3 : 2) { onPerson(p.route) } }
                    }.padding(.vertical, 4).padding(.horizontal, 2)
                }
            }
        }
    }
}

private struct CastCell: View {
    let person: TitlePageModel.CastEntry
    let size: CGFloat
    let lines: Int
    let action: () -> Void
    @Environment(\.reddyAccent) private var accent
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    if let url = person.photo { ArtworkImage(url: url, kind: .poster, contentMode: .fill, symbol: "person.fill", alignment: .top) }
                    else {
                        ArtworkTile(content: .init(title: person.name, detail: nil))
                        Text(TitlePageLogic.initials(person.name)).font(.system(size: size * 0.3, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                    }
                }
                .frame(width: size, height: size).clipShape(Circle())
                .overlay(Circle().strokeBorder(hover ? accent : Color.white.opacity(0.1), lineWidth: hover ? 2 : 1))
                .shadow(color: .black.opacity(hover ? 0.4 : 0.2), radius: hover ? 8 : 4, y: 2)
                .scaleEffect(hover ? 1.04 : 1)
                Text(person.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(lines).multilineTextAlignment(.center).frame(width: size + 22)
                if let r = person.role { Text(r).font(.system(size: 11.5)).foregroundStyle(ColorTokens.textSecondary).lineLimit(lines).multilineTextAlignment(.center).frame(width: size + 22) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }
        .animation(.easeOut(duration: 0.14), value: hover)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(person.name)\(person.role.map { ", as \($0)" } ?? "")")
        .accessibilityHint("Shows this person's films").atlas("screen.person")
    }
}

#if os(macOS)
// MARK: skeleton

/// What the body shows until the saved details have been read (a fraction of a second): the same blocks, in the same places and sizes.
struct TitleBodySkeleton: View {
    let metrics: TitlePageLogic.Metrics
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            let synopsis = VStack(alignment: .leading, spacing: 10) {
                SkeletonBlock(height: 14); SkeletonBlock(height: 14); SkeletonBlock(height: 14); SkeletonBlock(width: 220, height: 14)
            }
            let card = RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ColorTokens.card.opacity(0.5)).frame(height: 168)
            if metrics.columns == .two {
                HStack(alignment: .top, spacing: 36) { synopsis.frame(maxWidth: .infinity, alignment: .leading); card.frame(width: metrics.sideWidth) }
            } else { VStack(alignment: .leading, spacing: 24) { synopsis; card } }
            VStack(alignment: .leading, spacing: 12) {
                SkeletonBlock(width: 70, height: 18)
                HStack(spacing: 18) { ForEach(0..<7, id: \.self) { _ in Circle().fill(ColorTokens.card).frame(width: 80, height: 80).modifier(Shimmer()) } }
            }
        }
        .accessibilityHidden(true)
    }
}
#endif
