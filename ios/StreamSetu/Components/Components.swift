import SwiftUI

extension View {
    /// A font size that follows the person's Text Size setting (Settings > Display), like the system's own text styles.
    func appFont(_ size: CGFloat, _ weight: Font.Weight = .regular) -> some View { modifier(ScaledFont(size: size, weight: weight)) }
}

/// Side by side at ordinary text sizes; stacked at the accessibility sizes, so large text gets the full width instead of being squeezed or cut off.
struct ReflowStack<Content: View>: View {
    var alignment: VerticalAlignment = .center
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content
    @Environment(\.dynamicTypeSize) private var size
    var body: some View {
        if size.isAccessibilitySize { VStack(alignment: .leading, spacing: spacing / 2) { content } }
        else { HStack(alignment: alignment, spacing: spacing) { content } }
    }
}

private struct ScaledFont: ViewModifier {
    @ScaledMetric private var scaled: CGFloat
    let weight: Font.Weight
    init(size: CGFloat, weight: Font.Weight) { _scaled = ScaledMetric(wrappedValue: size, relativeTo: .body); self.weight = weight }
    func body(content: Content) -> some View { content.font(.system(size: scaled, weight: weight)) }
}

extension LibraryItem {
    /// The provider's rating as a number worth showing, or nil.
    var ratingValue: Double? {
        let r: String? = { switch self { case .movie(let m): m.rating; case .series(let s): s.rating } }()
        return r.flatMap { Double($0) }.flatMap { $0 > 0 ? $0 : nil }
    }
    /// "2025 · Thriller"
    /// The year is left out when the title already carries it, e.g. "Only Me (2026)".
    var detailLine: String { [titleHasYear ? nil : year.map(String.init), genre].compactMap { $0 }.joined(separator: " · ") }
    var titleHasYear: Bool { year.map { title.contains(String($0)) } ?? false }
}

/// The thin "how far you have watched" bar along the bottom of a card.
struct ProgressStrip: View {
    let fraction: Double
    var body: some View {
        GeometryReader { g in
            Rectangle().fill(.black.opacity(0.5)).overlay(alignment: .leading) { Rectangle().fill(ColorTokens.accentDefault).frame(width: g.size.width * min(1, fraction)) }
        }.frame(height: 3)
    }
}

/// A poster with its title underneath. The whole card is a button; the caller decides what a tap does.
struct PosterCard: View {
    let item: LibraryItem
    var width: CGFloat = 120
    var progress: Double?
    /// Why a search found it when its own name does not say ("Cast: Mahesh Babu"); shown where the year and genre would be.
    var note: String?
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottom) {
                ArtworkImage(url: item.posterURL ?? item.backdropURL, kind: .poster, contentMode: .fill, symbol: item.isSeries ? "rectangle.stack" : "film")
                    .frame(width: width, height: width * 1.5)
                if let shown = progress ?? state.partialProgress(item.id), shown > 0 { ProgressStrip(fraction: shown) }
            }
            .overlay(alignment: .topLeading) {
                if item.isSeries, state.hasNewEpisodes(item.id) {
                    Text("NEW").appFont(9, .heavy).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 3)
                        .background(ColorTokens.accentDefault, in: RoundedRectangle(cornerRadius: 4)).padding(6).accessibilityLabel("New episode")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 4) {
                    DownloadCornerBadge(titleID: item.id)
                    if state.isWatched(item.id) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).symbolRenderingMode(.palette).foregroundStyle(.white, Color(red: 0.2, green: 0.72, blue: 0.4))
                            .shadow(color: .black.opacity(0.5), radius: 3).accessibilityLabel("Watched")
                    }
                }.padding(6)
            }
            .overlay(alignment: .topTrailing) {
                if let r = item.ratingValue {
                    Label(String(format: "%.1f", r), systemImage: "star.fill").labelStyle(.titleAndIcon)
                        .appFont(10, .bold).padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.65), in: Capsule()).foregroundStyle(.yellow).padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.08)))
            Text(item.title).appFont(12, .semibold).lineLimit(2).multilineTextAlignment(.leading).frame(width: width, alignment: .leading)
            if let note { Text(note).appFont(11, .medium).foregroundStyle(ColorTokens.accentDefault).lineLimit(1).frame(width: width, alignment: .leading) }
            else if !item.detailLine.isEmpty { Text(item.detailLine).appFont(11).foregroundStyle(.secondary).lineLimit(1).frame(width: width, alignment: .leading) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A wide card for "continue watching" and similar.
struct WideCard: View {
    let title: String
    let subtitle: String?
    let imageURL: String?
    var progress: Double?
    var width: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottom) {
                ArtworkImage(url: imageURL, kind: .backdrop, contentMode: .fill, symbol: "play.rectangle")
                    .frame(width: width, height: width * 9 / 16)
                if let progress, progress > 0 { ProgressStrip(fraction: progress) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.08)))
            Text(title).appFont(13, .medium).lineLimit(1).frame(width: width, alignment: .leading)
            if let subtitle { Text(subtitle).appFont(11).foregroundStyle(.secondary).lineLimit(1).frame(width: width, alignment: .leading) }
        }
        .accessibilityElement(children: .combine)
    }
}

