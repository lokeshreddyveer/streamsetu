import SwiftUI

// Detail pages: album, artist, playlist, local playlist, genre and user. Lists load the next page as the end comes into view.

// MARK: paging

/// Loads a list one page at a time. The loader receives nil for the first page, then the strategy the provider returned.
@MainActor @Observable
final class MusicPagedList<T: Sendable> {
    typealias Loader = @MainActor (MusicPagination?) async throws -> MusicPage<T>
    enum State: Equatable { case idle, loading, loaded, failed(String) }

    private(set) var items: [T] = []
    private(set) var state = State.idle
    private(set) var loadingMore = false
    /// The last attempt to load another page failed. The page keeps what it has and offers "Try again" under the list.
    private(set) var loadMoreFailed = false
    private(set) var next: MusicPagination?
    @ObservationIgnored private let loader: Loader
    @ObservationIgnored private let describe: @MainActor (Error) -> String
    @ObservationIgnored private var generation = 0

    var hasMore: Bool { next != nil }

    init(describe: @escaping @MainActor (Error) -> String = { $0.localizedDescription }, loader: @escaping Loader) {
        self.loader = loader; self.describe = describe
    }

    func loadIfNeeded() async { if state == .idle { await reload() } }

    func reload() async {
        generation += 1; let g = generation
        state = .loading; loadingMore = false; loadMoreFailed = false; next = nil; items = []
        do {
            let p = try await loader(nil)
            guard g == generation else { return }
            items = p.items; next = p.next; state = .loaded
        } catch {
            guard g == generation, !Self.isCancel(error) else { return }
            state = .failed(describe(error))
        }
    }

    /// Swaps in a better version of the rows already shown (catalogue enrichment that finished after the first paint). Ignored while loading,
    /// when it would drop songs, or when nothing changed.
    func replaceItems(_ better: [T], key: (T) -> String) {
        guard state == .loaded, !loadingMore, MusicFirstPaint.shouldReplace(painted: items.map(key), enriched: better.map(key)) else { return }
        items = better
    }

    func loadMore() async {
        guard let n = next, !loadingMore, state == .loaded else { return }
        let g = generation; loadingMore = true; loadMoreFailed = false
        defer { if g == generation { loadingMore = false } }
        do {
            let p = try await loader(n)
            guard g == generation else { return }
            items += p.items; next = p.next
        } catch {
            guard g == generation, !Self.isCancel(error) else { return }
            // The list stays as it is; the next page is tried again only when the person asks.
            loadMoreFailed = true
        }
    }

    private static func isCancel(_ e: Error) -> Bool { e is CancellationError || (e as? MusicError) == .cancelled }
}

/// Loads one value (an artist overview, a user).
enum MusicLoad<Value> {
    case loading, loaded(Value), failed(String)
}

@MainActor enum MusicDetailSource {
    static func metadata(_ hub: MusicHub, providerID: String) throws -> any MusicMetadataProvider {
        guard let p = hub.registry.metadataProvider(id: providerID) else { throw MusicError.unsupported("this source is switched off in Settings") }
        return p
    }
}

// MARK: shared pieces

/// Back button, soft artwork backdrop and the standard page padding. The page remembers where it was scrolled to and shows a back-to-top button
/// when it is long.
struct MusicPageScaffold<Content: View>: View {
    let hub: MusicHub
    var thumbs: [MusicThumbnail] = []
    var scrollKey: String?
    @ViewBuilder var content: () -> Content
    @Environment(\.reddyAccent) private var accent

    private var key: String { scrollKey ?? hub.nav.top.map(MusicScrollKey.route) ?? "page" }

