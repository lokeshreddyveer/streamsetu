import SwiftUI

/// The song page: one recording with its credits, lyrics, versions, neighbours and playback sources, built from the connected graph. It opens from a
/// provider row instantly (title, cover and Play come from provider data), and every other block fills in on its own as the graph and the metadata
/// sources deliver: nothing here waits for enrichment, nothing here starts playback, and a block with no data takes no room.
struct MusicSongPage: View {
    let entity: MusicEntityID
    let hub: MusicHub
    @State private var page: MusicSongPageModel

    init(entity: MusicEntityID, hub: MusicHub) {
        self.entity = entity; self.hub = hub
        _page = State(initialValue: MusicSongPageModel(hub: hub, entity: entity))
    }

    private var snapshotKey: String { page.model?.snapshot.map { $0.id.rawValue + "#" + String($0.updatedAt.timeIntervalSince1970) } ?? "none" }

    var body: some View {
        let model = page.model
        let data = page.data
        MusicPageScaffold(hub: hub, thumbs: MusicSongText.thumbs(model?.snapshot?.imageRef)) {
            MusicSongHeader(page: page, data: data)
            if model?.phase == .failed {
                MusicEmptyState(symbol: "music.note", title: Localized.string("This song is not available right now."),
                                message: Localized.string("Nothing is known about it yet. Go back and try again later."))
            } else if model?.snapshot != nil {
                // A plain VStack, not a lazy one: a page is a handful of sections whose heights change as their data lands, and a lazy stack only estimates the
                // height of what it has not drawn, then corrects it while the person scrolls, which moves the scroll offset (the page jumps back). Long lists
                // inside a section stay lazy.
                VStack(alignment: .leading, spacing: MusicSpace.xl) {
                    ForEach(data.visibleBlocks, id: \.rawValue) { block in
                        MusicSongBlockView(page: page, data: data, block: block)
                    }
                }
            }
        }
        .onAppear { page.open() }
        .onDisappear { page.close() }
        .task(id: snapshotKey) {
            await page.buildTrack()
            // The header needs the context and the singers at once; every other block loads when it comes into view.
            page.ensure(.context); page.ensure(.credits)
        }
        .atlasScreen("screen.music.song")
    }
}

// MARK: header (items 1 to 4 and the singers line)

struct MusicSongHeader: View {
    let page: MusicSongPageModel
    let data: MusicSongPageData

    var body: some View {
        let snap = page.model?.snapshot
        MusicPageHeader(title: snap?.name ?? Localized.string("Loading song"), kind: Localized.string("Song"), subtitle: facts(snap),
                        thumbs: MusicSongText.thumbs(snap?.imageRef), subject: snap.map { MusicArtworkSubject.derive($0) }, detail: AnyView(detail)) {
            actions
        }
    }

    private func facts(_ snap: MusicEntitySnapshot?) -> String {
        guard let snap else { return "" }
        let ctx = data.context
        var parts: [String] = []
        if let y = ctx?.year ?? snap.year { parts.append(String(y)) }
        if let d = snap.durationMs, d > 0 { parts.append(MusicTime.clock(ms: Int64(d))) }
        if let l = MusicSongText.languageName(ctx?.language) { parts.append(l) }
        if ctx?.explicit == true { parts.append(Localized.string("Explicit")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            versionLine
            singersLine
            albumAndFilmLine
        }
    }

    /// Item 2: the version badge, and a link to the original when an edge names it.
    @ViewBuilder private var versionLine: some View {
        if let v = data.context?.version, v.showsBadge, let badge = MusicSongVersioning.badgeKey(v.kind, inferred: v.isInferred) {
            MusicSongFlow {
                MusicStatusChip(title: Localized.string(badge), symbol: v.isInferred ? "questionmark.circle" : "arrow.triangle.2.circlepath", tone: .neutral)
                    .accessibilityLabel(Localized.string(badge))
                if let o = data.context?.original, let key = MusicSongVersioning.originalLineKey(v) {
                    Button { page.open(o.id) } label: { Text(verbatim: Localized.string(key, o.displayName)) }
                        .musicButton(.tertiary, size: .compact, accentText: true)
                        .accessibilityHint(Localized.string("Opens the original recording"))
                        .atlas("control.music.songPageOriginal")
                }
            }
        }
    }

    /// Item 5: the singers, one tap from their pages.
    @ViewBuilder private var singersLine: some View {
        let singers = MusicSongCredits.people(in: data.creditGroups, kinds: [.singers])
        if !singers.isEmpty {
            MusicSongFlow {
                ForEach(singers) { p in MusicSongPersonButton(page: page, person: p) }
            }
        }
    }

    /// Items 3 and 4: the album and the film, with the film marked when it is only inferred.
    @ViewBuilder private var albumAndFilmLine: some View {
        let ctx = data.context
        if ctx?.album != nil || ctx?.film != nil {
            MusicSongFlow {
                if let a = ctx?.album {
                    Button { page.open(a.id) } label: { Label(Localized.string("Album: %1$@", a.displayName), systemImage: "square.stack") }
                        .musicButton(.tertiary, size: .compact, accentText: true).atlas("control.music.songPageAlbum")
                }
                if let f = ctx?.film {
                    if f.isPlainText {
                        Label(Localized.string("From the film %1$@", f.film.displayName), systemImage: "film")
                            .musicText(.body).foregroundStyle(ColorTokens.textSecondary).padding(.horizontal, MusicSpace.xs)
                    } else {
                        Button { page.open(f.film.id) } label: { Label(Localized.string("Film: %1$@", f.film.displayName), systemImage: "film") }
                            .musicButton(.tertiary, size: .compact, accentText: true).atlas("control.music.songPageFilm")
                    }
                }
            }
        }
    }

    /// Item 1: Play (a tap, never automatic), queue and like.
    @ViewBuilder private var actions: some View {
        if page.track != nil {
            MusicButton(title: Localized.string("Play"), systemImage: "play.fill", variant: .primary, atlas: "control.music.songPagePlay") { page.play() }
            Menu {
                Button(Localized.string("Play Next"), systemImage: "text.insert") { page.playNext() }.atlas("control.music.songPagePlayNext")
                Button(Localized.string("Add to Queue"), systemImage: "text.append") { page.enqueue() }.atlas("control.music.songPageAddToQueue")
                if let t = page.track {
                    Button(Localized.string("Add to Playlist…"), systemImage: "music.note.list") { MusicChromeState.shared.addToPlaylist = [t] }.atlas("control.music.songMenusAddToPlaylist")
                    Button(Localized.string("Start Radio"), systemImage: "dot.radiowaves.left.and.right") { Task { await MusicQueueActions.startRadio(t, hub: page.hub) } }.atlas("control.music.songPageStartRadio")
                }
            } label: {
                Image(systemName: "ellipsis").font(MusicTokens.iconLarge)
            }
            .menuStyle(.button).menuIndicator(.hidden).musicButton(.glassIcon, size: .large).fixedSize()
            .accessibilityLabel(Localized.string("More ways to play")).musicTooltip(verbatim: Localized.string("More ways to play")).atlas("control.music.songPageMore")
            MusicIconButton(systemImage: page.isLiked ? "heart.fill" : "heart", label: page.isLiked ? Localized.string("Unlike") : Localized.string("Like"),
                            atlas: "control.music.songPageLike") { page.toggleLike() }
        } else if page.matchBase != nil {
            MusicButton(title: Localized.string("Find a playable copy"), systemImage: "magnifyingglass", variant: .secondary, atlas: "control.music.songPageFindCopy") { page.loadSources() }
            if page.sourcesSearched, page.sourcesState == .loaded {
                Text(Localized.string("No playable copy was found.")).musicText(.secondary).foregroundStyle(ColorTokens.textTertiary)
            }
        }
    }
}

/// A credited name that opens the person's page on the role it was credited for. Two people who share a name carry what tells them apart.
struct MusicSongPersonButton: View {
    let page: MusicSongPageModel
    let person: MusicSongCreditPerson

