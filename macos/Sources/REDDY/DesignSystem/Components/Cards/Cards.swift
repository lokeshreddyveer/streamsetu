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
    var showsTitle = true
    var body: some View {
        let h = PosterTint.hue(for: title)
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [PosterTint.color(hue: h, saturation: 0.25, lightness: 0.29), PosterTint.color(hue: h, saturation: 0.28, lightness: 0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { g in
                Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                    .background(Circle().fill(LinearGradient(colors: [Color(hex: 0xEAD3A3, opacity: 0.10), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .frame(width: g.size.width * 0.86, height: g.size.width * 0.86)
                    .position(x: g.size.width * 0.58, y: g.size.height * 0.30)
            }
            if showsTitle {
                Text(title.uppercased()).font(.system(size: 17, weight: .regular)).tracking(0.7).lineSpacing(0)
                    .lineLimit(4).minimumScaleFactor(0.7).multilineTextAlignment(.leading)
                    .foregroundStyle(ColorTokens.textPrimary.opacity(0.92)).padding(12)
            }
        }
    }
}

/// Real artwork over the placeholder; the placeholder stays visible if the image is missing or fails.
struct PosterArt: View {
    let title: String
    let url: String?
    var kind: ArtworkKind = .poster
    var body: some View {
        ZStack {
            PosterPlaceholder(title: title)
            if url.nilIfEmpty != nil { ArtworkImage(url: url, kind: kind, showsPlaceholder: false) }
        }
    }
}

// MARK: - Poster card

struct PosterCardModel: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let imageURL: String?
    var tag: String?
    var rank: Int?
    var progress: Double?
    var isFavorite = false
    /// A series with an episode the person has not played yet.
    var isNew = false
    /// Watched to the end: a green tick in the corner.
    var isWatched = false

    init(item: LibraryItem, rank: Int? = nil, progress: Double? = nil, isFavorite: Bool = false, isNew: Bool = false, isWatched: Bool = false) {
        id = item.id; title = item.title
        subtitle = [item.year.flatMap { item.title.contains(String($0)) ? nil : String($0) }, item.genre, item.isSeries ? "Series" : nil].compactMap { $0 }.joined(separator: " · ")
        imageURL = item.posterURL
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
    @FocusState private var focus: Field?
    @Environment(\.reddyAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum Field { case detail, play }

    private var height: CGFloat { (width * 1.45).rounded() }
    private var showPlay: Bool { hovering || focus != nil }

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
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                PosterArt(title: model.title, url: model.imageURL)
                if model.isNew {
                    Text("NEW").font(.system(size: 8, weight: .heavy)).tracking(0.6).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 3)
                        .background(accent, in: RoundedRectangle(cornerRadius: 3)).padding(8).accessibilityLabel("New episode")
                }
                if let r = model.rank {
                    Text("\(r)").font(.system(size: 27, weight: .heavy)).foregroundStyle(Color.white.opacity(0.62)).padding(.leading, 10).padding(.top, 4)
                }
                if let t = model.tag {
                    Text(t).font(.system(size: 8, weight: .semibold)).tracking(0.5).padding(.horizontal, 5).padding(.vertical, 3)
                        .background(Color(hex: 0x080A0D, opacity: 0.78), in: RoundedRectangle(cornerRadius: 3)).frame(maxWidth: .infinity, alignment: .trailing).padding(8)
                }
                if model.isWatched {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).symbolRenderingMode(.palette).foregroundStyle(.white, Color(red: 0.2, green: 0.72, blue: 0.4))
                        .shadow(color: .black.opacity(0.5), radius: 3).padding(7).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).accessibilityLabel("Watched")
                }
                if model.isFavorite { Image(systemName: "heart.fill").font(.system(size: 9)).foregroundStyle(accent).padding(6).background(.black.opacity(0.55), in: Circle()).frame(maxWidth: .infinity, alignment: .trailing).padding(.top, model.tag == nil ? 6 : 30).padding(.trailing, 6) }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(focus != nil ? accent : (hovering ? Color.white.opacity(0.28) : Color.white.opacity(0.07)), lineWidth: focus != nil ? 2 : 1))
            .shadow(color: .black.opacity(hovering ? 0.55 : 0.18), radius: hovering ? 18 : 6, y: hovering ? 10 : 3)
            .scaleEffect(hovering && !reduceMotion ? 1.035 : 1, anchor: .center)
            .animation(reduceMotion ? nil : AnimationTokens.hover, value: hovering)
            .overlay(alignment: .bottom) { if let p = model.progress, p > 0 { ProgressBar(fraction: p).padding(8) } }

            Text(model.title).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.tail).padding(.top, 7)
            Text(model.subtitle).font(.system(size: 10)).foregroundStyle(ColorTokens.textSecondary).lineLimit(1).padding(.top, 3)
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
    let items: [Item]
    @ViewBuilder let card: (Item, Int) -> Card
    @State private var index = 0
    private let step = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 16, weight: .semibold)).tracking(-0.2)
                    if let caption { Text(caption).font(.system(size: 10)).foregroundStyle(ColorTokens.textTertiary) }
                }
                Spacer()
                arrow("chevron.left", "Scroll \(title) left", disabled: index == 0) { index = max(0, index - step) }
                arrow("chevron.right", "Scroll \(title) right", disabled: index >= items.count - 1) { index = min(items.count - 1, index + step) }
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 11) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in card(item, i + 1).id(item.id) }
                    }.scrollTargetLayout().padding(.vertical, 12).padding(.horizontal, 6)      // room for the hover lift and shadow
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .padding(.vertical, -9).padding(.horizontal, -5)
                .onChange(of: index) { _, i in if items.indices.contains(i) { withAnimation(.smooth(duration: 0.5)) { proxy.scrollTo(items[i].id, anchor: .leading) } } }
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel(title)
    }

    private func arrow(_ symbol: String, _ label: String, disabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(disabled ? ColorTokens.textTertiary : ColorTokens.textSecondary).disabled(disabled).accessibilityLabel(label)
    }
}

