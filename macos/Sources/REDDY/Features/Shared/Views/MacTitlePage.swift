import SwiftUI

/// The Mac title page, for a movie or a series. A hero with the artwork, title, facts, one Play and round actions; below it the
/// synopsis beside a details grid, then full-width rails (versions, episodes, cast, similar). The pages differ only in what they pass in.
struct MacTitlePage<Actions: View, More: View, Middle: View, Tail: View>: View {
    let item: LibraryItem
    let model: TitlePageModel
    let hub: TitleHubModel
    let art: HeroArtwork
    let ownOverview: String?
    let play: TitlePageLogic.PlayLabel
    var playEnabled = true
    let onPlay: () -> Void
    let onClose: () -> Void
    let onOpenVersion: (LibraryItem) -> Void
    var onOpenFolder: (() -> Void)? = nil
    @Binding var person: PersonRoute?
    @ViewBuilder let actions: Actions
    @ViewBuilder let more: More
    @ViewBuilder let middle: Middle
    @ViewBuilder let tail: Tail

    @Environment(\.artwork) private var artwork
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var titleScale: CGFloat = 1
    @State private var revealed = false
    @FocusState private var playFocus: Bool

    private var reduceMotion: Bool { BrandMotion.reduced(systemReduceMotion) }
    /// The page's own pictures first; the hub's only where the page has none (never a downgrade).
    private var backdropURL: String? { item.backdropURL.nilIfEmpty ?? hub.backdropURL.nilIfEmpty }
    private var posterURL: String? { item.posterURL.nilIfEmpty ?? hub.posterURL.nilIfEmpty }
    private var artKey: String { (backdropURL ?? "") + "|" + (posterURL ?? "") }

