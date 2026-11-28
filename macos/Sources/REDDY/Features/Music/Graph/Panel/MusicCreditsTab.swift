import SwiftUI

// The Credits tab of the context panel: who made the song that is playing, grouped by role, with the film and album it belongs to and where each fact
// came from. The data and the layout rules are in `MusicSongCredits.swift` (pure, tested); this file only draws them.
// It reads the graph through the shared entity model (one load however many views ask), shows what it has as soon as it has it, and fills in as
// enrichment lands. Choosing a name opens that person on the role it was listed under; choosing the film or the album opens its page. Nothing here
// starts or changes playback.

struct MusicCreditsTab: View {
    let hub: MusicHub
    /// Tests and the snapshot harness set this to show one known song entity instead of finding it from the playing track.
    nonisolated(unsafe) static var entityOverride: MusicEntityID?
    @State private var lease: MusicEntityLease?
    @State private var trackUID: String?

    private var current: MusicTrack? { hub.player.current }

    var body: some View {
        let section = lease?.model.section(MusicSongCreditsLoader.sectionKey) ?? MusicEntitySection(key: MusicSongCreditsLoader.sectionKey)
        let layout = MusicCreditsLayout.make(items: section.items(MusicSongCreditItem.self), phase: section.phase)
        ScrollView {
            VStack(alignment: .leading, spacing: MusicSpace.lg) {
                if hub.gated {
                    Text("No more information for this song").musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    header(layout)
                    if let t = current { recording(t) }
                    if layout.hasPeople || layout.film != nil || layout.album != nil {
                        ForEach(layout.groups, id: \.group) { g in groupView(g) }
                        // Credits read from the album or the film are kept apart: they are not claimed as this song's own.
                        inheritedView(layout.fromAlbum, title: Localized.string("From the album"))
                        inheritedView(layout.fromFilm, title: Localized.string("From the film"))
                        links(layout)
                    } else if !layout.showsEmptyLine {
                        MusicRelatedRowsSkeleton(count: 3)
                    }
                    if layout.showsEmptyLine {
                        Text("Not credited in the sources we checked").musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, MusicSpace.md).padding(.vertical, MusicSpace.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .task(id: current?.uid) { await attach(current) }
        .onDisappear { lease?.release(); lease = nil; trackUID = nil }
    }

    // MARK: loading

    /// Finds (or mints, locally and without the network) the song's entity and holds the shared model for it. The model survives for a short while after
    /// the tab goes, so switching tabs or pages and coming back costs nothing.
    private func attach(_ t: MusicTrack?) async {
        guard let t, !hub.gated else { lease?.release(); lease = nil; trackUID = nil; return }
        if trackUID == t.uid, lease != nil { return }
        if trackUID != t.uid { lease?.release(); lease = nil; trackUID = nil }
        let runtime = MusicGraphRuntime.shared
        let id: MusicEntityID?
        if let o = Self.entityOverride { id = o }
        else if let known = try? await runtime.index.lookup(providerUID: t.uid, kind: .recording) { id = known }
        else { id = try? await runtime.index.mint(MusicGraphAdapters.plan(for: t)) }
        guard let id, !Task.isCancelled, current?.uid == t.uid else { return }
        lease?.release()
        let next = MusicEntityRuntime.shared.center.acquire(id)
        lease = next
        trackUID = t.uid
        next.model.load(MusicSongCreditsLoader())
    }

    // MARK: pieces

    @ViewBuilder private func header(_ layout: MusicCreditsLayout) -> some View {
        let title = layout.songTitle.isEmpty ? (current?.title ?? "") : layout.songTitle
        VStack(alignment: .leading, spacing: MusicSpace.xxs) {
            Text(verbatim: title).musicText(.section).foregroundStyle(ColorTokens.textPrimary).lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            if let v = layout.version {
                Text(Localized.string(Self.versionTitle(v))).musicText(.caption).foregroundStyle(ColorTokens.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The facts of the recording itself (length, release, ISRC, and the stream's own codec, bitrate and sample rate). Unknown ones are not listed.
    @ViewBuilder private func recording(_ t: MusicTrack) -> some View {
        let rows = MusicRecordingInfo.rows(for: t, technical: MusicQualityFacts.make(stream: hub.player.currentStream).rows)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                MusicRelatedHeading(title: Localized.string("Recording"))
                ForEach(rows) { r in
                    HStack(alignment: .firstTextBaseline, spacing: MusicSpace.sm) {
                        Text(verbatim: r.label).musicText(.caption).foregroundStyle(ColorTokens.textSecondary)
                        Spacer(minLength: MusicSpace.sm)
                        Text(verbatim: r.value).musicText(.body).foregroundStyle(ColorTokens.textPrimary).multilineTextAlignment(.trailing).textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    @ViewBuilder private func inheritedView(_ groups: [MusicCreditsLayout.Group], title: String) -> some View {
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                MusicRelatedHeading(title: title)
                ForEach(Array(groups.flatMap(\.rows).enumerated()), id: \.offset) { _, row in personRow(row) }
            }
        }
    }

    private func groupView(_ g: MusicCreditsLayout.Group) -> some View {
        VStack(alignment: .leading, spacing: MusicSpace.xxs) {
            MusicRelatedHeading(title: Localized.string(g.group.title))
            ForEach(g.rows, id: \.person) { row in personRow(row) }
        }
    }

    private func personRow(_ row: MusicCreditsLayout.Row) -> some View {
        let roles = row.roles.map { Localized.string(Self.roleTitle($0)) }.joined(separator: ", ")
        let tag: String? = row.level == .film ? Localized.string("Film credit") : (row.level == .album ? Localized.string("Album credit") : nil)
        let sub = [roles, row.hint, tag].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return Button { hub.open(row.person, role: row.linkRole) } label: {
            HStack(spacing: MusicSpace.xs) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: row.name).musicText(.body).foregroundStyle(ColorTokens.textPrimary).lineLimit(2)
                    Text(verbatim: sub).musicText(.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(2)
                }
                Spacer(minLength: MusicSpace.xs)
                Image(systemName: "chevron.right").musicText(.micro).foregroundStyle(ColorTokens.textTertiary).accessibilityHidden(true)
            }
            .frame(minHeight: MusicTokens.hitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).hoverHighlight()
        .accessibilityLabel(Text(verbatim: sub.isEmpty ? row.name : row.name + ", " + sub))
        .accessibilityHint(Text("Opens the person's page"))
        .musicTooltip(verbatim: row.name)
        .atlas("control.music.creditsPerson")
    }

    @ViewBuilder private func links(_ layout: MusicCreditsLayout) -> some View {
        if let f = layout.film {
            VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                MusicRelatedHeading(title: Localized.string("Film"))
                linkRow(f, atlas: "control.music.creditsFilm")
            }
        }
        if let a = layout.album {
            VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                MusicRelatedHeading(title: Localized.string("Album"))
                linkRow(a, atlas: "control.music.creditsAlbum")
            }
        }
    }

    private func linkRow(_ t: MusicCreditTarget, atlas id: String) -> some View {
        let sub = [t.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
        return Button { hub.open(t.id) } label: {
            HStack(spacing: MusicSpace.xs) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: t.name).musicText(.body).foregroundStyle(ColorTokens.textPrimary).lineLimit(2)
                    if !sub.isEmpty { Text(verbatim: sub).musicText(.caption).foregroundStyle(ColorTokens.textSecondary) }
                }
                Spacer(minLength: MusicSpace.xs)
                Image(systemName: "chevron.right").musicText(.micro).foregroundStyle(ColorTokens.textTertiary).accessibilityHidden(true)
            }
            .frame(minHeight: MusicTokens.hitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).hoverHighlight()
        .accessibilityLabel(Text(verbatim: sub.isEmpty ? t.name : t.name + ", " + sub))
        .musicTooltip(verbatim: t.name)
        .atlas(id)
        .atlasCovers("control.music.creditsFilm")
    }

    // MARK: words

    static func roleTitle(_ r: MusicRole) -> String {
        switch r {
        case .singer: "Singer"
        case .performer: "Performer"
        case .instrumentalist: "Instrumentalist"
        case .composer: "Composer"
        case .musicDirector: "Music director"
        case .arranger: "Arranger"
        case .lyricist: "Lyricist"
        case .writer: "Writer"
        case .actor: "Actor"
        case .director: "Director"
        case .producer: "Producer"
        case .screenwriter: "Screenwriter"
        case .cinematographer: "Cinematographer"
        case .editor: "Editor"
        case .featured: "Featured artist"
        case .conductor: "Conductor"
        case .remixer: "Remixer"
        case .label: "Label"
        }
    }

    static func versionTitle(_ v: MusicVersionKind) -> String {
        switch v {
        case .original: "Original"
        case .cover: "Cover"
        case .remix: "Remix"
        case .live: "Live"
        case .reRecording: "Re-recording"
        case .karaoke: "Karaoke"
        case .instrumental: "Instrumental"
        case .reprise: "Reprise"
        case .dub: "Dubbed"
        case .translatedLyrics: "Translated lyrics"
        case .otherLanguage: "Other language"
        case .translatedSoundtrack: "Translated soundtrack"
        case .acoustic: "Acoustic"
        case .unknown: "Version"
        }
    }
}
