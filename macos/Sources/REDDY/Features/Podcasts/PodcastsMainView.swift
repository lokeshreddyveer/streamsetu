import SwiftUI

/// Podcasts in the main window. The sidebar (Discover, Following, Recently Played, Up Next) and the bottom bar belong to the shell; this is the page.
/// `PodcastsHub` holds what is open and what is loaded; Back unwinds its stack (home, search results or a category).
struct PodcastsMainView: View {
    var hub: PodcastsHub = .shared
    @Environment(\.container) private var container

    var body: some View {
        Group {
            switch hub.nav.top {
            case .show(let s)?: PodcastShowPage(hub: hub, show: s).id(s.id)
            case .genre(let g)?: PodcastGenrePage(hub: hub, genre: g)
            case nil:
                switch hub.nav.section {
                case .discover: PodcastsDiscoverPage(hub: hub)
                case .following: PodcastsFollowingPage(hub: hub)
                case .recent: PodcastsRecentPage(hub: hub)
                case .upNext: PodcastsUpNextPage(hub: hub)
                }
            }
        }
        .atlasScreen("screen.destination.podcasts")
        .onAppear { hub.reloadFollowing(); hub.loadTop(); hub.refreshFollowing() }
    }
}

// MARK: building blocks

/// A square cover with the title and author under it; a dot marks a followed show with a new episode.
struct PodcastCover: View {
    let show: PodcastSubscription
    var dot = false
    var rank: Int?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkImage(url: show.artwork?.absoluteString, kind: .poster, contentMode: .fill, symbol: "mic.fill")
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ColorTokens.line, lineWidth: 0.75))
                .overlay(alignment: .topTrailing) { if dot { Circle().fill(ColorTokens.accentDefault).frame(width: 11, height: 11).overlay(Circle().strokeBorder(ColorTokens.background, lineWidth: 2)).padding(7).accessibilityLabel("New episode") } }
                .overlay(alignment: .bottomLeading) { if let rank { Text(verbatim: "\(rank)").font(Typography.micro).padding(.horizontal, 6).padding(.vertical, 2).background(ColorTokens.background.opacity(0.78), in: Capsule()).foregroundStyle(ColorTokens.textPrimary).padding(6) } }
            Text(verbatim: show.title).font(Typography.bodyMedium).lineLimit(2).multilineTextAlignment(.leading).foregroundStyle(ColorTokens.textPrimary)
            if !show.author.isEmpty { Text(verbatim: show.author).font(Typography.caption).lineLimit(1).foregroundStyle(ColorTokens.textSecondary) }
        }
        .contentShape(Rectangle())
    }
}

private let coverColumns = [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 16, alignment: .top)]

struct PodcastsSectionTitle: View {
    let title: LocalizedStringKey
    var body: some View { Text(title).font(Typography.title).accessibilityAddTraits(.isHeader) }
}

private struct CoverSkeleton: View {
    var body: some View {
        LazyVGrid(columns: coverColumns, alignment: .leading, spacing: 16) {
            ForEach(0..<8, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 12).fill(ColorTokens.elevated).aspectRatio(1, contentMode: .fit)
                    RoundedRectangle(cornerRadius: 3).fill(ColorTokens.elevated).frame(height: 10)
                    RoundedRectangle(cornerRadius: 3).fill(ColorTokens.card).frame(width: 90, height: 8)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct CoverGrid: View {
    let hub: PodcastsHub
    let shows: [PodcastSubscription]
    var ranked = false
    var dots = false
    var body: some View {
        LazyVGrid(columns: coverColumns, alignment: .leading, spacing: 18) {
            ForEach(Array(shows.enumerated()), id: \.element.id) { i, s in
                Button { hub.open(s) } label: { PodcastCover(show: s, dot: dots && hub.hasNew(s), rank: ranked ? i + 1 : nil) }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if hub.isFollowing(s) { Button("Unfollow", role: .destructive) { hub.unfollow(s) }.atlas("control.podcasts.queue") }
                    }
                    .atlas("context.podcasts.show")
            }
        }
    }
}

/// The page frame shared by the Podcasts pages: a title row, optional Back, scrolling body.
struct PodcastsPage<Content: View, Trailing: View>: View {
    let title: LocalizedStringKey
    var back: (() -> Void)?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let back { Button(action: back) { Label("Back", systemImage: "chevron.left").font(Typography.bodyMedium) }.buttonStyle(.plain).foregroundStyle(accent).keyboardShortcut(.cancelAction).atlas("screen.destination.podcasts") }
                HStack(alignment: .firstTextBaseline) { Text(title).font(Typography.pageTitle); Spacer(minLength: 12); trailing }
                content
            }
            .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 28)
            .frame(maxWidth: 1180, alignment: .leading).frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }
}