    var body: some View {
        MusicOverlayHostView(hub: hub) {
            ZStack(alignment: .top) {
                if !thumbs.isEmpty {
                    MusicCoverImage(thumbs: thumbs.filter { !MusicArtworkURLSizing.isServiceCollage($0.url) }, corner: 0, pixelHint: 256).artwork(of: nil, slot: .backdrop)
                        .frame(height: 380).frame(maxWidth: .infinity).clipped().blur(radius: 70).saturation(1.3).opacity(0.38)
                        .overlay(ColorTokens.background.opacity(0.35))
                        .mask(LinearGradient(colors: [ColorTokens.textPrimary, ColorTokens.textPrimary.opacity(0)], startPoint: .top, endPoint: .bottom))
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                MusicPageColumn(spacing: MusicSpace.lg, memoryKey: key) {
                    // The toolbar above already has Back and Forward, so the page carries no second Back row (it cost a whole line above the cover).
                    // Escape still goes back: a hidden zero-size button holds the shortcut.
                    Button { hub.nav.back() } label: { EmptyView() }
                        .buttonStyle(.plain).frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
                        .keyboardShortcut(.cancelAction).atlas("control.music.albumArtistAndPlaylistPagesBack")
                        .padding(.bottom, -MusicSpace.lg)
                    content()
                }
            }
        }
    }
}

struct MusicPageHeader<Actions: View>: View {
    let title: String
    var kind = ""
    var subtitle = ""
    var thumbs: [MusicThumbnail] = []
    var round = false
    var coverSize: CGFloat = 190
    var titleFont: Font = Typography.pageTitle
    /// A cover of the page's own (a playlist's chosen picture); the thumbnails are used when there is none.
    var customCover: AnyView?
    /// What the page is about: with it a missing cover is looked up (an artist's photo, an album's or a playlist's cover).
    var subject: MusicArtworkSubject?
    /// A line of views under the title, for links (the album's artist).
    var detail: AnyView?
    @ViewBuilder var actions: () -> Actions
    @Environment(\.musicLayoutClass) private var layoutClass

