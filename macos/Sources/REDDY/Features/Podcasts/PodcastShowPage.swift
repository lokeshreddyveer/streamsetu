import SwiftUI

/// What the show page lists: the episodes of a feed, sorted and filtered. Pure, so it is tested without a view.
enum PodcastEpisodeList {
    static func visible(_ episodes: [PodcastEpisode], newestFirst: Bool, query: String) -> [PodcastEpisode] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = q.isEmpty ? episodes : episodes.filter { $0.title.lowercased().contains(q) || $0.summary.lowercased().contains(q) }
        let sorted = filtered.sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
        return newestFirst ? sorted : sorted.reversed()
    }
    static func length(_ s: TimeInterval) -> String {
        let t = Int(s); let h = t / 3600, m = (t % 3600) / 60
        return h > 0 ? "\(h) h \(m) min" : "\(max(m, 1)) min"
    }
}

@MainActor @Observable
final class PodcastShowViewModel {
    let show: PodcastSubscription
    var feed: PodcastFeed?
    var failed = false
    var newestFirst = true
    var query = ""
    var following = false
    init(show: PodcastSubscription) { self.show = show }

    var episodes: [PodcastEpisode] { PodcastEpisodeList.visible(feed?.episodes ?? [], newestFirst: newestFirst, query: query) }

    func load(_ hub: PodcastsHub) async {
        following = hub.isFollowing(show); failed = false
        do {
            let f = try await hub.service.load(show.feedURL)
            feed = f
            hub.library.noteLatest(f.episodes.compactMap(\.published).max(), for: show.feedURL)
            if following { hub.library.markSeen(show.feedURL) }
        } catch { failed = true }
    }

    func toggleFollow(_ hub: PodcastsHub) {
        if following { hub.service.unsubscribe(show.feedURL); following = false; hub.reloadFollowing() }
        else { Task { if (try? await hub.service.subscribe(show.feedURL)) != nil { following = true; hub.reloadFollowing(); hub.library.markSeen(show.feedURL) } } }
    }
}

struct PodcastShowPage: View {
    let hub: PodcastsHub
    let show: PodcastSubscription
    @State private var model: PodcastShowViewModel
    @State private var expanded = false
    @FocusState private var focus: String?
    @Environment(\.reddyAccent) private var accent

    init(hub: PodcastsHub, show: PodcastSubscription) {
        self.hub = hub; self.show = show
        _model = State(initialValue: PodcastShowViewModel(show: show))
    }

    private var artwork: URL? { model.feed?.artwork ?? show.artwork }