// MARK: - Hero

struct HeroModel {
    let title: String
    let kicker: String
    let meta: [String]
    let synopsis: String?
    let imageURL: String?
    let tag: String?
}

/// Featured banner: cinematic artwork, compact copy, one primary action.
struct ReddyHeroBanner: View {
    let model: HeroModel
    var height: CGFloat = 315
    var onPlay: () -> Void
    var onInfo: () -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            HeroArt(title: model.title, url: model.imageURL)
            LinearGradient(colors: [Color(hex: 0x0C121A, opacity: 0.92), .clear], startPoint: .leading, endPoint: UnitPoint(x: 0.85, y: 0.5))
            LinearGradient(colors: [Color(hex: 0x0C121A, opacity: 0.94), .clear], startPoint: .bottom, endPoint: UnitPoint(x: 0.5, y: 0.2))
            VStack(alignment: .leading, spacing: 0) {
                Text(model.kicker).font(.system(size: 9, weight: .bold)).tracking(1.6).foregroundStyle(Color(hex: 0xC4D0D2))
                Text(model.title.uppercased()).font(.system(size: 40, weight: .medium)).tracking(1).lineLimit(2).minimumScaleFactor(0.6)
                    .padding(.top, 12).padding(.bottom, 10).frame(maxWidth: 520, alignment: .leading)
                HStack(spacing: 10) {
                    ForEach(model.meta, id: \.self) { Text($0) }
                    if let t = model.tag { Text(t).font(.system(size: 9, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 3).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ColorTokens.lineStrong)) }
                }.font(.system(size: 11)).foregroundStyle(Color(hex: 0xBDC4CF))
                if let s = model.synopsis, !s.isEmpty {
                    Text(s).font(.system(size: 12)).foregroundStyle(Color(hex: 0xB6BCC7)).lineLimit(2).lineSpacing(2).frame(maxWidth: 340, alignment: .leading).padding(.top, 10)
                }
                HStack(spacing: 8) {
                    Button(action: onPlay) { Label("Play", systemImage: "play.fill").labelStyle(.titleAndIcon) }.buttonStyle(HeroPrimaryStyle())
                    Button(action: onInfo) { Label("More info", systemImage: "info.circle") }.buttonStyle(HeroSecondaryStyle())
                }.padding(.top, 16)
            }
            .padding(28)
        }
        .frame(height: height).frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.10)))
        .accessibilityElement(children: .contain).accessibilityLabel("Featured: \(model.title)")
    }
}

private struct HeroArt: View {
    let title: String
    let url: String?
    var body: some View {
        GeometryReader { g in
            ZStack {
                let h = PosterTint.hue(for: title)
                LinearGradient(colors: [PosterTint.color(hue: h, saturation: 0.22, lightness: 0.14), PosterTint.color(hue: h, saturation: 0.18, lightness: 0.28), Color(hex: 0x202738)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().strokeBorder(Color(hex: 0xD9D4B0, opacity: 0.18)).frame(width: g.size.height * 1.3).position(x: g.size.width * 0.78, y: g.size.height * 0.15)
                if url.nilIfEmpty != nil { ArtworkImage(url: url, kind: .backdrop, showsPlaceholder: false).frame(width: g.size.width, height: g.size.height) }
            }
        }
    }
}

private struct HeroPrimaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: 0x14171F)).padding(.horizontal, 14).frame(height: 32)
            .background(LinearGradient(colors: [.white, Color(hex: 0xD4D9E2)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

private struct HeroSecondaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold)).foregroundStyle(ColorTokens.textPrimary).padding(.horizontal, 14).frame(height: 32)
            .background(Color.white.opacity(configuration.isPressed ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
    }
}

// MARK: - Other cards

/// 16:9 card for resumable items: the image is exactly `width` × `width·9/16`, the text sits beneath it, and the card is
/// never wider or taller than its own content, so neighbours in a rail can't overlap.
struct LandscapeCard: View {
    let title: String
    var subtitle: String?
    let imageURL: String?
    var progress: Double?
    var width: CGFloat = LayoutTokens.landscapeCard.width
    @State private var hovering = false
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottom) {
                PosterArt(title: title, url: imageURL, kind: .backdrop)
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