    var body: some View {
        // On a narrow page the cover sits above the text (as the album header does), so the title and the action row get the full width.
        let layout = layoutClass == .compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) : AnyLayout(HStackLayout(alignment: .bottom, spacing: 22))
        layout {
            Group {
                if let customCover { customCover } else { MusicArtwork(thumbs, size: coverSize, corner: round ? coverSize / 2 : 16, subject: subject) }
            }
            .shadow(color: ColorTokens.background.opacity(0.7), radius: 18, y: 8)
            VStack(alignment: .leading, spacing: 8) {
                if !kind.isEmpty { Text(verbatim: kind.uppercased()).font(Typography.eyebrow).tracking(1.2).foregroundStyle(ColorTokens.textTertiary) }
                Text(verbatim: title).font(titleFont).lineLimit(3).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                if let detail { detail }
                if !subtitle.isEmpty { Text(verbatim: subtitle).font(Typography.body).foregroundStyle(ColorTokens.textSecondary).lineLimit(3) }
                MusicGraphFlowLayout(spacing: 10) { actions() }.padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Play and Shuffle for a track list.
struct MusicPlayShuffleButtons: View {
    let hub: MusicHub
    let tracks: [MusicTrack]
    /// The page's own name (and id when it has one): "Playing from" and "Back to" name it, never the first song.
    var sourceName: String? = nil
    var sourceID: String? = nil
    var body: some View {
        Button { if !tracks.isEmpty { hub.play(tracks, at: 0, sourceName: sourceName, sourceID: sourceID) } } label: { Label("Play", systemImage: "play.fill") }
            .musicButton(.hero, size: .large).disabled(tracks.isEmpty).accessibilityLabel("Play all").atlas("control.music.albumArtistAndPlaylistPagesPlayAll")
        Button {
            hub.playShuffled(tracks, sourceName: sourceName, sourceID: sourceID)
        } label: { Label("Shuffle", systemImage: "shuffle") }.musicButton(.secondary, size: .large).disabled(tracks.isEmpty).accessibilityLabel("Shuffle all").atlas("control.music.albumArtistAndPlaylistPagesShuffleAll")
    }
}

/// The round "..." button of a page header; its items are the page's own.
struct MusicOverflowMenu<Items: View>: View {
    var label = "More"
    @ViewBuilder var items: () -> Items
    var body: some View {
        // A menu draws only its label (a macOS menu ignores a background put on the label), so the button look comes from the same button style as the
        // header's other icon buttons: the "..." has the same border and size as Heart and Add to playlist.
        Menu { items() } label: {
            Image(systemName: "ellipsis").font(MusicTokens.iconLarge)
        }
        .menuStyle(.button).menuIndicator(.hidden).musicButton(.glassIcon, size: .large).fixedSize()
        .accessibilityLabel(LocalizedStringKey(label)).help(LocalizedStringKey(label)).atlas("control.music.pageMenu")
    }
}

/// The "Load more" button at the end of a paged list that is not a track list (a shelf of albums).
struct MusicLoadMoreButton<T: Sendable>: View {
    let list: MusicPagedList<T>
    var body: some View {
        if list.loadMoreFailed { MusicLoadMoreFailedLine { Task { await list.loadMore() } } }
        else if list.hasMore {
            HStack {
                Spacer()
                if list.loadingMore { MusicLoadingIcon(size: MusicIconSize.small) }
                else { Button("Load more") { Task { await list.loadMore() } }.musicButton(.secondary).accessibilityLabel("Load more").atlas("control.music.albumArtistAndPlaylistPagesLoadMore") }
                Spacer()
            }.padding(.vertical, 10)
        }
    }
}


// MARK: route dispatch

/// Shows the page for a route. The host calls this with `hub.nav.top`.
struct MusicRouteView: View {
    let hub: MusicHub
    let route: MusicRoute
    var body: some View {
        switch route {
        case .album, .artist, .actor: MusicProviderEntityPage(hub: hub, route: route)
        case .playlist(let p): MusicPlaylistPage(hub: hub, playlist: p)
        case .localPlaylist(let id): MusicLocalPlaylistPage(hub: hub, id: id)
        case .genre(let g): MusicCategoryPage(hub: hub, genre: g).id(g.id)
        case .user(let u): MusicUserPage(hub: hub, user: u)
        case .blacklist: MusicBlacklistPage(hub: hub)
        case .node(let r):
            MusicNodeRouteView(hub: hub, route: r)
        case .collection(let c): MusicCollectionPage(hub: hub, key: c)
        }
    }
}

/// One switch over the entity page of a `.node` route: song, album and release, person and group, film and series each open their own graph page; every other kind keeps the scaffold.
struct MusicNodeRouteView: View {
    let hub: MusicHub
    let route: MusicEntityRoute
    var body: some View {
        switch route.page {
        case .song: MusicSongPage(entity: route.id, hub: hub)
        case .album: MusicSoundtrackPage(entity: route.id, hub: hub)
        case .person: MusicPersonPage(entity: route.id, role: route.role, hub: hub)
        case .film, .series: MusicFilmPage(entity: route.id, hub: hub).id(route.id)
        case .playlist: MusicPlaylistEntityPage(hub: hub, entity: route.id).id(route.id)
        case .language, .era, .region, .genre: MusicFacetPage(hub: hub, route: route).id(route.id)
        default: MusicEntityScaffoldPage(hub: hub, route: route)
        }
    }
}

// MARK: provider values -> the connected pages

/// An album, artist or actor that arrived as a provider value opens the SAME connected page as every other way in (there is one album page, one
/// artist page and one person page). The entity is found or saved first; until it is, the page shows a quiet skeleton.
struct MusicProviderEntityPage: View {
    let hub: MusicHub
    let route: MusicRoute
    @State private var id: MusicEntityID?
    /// Set when the graph could not find or save the entity: the page then says so (with Try again) instead of showing the skeleton for ever.
    @State private var unavailable = false

    /// What the page shows while it has no entity: a skeleton while it looks, the "not available" state once the look-up has answered nothing.
    static func showsUnavailable(resolved: MusicEntityID?, lookupFinished: Bool) -> Bool { resolved == nil && lookupFinished }

    private var unavailableTitle: String {
        if case .album = route { return Localized.string("This album is not available right now.") }
        return Localized.string("This page is not available right now.")
    }

    var body: some View {
        Group {
            if let id {
                switch route {
                case .album: MusicSoundtrackPage(entity: id, hub: hub, memoryKey: route.scrollKey)
                case .actor: MusicPersonPage(entity: id, role: .actor, hub: hub)
                default: MusicPersonPage(entity: id, role: nil, hub: hub)
                }
            } else if Self.showsUnavailable(resolved: id, lookupFinished: unavailable) {
                MusicPageScaffold(hub: hub) {
                    MusicEmptyState(glyph: .note, title: unavailableTitle, message: Localized.string("Go back and try again in a moment."),
                                    actionTitle: Localized.string("Try again")) { unavailable = false; Task { await resolve() } }
                }
            } else {
                MusicPageScaffold(hub: hub) { MusicShelfSkeleton().accessibilityHidden(true) }
            }
        }
        .task(id: route) { await resolve() }
    }

    private func resolve() async {
        unavailable = false
        var found = await hub.entityID(for: route)
        // The graph can be busy for a moment (a first open while it is saving other things). A page that finds nothing asks twice more, a little later, before it says "not available".
        for pause in [0.4, 1.2] where found == nil {
            try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
            guard !Task.isCancelled else { return }
            found = await hub.entityID(for: route)
        }
        if found == nil { MusicDebugLog.log("nav", "page not available after three tries: \(route.scrollKey)") }
        // An album opened from a provider value lands on the edition the person marked as preferred (the star in the Versions list), when there is one.
        if case .album = route, let e = found {
            let concept = await MusicAlbumReads.albumConcept(MusicSoundtrackReader(MusicEntityRuntime.shared.store.graph), e)
            if let pick = MusicAlbumPrefs.load().preferredRedirect(from: e, concept: concept) { found = pick }
        }
        guard !Task.isCancelled else { return }
        id = found
        unavailable = found == nil
    }
}

// The playlist pages (a service's and the person's own) live in Playlist/MusicPlaylistPage.swift and Playlist/MusicLocalPlaylistPage.swift.

// MARK: user

struct MusicUserPage: View {
    let hub: MusicHub
    let user: MusicUser
    @State private var loaded = MusicLoad<MusicUser>.loading

    var body: some View {
        MusicPageScaffold(hub: hub, thumbs: user.thumbnails) {
            switch loaded {
            case .loading: MusicLoadingView().frame(height: 200)
            case .failed(let m): MusicErrorView(message: m) { Task { await load() } }.frame(height: 200)
            case .loaded(let u):
                MusicPageHeader(title: u.displayName ?? u.username, kind: Localized.string("Profile"), subtitle: "@" + u.username, thumbs: u.thumbnails.isEmpty ? user.thumbnails : u.thumbnails, round: true) {
                    if let s = u.externalURL, let url = URL(string: s) { Link("Open profile", destination: url).accessibilityLabel("Open profile in the browser") }
                }
                MusicEmptyState(symbol: "person.crop.circle", title: Localized.string("Profile only"), message: Localized.string("This source does not list a person's tracks. Search for their name to find their music.")).frame(minHeight: 220)
            }
        }
        .task { await load() }
    }

    private func load() async {
        loaded = .loading
        do {
            let u = try await MusicDetailSource.metadata(hub, providerID: user.providerID).user(id: user.id)
            loaded = .loaded(u ?? user)
        } catch where !(error is CancellationError) { loaded = .failed(hub.loadError(error)) }
        catch {}
    }
}