    var body: some View {
        GeometryReader { g in
            let wide = g.size.width >= 940
            ZStack(alignment: .top) {
                backdrop
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Button { hub.back() } label: { Label("Back", systemImage: "chevron.left").font(Typography.bodyMedium) }
                            .buttonStyle(.plain).foregroundStyle(accent).keyboardShortcut(.cancelAction).atlas("screen.destination.podcasts")
                        if wide {
                            HStack(alignment: .top, spacing: 32) {
                                info(wide: true).frame(width: 320)
                                episodes.frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        } else {
                            info(wide: false)
                            episodes
                        }
                    }
                    .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 28)
                    .frame(maxWidth: wide ? 1240 : 900, alignment: .leading).frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
            }
        }
        .task { await model.load(hub) }
        .onKeyPress(.return) { if let e = focusedEpisode { play(e); return .handled }; return .ignored }
        .onKeyPress(.space) {
            if let c = hub.player.current, c.feedURL == show.feedURL, focusedEpisode == nil || focusedEpisode?.itemID == c.itemID { hub.player.toggle(); return .handled }
            if let e = focusedEpisode ?? model.episodes.first { play(e); return .handled }
            return .ignored
        }
    }

    private var focusedEpisode: PodcastEpisode? { focus.flatMap { id in model.episodes.first { $0.id == id } } }

    @ViewBuilder private var backdrop: some View {
        if artwork != nil { backdropImage }
    }

    private var backdropImage: some View {
        ArtworkImage(url: artwork?.absoluteString, kind: .poster, contentMode: .fill, symbol: "mic.fill")
            .frame(height: 380).frame(maxWidth: .infinity).clipped()
            .blur(radius: 70).saturation(1.3).opacity(0.38)
            .overlay(ColorTokens.background.opacity(0.35))          // the theme's own background keeps text readable over any artwork
            .mask(LinearGradient(colors: [ColorTokens.textPrimary, ColorTokens.textPrimary.opacity(0)], startPoint: .top, endPoint: .bottom))
            .allowsHitTesting(false).accessibilityHidden(true)
    }

    // MARK: show info

    private func info(wide: Bool) -> some View {
        let art = ArtworkImage(url: artwork?.absoluteString, kind: .poster, contentMode: .fill, symbol: "mic.fill")
            .frame(width: 200, height: 200).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: ColorTokens.background.opacity(0.7), radius: 18, y: 8)
        let text = VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: show.title).font(Typography.pageTitle).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            if !show.author.isEmpty { Text(verbatim: show.author).font(Typography.body).foregroundStyle(ColorTokens.textSecondary).lineLimit(2) }
            if let cats = model.feed?.categories, !cats.isEmpty {
                HStack(spacing: 6) { ForEach(cats.prefix(3), id: \.self) { c in Text(verbatim: c).font(Typography.caption).padding(.horizontal, 8).padding(.vertical, 3).background(ColorTokens.elevated, in: Capsule()).overlay(Capsule().strokeBorder(ColorTokens.line)) } }
            }
            if let s = model.feed?.summary, !s.isEmpty {
                let clean = PodcastText.display(s)
                Text(verbatim: clean).font(Typography.body).foregroundStyle(ColorTokens.textSecondary).lineLimit(expanded ? nil : 3).fixedSize(horizontal: false, vertical: true)
                if clean.count > 220 { Button(expanded ? "Less" : "More") { withAnimation(AnimationTokens.standard) { expanded.toggle() } }.buttonStyle(.plain).font(Typography.captionMedium).foregroundStyle(accent).atlas("control.podcasts.follow") }
            }
            HStack(spacing: 8) {
                Button { if let e = model.feed?.episodes.first { play(e) } } label: { Label("Play Latest", systemImage: "play.fill").font(Typography.bodyMedium) }
                    .buttonStyle(PrimaryButtonStyle()).disabled(model.feed == nil).atlas("control.podcasts.play")
                Button { model.toggleFollow(hub) } label: { Label(model.following ? "Following" : "Follow", systemImage: model.following ? "checkmark" : "plus").font(Typography.bodyMedium) }
                    .buttonStyle(SecondaryButtonStyle()).disabled(model.feed == nil && !model.following).atlas("control.podcasts.follow")
                if let link = model.feed?.link ?? Optional(show.feedURL) { ShareLink(item: link) { Image(systemName: "square.and.arrow.up") }.buttonStyle(SecondaryButtonStyle()).accessibilityLabel("Share").atlas("control.podcasts.follow") }
            }.padding(.top, 4)
        }
        return Group {
            if wide { VStack(alignment: .leading, spacing: 16) { art; text } }
            else { HStack(alignment: .top, spacing: 18) { art.frame(width: 160, height: 160).clipped(); text } }
        }
    }

    // MARK: episodes

    @ViewBuilder private var episodes: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let feed = model.feed {
                HStack(spacing: 10) {
                    Text("\(feed.episodes.count) episodes").font(Typography.heading).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(ColorTokens.textSecondary)
                        TextField("Search episodes", text: $model.query).textFieldStyle(.plain).font(Typography.body).frame(width: 150)
                        if !model.query.isEmpty { Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }.buttonStyle(.plain).foregroundStyle(ColorTokens.textSecondary).accessibilityLabel("Clear search").atlas("control.podcasts.sort") }
                    }
                    .padding(.horizontal, 10).frame(height: 28).podcastFieldStyle(focused: false, accent: accent)
                    Menu {
                        Button { model.newestFirst = true } label: { Label("Newest First", systemImage: model.newestFirst ? "checkmark" : "") }.atlas("control.podcasts.sort")
                        Button { model.newestFirst = false } label: { Label("Oldest First", systemImage: model.newestFirst ? "" : "checkmark") }.atlas("control.podcasts.sort")
                    } label: { Label(model.newestFirst ? "Newest" : "Oldest", systemImage: "arrow.up.arrow.down").font(Typography.caption) }
                        .menuStyle(.borderlessButton).foregroundStyle(ColorTokens.textSecondary).fixedSize().atlas("control.podcasts.sort")
                }
                let list = model.episodes
                if list.isEmpty { Text("No matching episodes.").font(Typography.body).foregroundStyle(ColorTokens.textSecondary).padding(.vertical, 20) }
                LazyVStack(spacing: 6) {
                    ForEach(list.prefix(300)) { e in PodcastEpisodeRow(hub: hub, show: show, feed: feed, episode: e).focusable().focused($focus, equals: e.id) }
                }
            } else if model.failed {
                EmptyStateView(symbol: "exclamationmark.triangle", title: "Couldn't load this show", message: "Check your connection and try again.")
                    .frame(height: 200).overlay(alignment: .bottom) { Button("Try Again") { Task { await model.load(hub) } }.buttonStyle(SecondaryButtonStyle()).atlas("control.podcasts.play") }
            } else {
                VStack(spacing: 8) { ForEach(0..<6, id: \.self) { _ in RoundedRectangle(cornerRadius: 12).fill(ColorTokens.elevated).frame(height: 78) } }.accessibilityHidden(true)
            }
        }
    }

    private func play(_ e: PodcastEpisode) { hub.play(e, of: show, showArtwork: artwork) }
}

