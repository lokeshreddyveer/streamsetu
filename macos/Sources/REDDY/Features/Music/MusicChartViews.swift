import SwiftUI

// The chart pieces of the Music screens: a chart's rows are resolved to playable copies (see `MusicChartResolver`), rows still being looked up show a
// quiet spinner and stay tappable, a copy that differs from the chart's row says so in a small note, and songs with no copy are hidden by default
// with one line that says how many and a button to show them.

/// What a row of a chart list is told: its status line and what a tap does (resolve this row first, then play).
struct MusicChartRowHooks {
    var status: MusicChartRowStatus
    var play: @MainActor () -> Void
    /// Every copy of this song the chart listed, preferred first; empty or one entry when there is only one.
    var versions: [MusicChartVersionChoice] = []
    /// Makes a copy the row's copy and plays it.
    var choose: (@MainActor (MusicTrack) -> Void)?
}

/// Connects the shared chart resolver to this app: the lock, the Never play list, the network rules, the stream checks and the pre-resolver.
@MainActor enum MusicChartBinding {
    private static var boundHub: ObjectIdentifier?

    @discardableResult
    static func resolver(for hub: MusicHub) -> MusicChartResolver {
        let r = MusicCatalogRuntime.shared.charts
        guard boundHub != ObjectIdentifier(hub) else { return r }
        boundHub = ObjectIdentifier(hub)
        var d = MusicChartDependencies.standard()
        let own = d.verifyOwn
        d.gated = { [weak hub] in await MainActor.run { hub?.gated ?? true } }
        d.blacklisted = { [weak hub] t in await MainActor.run { hub?.library.isBlacklisted(t) ?? false } }
        d.online = { await MainActor.run { MusicNetwork.watch.isOnline } }
        d.backgroundAllowed = { await MainActor.run { MusicNetwork.watch.link != .cellular } }
        d.providesAudio = { [weak hub] id in await MainActor.run { hub?.registry.audio.contains { $0.id == id } ?? false } }
        let opens: @Sendable (MusicTrack) async -> Bool = { [weak hub] t in
            guard let hub else { return false }
            let quality = await MainActor.run { hub.library.settings.audioQuality }
            do { _ = try await MusicStreamResolver.withDeadline(7) { try await hub.resolver.resolve(t, quality: quality) }; return true } catch { return false }
        }
        d.verifyOwn = { t in
            if (t.directStreams ?? []).isEmpty { return await opens(t) }
            return await own(t)
        }
        d.verifyTwin = opens
        d.prewarm = { [weak hub] tracks in await MainActor.run { hub?.player.preResolve(tracks) } }
        r.configure(d)
        return r
    }

    static func session(hub: MusicHub, chartID: String, tracks: [MusicTrack] = []) -> MusicChartSession {
        resolver(for: hub).session(chartID: chartID, tracks: tracks)
    }

    /// The chart's own rows carry its name ("Playing from", "Back to"); rows confirmed after Play join the list as its own, never as "Add to queue" rows.
    static func playerHooks(_ hub: MusicHub, chartID: String? = nil) -> MusicChartPlayerHooks {
        let name = Localized.string("Chart")
        return MusicChartPlayerHooks(play: { tracks, i in hub.play(tracks, at: i, sourceName: name, sourceID: chartID) },
                                     enqueue: { hub.player.extendContext($0) },
                                     currentUID: { hub.player.current?.uid },
                                     playShuffled: { hub.playShuffled($0, sourceName: name, sourceID: chartID) },
                                     enqueueShuffled: { hub.player.extendContext($0, shuffled: true) })
    }
}

/// "<N> songs from this chart are not available right now" with a Show / Hide button. Nothing when every row is playable or still resolving.
struct MusicChartNote: View {
    let session: MusicChartSession

    var body: some View {
        let n = session.unavailableCount
        if n > 0 {
            HStack(spacing: MusicSpace.xs) {
                Image(systemName: "info.circle").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textTertiary).accessibilityHidden(true)
                Text(verbatim: Localized.plural(n, one: "%@ song is not available right now", other: "%@ songs are not available right now"))
                    .font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                Spacer(minLength: MusicSpace.sm)
                Button(session.showUnavailable ? Localized.string("Hide") : Localized.string("Show")) { session.showUnavailable.toggle() }
                    .musicButton(.tertiary, size: .compact, accentText: true)
                    .accessibilityLabel(session.showUnavailable ? "Hide the songs that are not available" : "Show the songs that are not available")
                    .atlas("control.music.chartShowUnavailable")
            }
            .accessibilityElement(children: .contain)
            .padding(.horizontal, MusicSpace.sm)
        }
    }
}

/// Play and Shuffle for a chart: only verified playable songs are queued, in chart order; later rows join as they are confirmed.
struct MusicChartPlayButtons: View {
    let hub: MusicHub
    let session: MusicChartSession