struct Shelf<Content: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title.loc).appFont(18, .semibold).accessibilityAddTraits(.isHeader)
                if let caption { Text(caption.loc).appFont(12).foregroundStyle(.secondary) }
            }.padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) { content }.padding(.horizontal, 16)
            }
        }
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).appFont(36, .light).foregroundStyle(.secondary)
            Text(title.loc).font(.headline)
            if let message { Text(message.loc).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            if let actionTitle, let action { Button(actionTitle, action: action).buttonStyle(.borderedProminent).padding(.top, 4) }
        }
        .padding(32).frame(maxWidth: .infinity)
    }
}

struct ChannelRow: View {
    let channel: Channel
    var programme: EPGProgram?
    var isPlaying = false
    var isFavorite = false
    /// Position in the list, shown so a channel can be reached by typing its number.
    var number: Int?

    @Environment(\.dynamicTypeSize) private var typeSize
    private var lines: Int { typeSize.isAccessibilitySize ? 3 : 1 }
    var body: some View {
        ReflowStack {
            if let number { Text("\(number)").appFont(12, .medium).monospacedDigit().foregroundStyle(.tertiary).frame(minWidth: 26, alignment: .trailing) }
            ChannelLogo(url: channel.logoURL, name: channel.name, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(channel.name).appFont(15, .medium).lineLimit(lines)
                    if isFavorite { Image(systemName: "heart.fill").appFont(10).foregroundStyle(.pink) }
                }
                if let p = programme {
                    Text(p.title).appFont(12).foregroundStyle(.secondary).lineLimit(lines)
                    ProgressView(value: min(1, max(0, Date().timeIntervalSince(p.start) / max(1, p.end.timeIntervalSince(p.start))))).tint(ColorTokens.accentDefault).frame(maxWidth: 140)
                } else if let c = channel.categoryName {
                    Text(c).appFont(12).foregroundStyle(.tertiary).lineLimit(lines)
                }
            }
            Spacer(minLength: 0)
            if isPlaying { Image(systemName: "waveform").foregroundStyle(ColorTokens.accentDefault).symbolEffect(.variableColor.iterative) }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A channel as a small tile: its logo (or initials), name and what is on now.
struct ChannelTile: View {
    let channel: Channel
    var programme: EPGProgram?
    var isPlaying = false
    var isFavorite = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                ChannelLogo(url: channel.logoURL, name: channel.name, size: 56)
                if isFavorite { Image(systemName: "heart.fill").appFont(9).foregroundStyle(.pink).padding(2).offset(x: 6, y: -4) }
            }
            Text(channel.name).appFont(11, .medium).lineLimit(2).multilineTextAlignment(.center).frame(maxWidth: .infinity)
            if let p = programme { Text(p.title).appFont(9).foregroundStyle(.secondary).lineLimit(1) }
        }
        .padding(.vertical, 10).padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 112)
        .background(ColorTokens.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(isPlaying ? ColorTokens.accentDefault : Color.white.opacity(0.06), lineWidth: isPlaying ? 2 : 1))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Starting playback from anywhere in the app.
@MainActor enum Play {
    /// `privately` plays it as a private watch: nothing about it is recorded or shown outside the app.
    static func channel(_ c: Channel, queue: [Channel], _ container: AppContainer, privately: Bool = false) {
        container.playback.play(channel: c, queue: queue.isEmpty ? [c] : queue, privately: privately)
        container.playback.isExpanded = true
    }
    static func movie(_ m: Movie, _ container: AppContainer, privately: Bool = false) {
        container.playback.play(movie: m, privately: privately)
        container.playback.isExpanded = true
    }
    static func episode(_ e: Episode, _ s: Series, _ container: AppContainer, privately: Bool = false) {
        container.playback.play(episode: e, series: s, privately: privately)
        container.playback.isExpanded = true
    }
    /// A series: the episode the person would watch next (or the first).
    static func series(_ s: Series, _ container: AppContainer, privately: Bool) async {
        guard let detail = try? await container.details.series(id: s.id) else { return }
        let next = ((try? container.history.resumeTarget(seriesID: s.id)) ?? nil) ?? detail.episodes.sorted { ($0.seasonNumber, $0.episodeNumber) < ($1.seasonNumber, $1.episodeNumber) }.first
        if let next { episode(next, detail.series, container, privately: privately) }
    }
}

