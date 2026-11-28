import SwiftUI

// Every song surface links to the right typed pages: a context line under song rows (music director, film, cast), a "Go to" submenu in every song menu
// (song, albums, each artist, film, music director, singer, lyricist, actor), and a strip of chips on Now Playing. A name that has no page yet is plain
// text, never a dead link; "Various Artists" is never a link. Opening a page uses the hub's stack, so Back and Forward keep their page memory.

/// One line under a song's artists: "Shankar-Jaikishan · Awaara (1951) · Raj Kapoor, Nargis", each part a link. It always occupies one caption line, so a row
/// does not change height when the graph answers.
struct MusicTrackContextLine: View {
    let track: MusicTrack
    let hub: MusicHub
    /// The film the catalogue names, shown as plain text while the graph has not answered.
    var fallbackFilm: String?
    @State private var context: MusicTrackContext?
    @State private var rt = MusicFillRuntime.shared

    var body: some View {
        let _ = rt.revision
        HStack(spacing: 0) {
            if let c = context, !c.isEmpty { parts(c) } else { fallback }
        }
        .font(Typography.caption).lineLimit(1)
        .frame(height: MusicCardGeometry.subtitleLineHeight, alignment: .leading)
        .task(id: track.uid + "|\(rt.revision)") { context = await rt.context(for: track) }
    }

    @ViewBuilder private var fallback: some View {
        if let film = fallbackFilm, !film.isEmpty {
            Text(verbatim: Localized.string("From %@", film)).foregroundStyle(ColorTokens.textTertiary)
        } else if let a = track.album, !a.title.isEmpty, !MusicCompilationArtist.isCompilation(a.title) {
            Text(verbatim: a.title).foregroundStyle(ColorTokens.textTertiary)
        }
    }

    @ViewBuilder private func parts(_ c: MusicTrackContext) -> some View {
        let items = MusicTrackLinkItems.contextParts(c)
        ForEach(Array(items.enumerated()), id: \.offset) { i, p in
            if i > 0 { Text(verbatim: " · ").foregroundStyle(ColorTokens.textTertiary) }
            MusicInlineLink(title: p.title, font: Typography.caption, label: p.label) { hub.open(p.target, role: p.role) }
                .atlas("control.music.rowContextLink")
        }
    }
}

struct MusicTrackLinkItem: Hashable, Sendable {
    var title: String
    var label: String
    var target: MusicEntityID
    var role: MusicRole?
}

enum MusicTrackLinkItems {
    static func contextParts(_ c: MusicTrackContext) -> [MusicTrackLinkItem] {
        var out: [MusicTrackLinkItem] = []
        if let m = c.musicDirector { out.append(.init(title: m.name, label: Localized.string("Open music director %@", m.name), target: m.target, role: .musicDirector)) }
        if let f = c.film { out.append(.init(title: MusicFillLine.filmCaption(f.name, year: f.year), label: Localized.string("Open film %@", f.name), target: f.target, role: nil)) }
        for a in c.cast.prefix(2) { out.append(.init(title: a.name, label: Localized.string("Open actor %@", a.name), target: a.target, role: .actor)) }
        return out
    }

    /// The "Go to" items of a song: from the song's own credits (always) and the graph context (when read). Each is a typed page.
    static func goTo(track: MusicTrack, context: MusicTrackContext?) -> [(title: String, symbol: String, target: MusicEntityID, role: MusicRole?)] {
        var out: [(String, String, MusicEntityID, MusicRole?)] = []
        func add(_ t: String, _ s: String, _ id: MusicEntityID, _ r: MusicRole? = nil) { if !out.contains(where: { $0.2 == id && $0.3 == r }) { out.append((t, s, id, r)) } }
        add(Localized.string("Go to Song"), "music.note", MusicFillRuntime.songID(track))
        for a in context?.albums ?? [] { add(Localized.string("Go to %@", a.name), "square.stack", a.target) }
        if context?.albums.isEmpty ?? true, let al = track.album, !al.title.isEmpty, al.hasPage, !MusicCompilationArtist.isCompilation(al.title) {
            add(Localized.string("Go to %@", al.title), "square.stack", .provisional(kind: .release, providerUID: track.providerID + ":" + al.id))
        }
        for a in track.artists where MusicCompilationArtist.isUsableArtist(a) && !a.id.isEmpty {
            add(Localized.string("Go to %@", a.name), "person.crop.circle", .provisional(kind: .person, providerUID: track.providerID + ":" + a.id))
        }
        if let c = context {
            if let f = c.film { add(Localized.string("Go to film %@", f.name), "film", f.target) }
            if let m = c.musicDirector { add(Localized.string("Go to music director %@", m.name), "music.quarternote.3", m.target, .musicDirector) }
            for s in c.singers.prefix(2) { add(Localized.string("Go to singer %@", s.name), "mic", s.target, .singer) }
            if let l = c.lyricist { add(Localized.string("Go to lyricist %@", l.name), "pencil.line", l.target, .lyricist) }
            for a in c.cast.prefix(2) { add(Localized.string("Go to actor %@", a.name), "person.2", a.target, .actor) }
        }
        return out
    }
}

extension MusicTrackLinkItems {
    /// One chip under the Now Playing title: the bare name (no "Go to" text to cut off in other languages), its symbol, and the sentence for VoiceOver.
    struct StripChip: Hashable {
        var name: String
        var symbol: String
        var label: String
        var target: MusicEntityID
        var role: MusicRole?
    }