    var body: some View {
        GeometryReader { g in
            let m = TitlePageLogic.metrics(width: g.size.width)
            ZStack(alignment: .topTrailing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        hero(m)
                        content(m).padding(.horizontal, m.margin).padding(.top, 26).padding(.bottom, 40)
                    }
                }
                .scrollContentBackground(.hidden)
                controls
                if let p = person {
                    PersonSheet(person: p) { person = nil }.frame(maxWidth: .infinity, maxHeight: .infinity).background(ColorTokens.background).transition(.move(edge: .trailing))
                }
            }
        }
        .background(ColorTokens.background)
        .animation(.easeOut(duration: 0.2), value: person?.id)
        .task(id: artKey) {
            art.peek(backdrop: backdropURL, poster: posterURL)
            await art.load(backdrop: backdropURL, poster: posterURL, artwork: artwork)
        }
        // The body waits for the saved details (a few milliseconds) behind a skeleton of its own geometry, then appears in one piece. Never longer than 350 ms.
        .task(id: item.id) { try? await Task.sleep(nanoseconds: 350_000_000); reveal() }
        .onChange(of: model.bodyReady) { _, ready in if ready { reveal() } }
        .onAppear { playFocus = true; if model.bodyReady { reveal() } }
    }

    private func reveal() {
        guard !revealed else { return }
        if reduceMotion { revealed = true } else { withAnimation(.easeOut(duration: 0.22)) { revealed = true } }
    }

    // MARK: hero

    private func hero(_ m: TitlePageLogic.Metrics) -> some View {
        // The size comes from the clear base alone: the pictures only fill it, whatever their own proportions.
        Color.clear.frame(maxWidth: .infinity).frame(height: m.heroHeight)
            .background { TitleHeroBackground(art: art, title: DisplayTitle.clean(item.title)) }
            .overlay(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: 26) {
                    if m.poster > 0 { poster(m.poster) }
                    titleBlock(m)
                }
                .padding(.horizontal, m.margin).padding(.bottom, 26)
            }
            .clipped()
    }

    private func poster(_ width: CGFloat) -> some View {
        ArtworkImage(url: posterURL, kind: .poster, contentMode: .fill, alignment: .top, tile: ArtworkTile.Content(title: DisplayTitle.clean(item.title), detail: item.year.map(String.init)))
            .frame(width: width, height: width * 1.5)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
            .accessibilityHidden(true)
    }

    private func titleBlock(_ m: TitlePageLogic.Metrics) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            titleOrLogo(m)
            HStack(spacing: 10) {
                TitleChipsRow(chips: model.info.chips, rating: model.info.rating, spoken: model.info.chipsSpoken).fixedSize(horizontal: true, vertical: false)
                if item.isSeries { NextEpisodeChip(stamp: hub.nextEpisodeStamp, onDark: true).fixedSize() }
                Spacer(minLength: 0)
            }
            Text(model.info.genreLine ?? " ").font(.system(size: 14)).foregroundStyle(Color.white.opacity(0.72)).lineLimit(1)
                .accessibilityHidden(model.info.genreLine == nil)
            FlowLayout(spacing: 10) {
                TitlePlayPill(label: play, enabled: playEnabled, action: onPlay).focused($playFocus)
                actions
                TrailerSection(itemID: item.id, title: item.title, year: item.year, isSeries: item.isSeries, showFacts: false, circle: true)
            }.padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The title in type. When the hub has the title's own logo it is drawn over the same space and the text fades out, so nothing moves when it arrives;
    /// the text stays underneath as the layout and the accessibility label.
    private func titleOrLogo(_ m: TitlePageLogic.Metrics) -> some View {
        let title = DisplayTitle.clean(item.title)
        return Text(title)
            .font(.system(size: m.titleSize * titleScale, weight: .heavy)).lineLimit(2).minimumScaleFactor(0.6).fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.white).shadow(color: .black.opacity(0.55), radius: 10, y: 2)
            .opacity(hub.logoURL.nilIfEmpty == nil ? 1 : 0)
            .overlay(alignment: .leading) {
                if let logo = hub.logoURL.nilIfEmpty {
                    ArtworkImage(url: logo, kind: .backdrop, contentMode: .fit, alignment: .leading, showsPlaceholder: false)
                        .frame(maxWidth: 420, maxHeight: m.titleSize * titleScale * 1.9, alignment: .leading)
                        .shadow(color: .black.opacity(0.5), radius: 8, y: 2).accessibilityHidden(true)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: hub.logoURL)
            .accessibilityLabel(title).accessibilityAddTraits(.isHeader)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Menu { more } label: { Image(systemName: "ellipsis") }
                .menuStyle(.button).buttonStyle(HeroCircleStyle(size: 34)).menuIndicator(.hidden).fixedSize().help("More").accessibilityLabel("More").atlas("screen.title.movie")
            Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(HeroCircleStyle(size: 34)).help("Close").accessibilityLabel("Close").atlas("screen.title.movie")
        }.padding(14)
    }

    // MARK: body

    @ViewBuilder private func content(_ m: TitlePageLogic.Metrics) -> some View {
        if revealed {
            VStack(alignment: .leading, spacing: 30) {
                infoRow(m)
                TitleVersionsSection(versions: model.versions.versions, open: onOpenVersion)
                middle
                TitleCastRail(cast: model.info.cast) { person = $0 }.castRowFocus(item.id)
                tail
                SimilarSection(item: item)
            }
            .transition(.opacity)
        } else {
            TitleBodySkeleton(metrics: m).transition(.opacity)
        }
    }

    @ViewBuilder private func infoRow(_ m: TitlePageLogic.Metrics) -> some View {
        let text = ownOverview?.nilIfEmpty ?? model.info.story
        let rows = TitlePageLogic.gridRows(model.info.rows, castShown: !model.info.cast.isEmpty)
        let synopsis = Group {
            if let text { MacSynopsis(text: text, tagline: model.info.tagline) }
            else if !model.settled { VStack(alignment: .leading, spacing: 10) { SkeletonBlock(height: 14); SkeletonBlock(height: 14); SkeletonBlock(width: 220, height: 14) } }
        }
        let details = TitleDetailsGrid(rows: rows, onPerson: { person = $0 }, onFolder: onOpenFolder)
        if m.columns == .two {
            HStack(alignment: .top, spacing: 36) {
                synopsis.frame(maxWidth: .infinity, alignment: .leading)
                if !rows.isEmpty { details.frame(width: m.sideWidth) }
            }
        } else {
            VStack(alignment: .leading, spacing: 24) { synopsis; if !rows.isEmpty { details } }
        }
    }
}
