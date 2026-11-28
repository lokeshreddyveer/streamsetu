import SwiftUI

/// Listen Now: a personal front page, top to bottom: greeting with Refresh and quick actions, Continue listening, one hero, Made for you, New for you, On
/// repeat, Rediscover, Artists you love, Because you play X, the films-and-people block, a real top-tracks list, and Explore more. A new listener gets a
/// welcome card instead (no charts: those live in Explore). A section with fewer than three good items is not there. Nothing here is labelled by country.
/// The feed is composed off the main thread (`HomeEngine`, `MusicHomeFeedModel`) and the last one is painted at once; nothing is composed in `body`.
struct MusicHomePage: View {
    let hub: MusicHub
    private let model = MusicHomeFeedModel.shared
    @Environment(\.musicLayoutClass) private var layoutClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showImport = false

    var body: some View {
        let spec = MusicHomeLayout.spec(for: layoutClass)
        MusicScreen(title: Localized.string("Listen Now"), trailing: { EmptyView() }, content: {
            // lazy: a section is built when it nears the screen
            LazyVStack(alignment: .leading, spacing: spec.sectionGap) {
                MusicHomeHeader(hub: hub, refreshing: model.refreshing, onRefresh: refresh)
                if let feed = model.feed { loaded(feed) } else { skeleton }
            }
        })
        .sheet(isPresented: $showImport) {
            MusicImportPage(hub: hub, onClose: { showImport = false }).frame(minWidth: 560, minHeight: 520).atlasScreen("screen.music.import")
        }
        .task {
            let refresh = hub.userRefreshToken != model.handledRefreshToken
            model.handledRefreshToken = hub.userRefreshToken
            // Composing the first feed takes a while on a slow network; it carries on if the person leaves the page (the result and the caches are kept).
            let work = Task { await model.open(hub: hub, refresh: refresh) }
            await work.value
        }
        .task(id: model.feed == nil) {
            // After a reset or a wipe the feed is gone while this page is still on screen: compose it again instead of leaving the skeleton.
            if model.feed == nil { Task { await model.open(hub: hub, refresh: false) } }
        }
        .task(id: hub.library.blacklist.count) { if model.feed != nil { model.refreshContinue(hub: hub) } }
        // Locked or unlocked, another language or source, or a first like, follow or import while on screen: a feed that no longer fits is made again
        // (one that fits stays as it is). Its own task, so a later change does not cancel the compose half way.
        .task(id: feedInputs) { Task { await model.reconcile(hub: hub) } }
        .task(id: hub.library.historyRevision) { model.refreshContinue(hub: hub) }
        .task(id: hub.player.current?.uid) { model.refreshContinue(hub: hub) }
    }

    private var feedInputs: String {
        "\(hub.gated)|\(hub.networkRevision)|\(MusicNetwork.watch.isOnline)|\(hub.library.likedRevision)|\(hub.library.playlistsRevision)|\(hub.library.followedRevision)|\(Localized.activeCode)|\(hub.registry.enabled.sorted())|\(Self.playsWatched(newUser: model.feed?.mode == .newUser, revision: hub.library.historyRevision))"
    }

    /// A welcome page also ends with the first plays, so the play log is watched while it is shown (not otherwise: a play must not rebuild a full page).
    nonisolated static func playsWatched(newUser: Bool, revision: Int) -> Int { newUser ? revision : -1 }

    private func refresh() {
        MusicDebugLog.log("home", "refresh button tapped")
        Task { await model.open(hub: hub, refresh: true) }
    }

    // MARK: the page

    /// The feed as shown now: what the person hid, and any song marked Never Play after the feed was made, leave at once (not at the next compose).
    private func visible(_ composed: HomeFeed) -> HomeFeed {
        HomeFeed.rendered(
            MusicHiddenRecommendations.shared.set.filter(composed),
            trackBlocked: { hub.library.isBlacklisted($0) },
            artistBlocked: { hub.library.isBlacklisted(artist: $0) },
            // The person's own playlists are shown as they are now: a renamed one under its name, a deleted or emptied one not at all.
            localPlaylist: { id in
                guard let p = hub.library.playlist(id: id), !p.tracks.isEmpty else { return nil }
                return HomeItem.make(p, count: Localized.plural(p.tracks.count, one: "%@ song", other: "%@ songs"))
            })
    }

    @ViewBuilder private func loaded(_ composed: HomeFeed) -> some View {
        let feed = visible(composed)
        if let note = note(for: feed.mode) { MusicHomeNote(symbol: note.symbol, text: note.text) }
        if feed.mode == .newUser { MusicHomeWelcomeCard(hub: hub, onImport: { showImport = true }) }
        if !model.continueItems.isEmpty, feed.mode != .newUser { MusicHomeContinue(items: model.continueItems, hub: hub) }
        Group {
            if let hero = feed.hero { MusicHomeHeroCard(hero: hero, hub: hub).id(hero.id) }
            ForEach(feed.sections) { section in
                switch section.kind {
                case .graph: MusicConnectedHomeBlock(hub: hub, model: model)
                case .quickPicks: MusicHomeQuickPicks(section: section, hub: hub)
                default: MusicHomeShelf(section: section, hub: hub)
                }
            }
            if !feed.topTracks.isEmpty { MusicHomeTopTracks(tracks: feed.topTracks, hub: hub) }
            MusicHomeExploreMore(hub: hub)
        }
        // a refresh dims the page a little while the new feed is composed; the layout does not change, so the scroll position stays
        .opacity(model.refreshing ? 0.55 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.refreshing)
    }

    /// The first run with nothing saved: the hero and two shelves at their final size.
    private var skeleton: some View {
        VStack(alignment: .leading, spacing: MusicHomeLayout.spec(for: layoutClass).sectionGap) {
            MusicHomeHeroSkeleton()
            MusicHomeShelfSkeleton()
            MusicHomeShelfSkeleton()
        }
    }

    private func note(for mode: HomeFeed.Mode) -> (symbol: String, text: String)? {
        switch mode {
        case .offline: ("wifi.slash", Localized.string("You are offline. Showing what is on this Mac."))
        case .gated: ("lock", Localized.string("Playback is paused for this profile. Showing your library."))
        default: nil
        }
    }
}

/// A calm one-line note under the greeting (offline, paused).
struct MusicHomeNote: View {
    let symbol: String
    let text: String
    var body: some View {
        Label { Text(verbatim: text).musicText(.body) } icon: { Image(systemName: symbol) }
            .foregroundStyle(ColorTokens.textSecondary)
            .padding(.horizontal, MusicSpace.md).padding(.vertical, MusicSpace.xs)
            .background(ColorTokens.elevated, in: Capsule())
            .accessibilityElement(children: .combine)
    }
}