    /// Film, music director, singers, lyricist and cast. What the panel already links above the strip (the credited artists and the album) is left out, so nothing
    /// shows twice; a person who is also a credited artist is matched by their page, then by their name.
    static func strip(track: MusicTrack, context: MusicTrackContext) -> [StripChip] {
        var out: [StripChip] = []
        let linkedArtists = track.artists.filter { MusicCompilationArtist.isUsableArtist($0) }
        let linkedIDs = Set(linkedArtists.filter { !$0.id.isEmpty }.map { MusicEntityID.provisional(kind: .person, providerUID: track.providerID + ":" + $0.id) })
        let linkedNames = Set(linkedArtists.map { $0.name.lowercased() })
        func add(_ name: String, _ symbol: String, _ label: String, _ target: MusicEntityID, _ role: MusicRole?, person: Bool = false) {
            if person, linkedIDs.contains(target) || linkedNames.contains(name.lowercased()) { return }
            if out.contains(where: { $0.target == target && $0.role == role }) { return }
            out.append(StripChip(name: name, symbol: symbol, label: label, target: target, role: role))
        }
        if let f = context.film { add(f.name, "film", Localized.string("Go to film %@", f.name), f.target, nil) }
        if let m = context.musicDirector { add(m.name, "music.quarternote.3", Localized.string("Go to music director %@", m.name), m.target, .musicDirector, person: true) }
        for x in context.singers.prefix(2) { add(x.name, "mic", Localized.string("Go to singer %@", x.name), x.target, .singer, person: true) }
        if let l = context.lyricist { add(l.name, "pencil.line", Localized.string("Go to lyricist %@", l.name), l.target, .lyricist, person: true) }
        for a in context.cast.prefix(2) { add(a.name, "person.2", Localized.string("Go to actor %@", a.name), a.target, .actor, person: true) }
        return out
    }
}

/// The "Go to" submenu of a song menu.
struct MusicGoToMenu: View {
    let track: MusicTrack
    let hub: MusicHub

    var body: some View {
        let ctx = MusicFillRuntime.shared.cachedContext(for: track)
        Menu {
            ForEach(Array(MusicTrackLinkItems.goTo(track: track, context: ctx).enumerated()), id: \.offset) { _, item in
                Button(item.title, systemImage: item.symbol) { hub.open(item.target, role: item.role) }.atlas("control.music.songMenusGoToConnected")
            }
            if ctx == nil { Button(Localized.string("Find film and music director"), systemImage: "sparkle.magnifyingglass") { Task { _ = await MusicFillRuntime.shared.context(for: track) } }.atlas("control.music.songMenusFindCredits") }
        } label: { Label(Localized.string("Go to"), systemImage: "arrow.turn.down.right") }
        .atlas("control.music.songMenusGoToMenu")
        .onAppear { if ctx == nil { Task { _ = await MusicFillRuntime.shared.context(for: track) } } }
    }
}

/// Chips under the Now Playing title: film, music director, singers, lyricist, actors, album. Hidden while the graph knows nothing.
struct MusicTrackLinkStrip: View {
    let track: MusicTrack
    let hub: MusicHub
    @State private var context: MusicTrackContext?
    @State private var contextUID: String?
    @State private var rt = MusicFillRuntime.shared

    var body: some View {
        let _ = rt.revision
        // Connected pages are off, or the song is a file of the person's own or a podcast episode: no page to go to, so no chips (the same rule as the title link).
        let linksOn = MusicGraphKeys.pagesOn && track.providerID != MusicStatsRules.localProviderID && track.isPodcast != true
        let items = linksOn ? ((contextUID == track.uid ? context : nil).map { MusicTrackLinkItems.strip(track: track, context: $0) } ?? []) : []
        // A task on an empty view never runs, so a zero-height line always exists to hold it until there is something to show.
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 0)
            if !items.isEmpty {
                MusicChipFlow(spacing: MusicSpace.xs) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        Button { hub.open(item.target, role: item.role) } label: { Label { Text(verbatim: item.name) } icon: { Image(systemName: item.symbol) }.musicText(.caption).lineLimit(1) }
                            .musicButton(.tertiary, size: .compact).accessibilityLabel(item.label).atlas("control.music.nowPlayingLinkChip")
                    }
                }
            }
        }
        // A skip must not show the last song's film and director, and a slow lookup for an old song must not land on the new one.
        .task(id: track.uid + "|\(rt.revision)") {
            let uid = track.uid
            if contextUID != uid { context = nil }
            let found = await rt.context(for: track)
            guard !Task.isCancelled, track.uid == uid else { return }
            context = found; contextUID = uid
        }
    }
}


/// "Remove autoplay songs": takes the rows endless playback added out as one group; Undo (in the toast and Cmd-Z) brings the group back.
struct MusicAutoplayGroupButton: View {
    let hub: MusicHub
    var body: some View {
        Button { hub.player.clearAutoAdded() } label: {
            Label(Localized.plural(hub.player.autoAddedCount, one: "Remove %@ autoplay song", other: "Remove %@ autoplay songs"), systemImage: "infinity")
                .font(Typography.captionMedium).lineLimit(1)
        }
        .musicButton(.tertiary, size: .compact).accessibilityLabel(Localized.string("Remove the songs autoplay added")).atlas("control.music.queueRemoveAutoplayGroup")
    }
}