extension View {
    /// Keeps content clear of the mini player that sits above the tab bar.
    /// The mini player now lives once at the root, above the floating bar (see RootView), so screens no longer add their own.
    func miniPlayerInset() -> some View { self }
}

/// A screen that normally has its own navigation stack, or sits inside another one (the More tab on iPhone).
struct OptionalStack<Content: View>: View {
    let embedded: Bool
    @ViewBuilder var content: Content
    var body: some View {
        if embedded { content } else { NavigationStack { content } }
    }
}

/// Paints a screen with the chosen theme: its background and its list rows, instead of the system's grey. There is no bar behind
/// the top of the screen (no blur); the screen's name floats over the content as a small pill.
struct Themed: ViewModifier {
    var title: String?
    /// Put the title pill in the left corner of the top bar instead of the system's centre slot (which squeezes it when there are many buttons).
    var corner = false
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .listRowBackground(ColorTokens.surface)
            .background(ColorTokens.background.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .clearTopBar()
            .toolbar {
                if let title {
                    if corner {
                        if #available(iOS 26.0, *) { ToolbarItem(placement: .topBarLeading) { TitlePill(text: title) }.sharedBackgroundVisibility(.hidden) }
                        else { ToolbarItem(placement: .topBarLeading) { TitlePill(text: title) } }
                    } else { ToolbarItem(placement: .principal) { TitlePill(text: title) } }
                }
            }
    }
}

/// Touch feel for cards, rows and buttons: they dip a little under the finger and spring back, with a light tap from the haptic
/// engine, like the buttons in Apple's own apps.
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.65), value: configuration.isPressed)
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.55), trigger: configuration.isPressed) { _, pressed in pressed }
    }
}

extension ButtonStyle where Self == PressStyle {
    static var press: PressStyle { PressStyle() }
    static var pressSubtle: PressStyle { PressStyle(scale: 0.985) }
}

/// A screen's name, floating like a button.
struct TitlePill: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            .foregroundStyle(ColorTokens.textPrimary)
            .padding(.horizontal, 16).frame(height: 32)
            .background(ColorTokens.card, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// No bar, blur or edge fade behind the top of a screen: its content shows through.
    func clearTopBar() -> some View { toolbarBackground(.hidden, for: .navigationBar).noScrollEdgeEffect() }
    /// iOS 26 fades the content behind the bars as it scrolls. Not wanted here: the top is fully clear, the bottom bar floats.
    @ViewBuilder func noScrollEdgeEffect() -> some View {
        if #available(iOS 26.0, *) { self.scrollEdgeEffectHidden(true, for: .all) } else { self }
    }
    /// Hides the system tab bar for this screen (the iPhone draws its own).
    func withoutSystemTabBar() -> some View { toolbarVisibility(.hidden, for: .tabBar) }
    func themed(_ title: String? = nil, corner: Bool = false) -> some View { modifier(Themed(title: title, corner: corner)) }
}

/// A banner for the top of a scrolling page. The picture is taller than its frame, so as the page scrolls up it can slip down at
/// half speed (never leaving a gap), and when the page is pulled down it stays pinned and stretches. `scrollY` is how far the page
/// has scrolled (negative when pulled down).
struct ParallaxBanner<Content: View>: View {
    let height: CGFloat
    let scrollY: CGFloat
    @ViewBuilder var content: Content
    private let spare: CGFloat = 140

    var body: some View {
        let up = max(0, scrollY), pull = max(0, -scrollY)
        Color.clear.frame(height: height)
            .overlay(alignment: .bottom) {
                content.frame(height: height + spare)
                    .scaleEffect(1 + pull / height, anchor: .top)
                    .offset(y: min(up * 0.5, spare) - pull)
            }
            .clipped()
    }
}

/// A small icon button for the top bar, the same family as the bottom bar's pills.
extension View {
    func pillIcon() -> some View {
        self.font(.system(size: 14, weight: .semibold)).foregroundStyle(ColorTokens.textPrimary)
            .frame(width: 34, height: 30)
            .background(ColorTokens.card, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
            .contentShape(Capsule())
    }
}

/// The buttons at the top right of a screen: small pills, with none of the system's larger round backgrounds behind them.
struct TrailingPills<Content: View>: ToolbarContent {
    @ViewBuilder var content: Content
    var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarTrailing) { HStack(spacing: 6) { content }.buttonStyle(.press) }.sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarTrailing) { HStack(spacing: 6) { content }.buttonStyle(.press) }
        }
    }
}