// MARK: Discover

struct PodcastsDiscoverPage: View {
    @Bindable var hub: PodcastsHub
    @FocusState private var searchFocused: Bool
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        PodcastsPage(title: "Podcasts", back: nil, trailing: { EmptyView() }) {
            searchField
            if hub.isSearchActive { results } else { home }
            Text("Shows and charts come from the public podcast directory. Only the words you search for and your two-letter region are sent.")
                .font(Typography.caption).foregroundStyle(ColorTokens.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium)).foregroundStyle(ColorTokens.textTertiary)
            TextField("Search shows, or paste a feed address", text: $hub.term).textFieldStyle(.plain).font(Typography.body).focused($searchFocused)
                .onSubmit { hub.search() }.onExitCommand { hub.clearSearch() }.accessibilityIdentifier("podcasts.search")
            if !hub.term.isEmpty {
                Button { hub.clearSearch() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 14)) }
                    .buttonStyle(.plain).foregroundStyle(ColorTokens.textSecondary).accessibilityLabel("Clear search").atlas("control.podcasts.search")
            }
        }
        .padding(.horizontal, 16).frame(height: 44).frame(maxWidth: 680)
        .podcastFieldStyle(focused: searchFocused, accent: accent)
    }

    @ViewBuilder private var results: some View {
        if hub.searching { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking…").font(Typography.body).foregroundStyle(ColorTokens.textSecondary) }; CoverSkeleton() }
        if let m = hub.message { Text(verbatim: m).font(Typography.body).foregroundStyle(ColorTokens.textSecondary) }
        if !hub.found.isEmpty { PodcastsSectionTitle(title: "Results"); CoverGrid(hub: hub, shows: hub.found) }
    }

    @ViewBuilder private var home: some View {
        if !hub.following.isEmpty {
            PodcastsSectionTitle(title: "Following")
            CoverGrid(hub: hub, shows: Array(hub.following.prefix(12)), dots: true)
        }
        let cont = hub.library.continueListening()
        if !cont.isEmpty {
            PodcastsSectionTitle(title: "Continue listening")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340, maximum: 520), spacing: 12)], spacing: 12) {
                ForEach(cont, id: \.ref.id) { item in PodcastEpisodeCard(hub: hub, ref: item.ref, progress: item.progress) }
            }
        }
        PodcastsSectionTitle(title: "Top Shows")
        switch hub.top {
        case .idle, .loading: CoverSkeleton()
        case .failed:
            EmptyStateView(symbol: "wifi.slash", title: "Couldn't load the charts", message: "Check your connection and try again. Search and the shows you follow still work.")
                .frame(height: 170).overlay(alignment: .bottom) { Button("Try Again") { hub.loadTop(refresh: true) }.buttonStyle(SecondaryButtonStyle()).atlas("control.podcasts.search") }
        case .loaded(let r):
            if r.stale { Label("Showing the last saved chart.", systemImage: "clock").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary) }
            CoverGrid(hub: hub, shows: r.shows, ranked: true)
        }
        PodcastsSectionTitle(title: "Browse by category")
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 10)], spacing: 10) {
            ForEach(PodcastGenre.allCases) { g in
                Button { hub.openGenre(g) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: g.symbol).font(.system(size: 15)).frame(width: 22).foregroundStyle(ColorTokens.accentDefault)
                        Text(LocalizedStringKey(g.title)).font(Typography.bodyMedium).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).frame(height: 44).surface(radius: LayoutTokens.radiusSmall).contentShape(Rectangle())
                }
                .buttonStyle(.plain).atlas("control.podcasts.category")
            }
        }
    }
}

/// A recent or in-progress episode as a card with its place.
struct PodcastEpisodeCard: View {
    let hub: PodcastsHub
    let ref: PodcastEpisodeRef
    var progress: PodcastProgress?
    var body: some View {
        Button { hub.player.play(ref) } label: {
            HStack(spacing: 12) {
                ArtworkImage(url: ref.artwork?.absoluteString, kind: .poster, contentMode: .fill, symbol: "mic.fill").frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: ref.title).font(Typography.bodyMedium).lineLimit(2).multilineTextAlignment(.leading)
                    Text(verbatim: ref.showTitle).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
                    if let progress, !progress.played { PodcastProgressBar(fraction: progress.fraction).frame(height: 3) }
                }
                Spacer(minLength: 0)
                Image(systemName: "play.circle.fill").font(.system(size: 26)).foregroundStyle(ColorTokens.accentDefault)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading).surface().contentShape(Rectangle())
        }
        .buttonStyle(.plain).atlas("control.podcasts.play")
    }
}