    var body: some View {
        Button { Task { await session.play(player: MusicChartBinding.playerHooks(hub, chartID: session.chartID)) } } label: { Label("Play", systemImage: "play.fill") }
            .musicButton(.hero, size: .large).disabled(session.entries.isEmpty).accessibilityLabel("Play the chart").atlas("control.music.chartPlay")
        Button {
            Task { await session.play(shuffle: true, player: MusicChartBinding.playerHooks(hub, chartID: session.chartID)) }
        } label: { Label("Shuffle", systemImage: "shuffle") }
            .musicButton(.secondary, size: .large).disabled(session.entries.isEmpty).accessibilityLabel("Shuffle the chart").atlas("control.music.chartShuffle")
    }
}

/// A chart's songs: the note, then the rows. Rows are drawn by the standard track list with chart hooks.
struct MusicChartList: View {
    let hub: MusicHub
    let session: MusicChartSession
    var numbered = true
    var hasMore = false
    var loadingMore = false
    var loadFailed = false
    var loadMore: (() -> Void)?
    var retry: (() -> Void)?
    var emptyMessage = Localized.string("There are no songs here.")

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            MusicChartNote(session: session)
            MusicTrackList(hub: hub, tracks: session.shownTracks, showsTools: false, numbered: numbered, canSort: false, showsAlbumByDefault: true,
                           hasMore: hasMore, loadingMore: loadingMore, loadFailed: loadFailed, loadMore: loadMore, retry: retry,
                           emptyMessage: session.isResolving ? Localized.string("Checking which songs can play…") : emptyMessage,
                           chartHooks: { hooks(for: $0) }, onRowVisible: { session.noteVisible(uid: $0.uid, $1) })
        }
        .onChange(of: hub.player.failedUIDs) { old, failed in
            for uid in failed.subtracting(old) { session.noteFailed(uid: uid) }
            for uid in old.subtracting(failed) { session.clearFailed(uid: uid) }
        }
    }

    private func hooks(for t: MusicTrack) -> MusicChartRowHooks? {
        guard let e = session.entry(forUID: t.uid) else { return nil }
        let uid = t.uid
        let choices = ([e.original] + e.alternates).map(MusicChartVersionChoice.init)
        let play: @MainActor () -> Void = { Task { await session.play(from: uid, player: MusicChartBinding.playerHooks(hub, chartID: session.chartID)) } }
        var chooser: (@MainActor (MusicTrack) -> Void)?
        if choices.count > 1 {
            chooser = { pick in
                guard session.chooseVersion(rowUID: uid, pick: pick) else { return }
                Task { await session.play(from: pick.uid, player: MusicChartBinding.playerHooks(hub, chartID: session.chartID)) }
            }
        }
        return MusicChartRowHooks(status: e.status, play: play, versions: choices, choose: chooser)
    }
}

/// Loading, error and loaded states of a chart playlist's pages; the session follows the list as pages arrive and stops when the page is left.
struct MusicChartTracks: View {
    let hub: MusicHub
    let list: MusicPagedList<MusicTrack>
    let session: MusicChartSession
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            switch list.state {
            case .idle, .loading: MusicLoadingView().frame(height: 160)
            case .failed(let m): MusicErrorView(message: m) { Task { await list.reload() } }.frame(height: 200)
            case .loaded:
                MusicChartList(hub: hub, session: session, hasMore: list.hasMore, loadingMore: list.loadingMore, loadFailed: list.loadMoreFailed,
                               loadMore: { Task { await list.loadMore() } }, retry: { Task { await list.loadMore() } })
            }
        }
        .task {
            await list.loadIfNeeded()
            session.update(tracks: list.items)
            session.setActive(phase == .active)
            session.start()
        }
        .onChange(of: list.items.count) { _, _ in session.update(tracks: list.items) }
        .onChange(of: phase) { _, p in session.setActive(p == .active) }
        .onDisappear { session.cancel() }
    }
}

/// The small things a chart row adds to a title line: a quiet spinner while it resolves and the note when the copy differs from the chart's row.
struct MusicChartRowAccessory: View {
    let status: MusicChartRowStatus

    var body: some View {
        switch status.phase {
        case .resolving:
            MusicLoadingIcon(size: MusicIconSize.tiny).accessibilityLabel("Checking this song")
        case .ready:
            if let note = status.note {
                Text(verbatim: note).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary).lineLimit(1)
            }
        case .unavailable:
            Image(systemName: "minus.circle").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textTertiary)
                .accessibilityLabel(status.reason ?? Localized.string("Not available right now"))
        }
    }
}

/// A plain list of songs on a page (a mood or genre section, a featured list) resolved to verified playable copies, rows in view first.
struct MusicChartSongs: View {
    let hub: MusicHub
    let tracks: [MusicTrack]
    let chartID: String
    var numbered = false
    @State private var session: MusicChartSession?
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            if let session { MusicChartList(hub: hub, session: session, numbered: numbered) }
            else { MusicTrackList(hub: hub, tracks: tracks, showsTools: false, numbered: numbered, canSort: false) }
        }
        .task(id: tracks.map(\.uid)) {
            let s = session ?? MusicChartBinding.session(hub: hub, chartID: chartID, tracks: tracks)
            s.update(tracks: tracks)
            s.setActive(phase == .active)
            session = s
            s.start()
        }
        .onChange(of: phase) { _, p in session?.setActive(p == .active) }
        .onDisappear { session?.cancel() }
    }
}