struct PodcastEpisodeRow: View {
    let hub: PodcastsHub
    let show: PodcastSubscription
    let feed: PodcastFeed
    let episode: PodcastEpisode
    @Environment(\.reddyAccent) private var accent

    private var ref: PodcastEpisodeRef { PodcastEpisodeRef(episode, show: show, showArtwork: feed.artwork) }
    private var isCurrent: Bool { hub.player.current?.itemID == episode.itemID }
    private var playingNow: Bool { isCurrent && hub.player.isPlaying }

    var body: some View {
        let progress = hub.library.progress(episode.itemID)
        let played = progress?.played ?? false
        HStack(alignment: .top, spacing: 12) {
            ArtworkImage(url: (episode.artwork ?? feed.artwork ?? show.artwork)?.absoluteString, kind: .poster, contentMode: .fill, symbol: "mic.fill")
                .frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)).opacity(played ? 0.6 : 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: episode.title).font(Typography.bodyMedium).lineLimit(2).multilineTextAlignment(.leading).foregroundStyle(isCurrent ? accent : ColorTokens.textPrimary)
                HStack(spacing: 6) {
                    if played { Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(ColorTokens.success).accessibilityLabel("Played") }
                    Text(verbatim: [episode.published.map { $0.formatted(date: .abbreviated, time: .omitted) }, episode.duration.map(PodcastEpisodeList.length)].compactMap { $0 }.joined(separator: "  ·  "))
                        .font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                }
                let summary = episode.displaySummary
                if !summary.isEmpty { Text(verbatim: summary).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(2).multilineTextAlignment(.leading) }
                if let progress, !progress.played, progress.fraction > 0.01 { PodcastProgressBar(fraction: progress.fraction).frame(height: 3).padding(.top, 2) }
            }
            Spacer(minLength: 0)
            Button { if isCurrent { hub.player.toggle() } else { hub.play(episode, of: show, showArtwork: feed.artwork) } } label: {
                Image(systemName: playingNow ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 30)).foregroundStyle(accent)
            }
            .buttonStyle(.plain).accessibilityLabel(playingNow ? "Pause" : "Play").atlas("control.podcasts.play")
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading).surface(radius: 14).contentShape(Rectangle())
        .contextMenu {
            Button("Play") { hub.play(episode, of: show, showArtwork: feed.artwork) }.atlas("control.podcasts.play")
            Button("Play Next") { hub.library.playNext(ref) }.atlas("control.podcasts.queue")
            Button("Add to Up Next") { hub.library.addToQueue(ref) }.atlas("control.podcasts.queue")
            Divider()
            Button(played ? "Mark as Unplayed" : "Mark as Played") { hub.library.markPlayed(ref, !played) }.atlas("control.podcasts.queue")
        }
        .atlas("context.podcasts.episode")
    }
}