struct PodcastProgressBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(ColorTokens.textPrimary.opacity(0.14))
                Capsule().fill(ColorTokens.accentDefault).frame(width: g.size.width * min(1, max(0, fraction)))
            }
        }
    }
}

// MARK: Category

struct PodcastGenrePage: View {
    let hub: PodcastsHub
    let genre: PodcastGenre
    var body: some View {
        PodcastsPage(title: LocalizedStringKey(genre.title), back: { hub.back() }, trailing: { EmptyView() }) {
            switch hub.genreResults {
            case .idle, .loading: CoverSkeleton()
            case .failed:
                EmptyStateView(symbol: "wifi.slash", title: "Couldn't load this category", message: "Check your connection and try again.")
                    .frame(height: 170).overlay(alignment: .bottom) { Button("Try Again") { hub.retryGenre() }.buttonStyle(SecondaryButtonStyle()).atlas("control.podcasts.category") }
            case .loaded(let r):
                if r.stale { Label("Showing the last saved chart.", systemImage: "clock").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary) }
                CoverGrid(hub: hub, shows: r.shows, ranked: true)
            }
        }
    }
}

// MARK: Following, Recently Played, Up Next

struct PodcastsFollowingPage: View {
    let hub: PodcastsHub
    var body: some View {
        PodcastsPage(title: "Following", back: nil, trailing: { EmptyView() }) {
            if hub.following.isEmpty {
                EmptyStateView(symbol: "heart", title: "No shows followed yet", message: "Open a show and choose Follow to keep it here. A dot appears on its cover when a new episode comes out.").frame(height: 240)
            } else { CoverGrid(hub: hub, shows: hub.following, dots: true) }
        }
    }
}

struct PodcastsRecentPage: View {
    let hub: PodcastsHub
    var body: some View {
        PodcastsPage(title: "Recently Played", back: nil, trailing: {
            if !hub.library.recents().isEmpty { Button("Clear") { hub.library.clearRecents() }.buttonStyle(SecondaryButtonStyle()).atlas("control.podcasts.queue") }
        }) {
            let list = hub.library.recents()
            if list.isEmpty {
                EmptyStateView(symbol: "clock", title: "Nothing played yet", message: "Episodes you listen to show up here with your place in them.").frame(height: 240)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340, maximum: 560), spacing: 12)], spacing: 12) {
                    ForEach(list) { r in PodcastEpisodeCard(hub: hub, ref: r, progress: hub.library.progress(r.itemID)) }
                }
            }
        }
    }
}

struct PodcastsUpNextPage: View {
    let hub: PodcastsHub
    var body: some View {
        PodcastsPage(title: "Up Next", back: nil, trailing: {
            if !hub.library.queue.isEmpty { Button("Clear") { hub.library.clearQueue() }.buttonStyle(SecondaryButtonStyle()).atlas("control.podcasts.queue") }
        }) {
            PodcastQueueList(hub: hub)
        }
    }
}

struct PodcastQueueList: View {
    let hub: PodcastsHub
    var body: some View {
        let q = hub.library.queue
        if q.isEmpty {
            EmptyStateView(symbol: "text.line.first.and.arrowtriangle.forward", title: "Nothing queued", message: "Right-click an episode and choose Add to Up Next. The next one starts when this one ends.").frame(height: 240)
        } else {
            VStack(spacing: 8) {
                ForEach(Array(q.enumerated()), id: \.element.id) { i, r in
                    HStack(spacing: 10) {
                        PodcastEpisodeCard(hub: hub, ref: r, progress: hub.library.progress(r.itemID))
                        Button { hub.library.removeFromQueue(r.itemID) } label: { Image(systemName: "xmark.circle").font(.system(size: 15)) }
                            .buttonStyle(.plain).foregroundStyle(ColorTokens.textSecondary).accessibilityLabel("Remove from Up Next").atlas("control.podcasts.queue")
                        VStack(spacing: 2) {
                            Button { hub.library.moveInQueue(from: IndexSet(integer: i), to: i - 1) } label: { Image(systemName: "chevron.up") }.disabled(i == 0).accessibilityLabel("Move up").atlas("control.podcasts.queue")
                            Button { hub.library.moveInQueue(from: IndexSet(integer: i), to: i + 2) } label: { Image(systemName: "chevron.down") }.disabled(i == q.count - 1).accessibilityLabel("Move down").atlas("control.podcasts.queue")
                        }.buttonStyle(.plain).foregroundStyle(ColorTokens.textSecondary).font(.system(size: 11)).atlas("control.podcasts.queue")
                    }
                }
            }
        }
    }
}