    var body: some View {
        Button { page.open(person.id, role: person.role) } label: {
            HStack(spacing: MusicSpace.xxs) {
                Text(verbatim: person.name)
                if let d = person.disambiguator { Text(verbatim: "(" + d + ")").foregroundStyle(ColorTokens.textTertiary) }
                if person.isBroaderCredit { Image(systemName: person.level == .film ? "film" : "square.stack").font(.system(size: MusicIconSize.small)).accessibilityHidden(true) }
            }
        }
        .musicButton(.tertiary, size: .compact, accentText: true)
        .accessibilityLabel(MusicSongText.accessibilityName(person))
        .help(Text(verbatim: MusicSongText.accessibilityName(person)))
        .atlas("control.music.songPagePerson")
    }
}

// MARK: shared text and layout helpers

enum MusicSongText {
    static func thumbs(_ url: String?) -> [MusicThumbnail] { url.map { [MusicThumbnail(url: $0, width: 600, height: 600)] } ?? [] }

    /// "Hindi" from "hin" or "hi"; nil for empty. A value the system cannot name is shown as given.
    static func languageName(_ code: String?) -> String? {
        guard let c = code?.trimmingCharacters(in: .whitespaces), !c.isEmpty else { return nil }
        return MusicLanguageNames.displayName(code: c) ?? c
    }

    /// The words of a related-song reason, with its subject in the placeholder.
    static func reason(_ r: MusicSongReason) -> String {
        if r.possibly { return Localized.string(r.key) }
        guard let s = r.subject, !s.isEmpty else { return r.kind == .sameWork ? Localized.string(r.key) : "" }
        return Localized.string(r.key, s)
    }

    /// "Kumar Sanu, born 1957, 1 of 2 with this name; film credit".
    static func accessibilityName(_ p: MusicSongCreditPerson) -> String {
        var s = p.name
        if let d = p.disambiguator { s += ", " + d }
        if p.homonymCount > 1 { s += ", " + Localized.string("%1$d of %2$d with this name", p.homonymIndex, p.homonymCount) }
        if p.level == .film { s += ", " + Localized.string("film credit") } else if p.level == .album { s += ", " + Localized.string("album credit") }
        return s
    }
}

/// Wraps its children onto as many rows as the width needs, with the same gap both ways.
struct MusicSongFlowLayout: Layout {
    var spacing: CGFloat = MusicSpace.xxs

    private func rows(_ subviews: Subviews, maxWidth: CGFloat) -> [[Int]] {
        var out: [[Int]] = [[]]
        var x: CGFloat = 0
        for (i, s) in subviews.enumerated() {
            let w = s.sizeThatFits(.unspecified).width
            if x > 0, x + w > maxWidth { out.append([]); x = 0 }
            out[out.count - 1].append(i); x += w + spacing
        }
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        let r = rows(subviews, maxWidth: maxW.isFinite ? maxW : .greatestFiniteMagnitude)
        var h: CGFloat = 0, w: CGFloat = 0
        for row in r {
            let sizes = row.map { subviews[$0].sizeThatFits(.unspecified) }
            h += (sizes.map(\.height).max() ?? 0) + spacing
            w = max(w, sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, sizes.count - 1)))
        }
        return CGSize(width: maxW.isFinite ? min(maxW, w) : w, height: max(0, h - spacing))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            let rowH = row.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0
            for i in row {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (rowH - s.height) / 2), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += rowH + spacing
        }
    }
}

struct MusicSongFlow<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { MusicSongFlowLayout { content } }
}
