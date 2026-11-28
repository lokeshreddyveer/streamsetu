import SwiftUI

// "Around this song" in the Related tab: the ways out of the playing song that are real for it. A song radio (started only by pressing it), the song's own page where the
// other versions and recordings are listed, and a link to each person and film the graph knows for it (music director, lyricist, film). Nothing here queues anything by itself.

struct MusicRelatedMoreSection: View {
    let track: MusicTrack
    let hub: MusicHub
    @State private var context: MusicTrackContext?
    @State private var contextUID: String?
    @State private var rt = MusicFillRuntime.shared

    private var canRadio: Bool { hub.registry.provider(id: track.providerID) is any MusicMetadataProvider }

    var body: some View {
        let _ = rt.revision
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            MusicRelatedHeading(title: Localized.string("Around this song"))
            if canRadio {
                Button { Task { await MusicQueueActions.startRadio(track, hub: hub) } } label: { rowLabel("dot.radiowaves.left.and.right", Localized.string("Start song radio")) }
                    .buttonStyle(.plain).hoverHighlight(radius: MusicCorner.control).accessibilityLabel(Localized.string("Start song radio")).atlas("control.music.relatedSongRadio")
            }
            if MusicGraphKeys.pagesOn, track.providerID != MusicStatsRules.localProviderID, track.isPodcast != true {
                Button { hub.open(MusicFillRuntime.songID(track)) } label: { rowLabel("square.stack.3d.up", Localized.string("Other versions and recordings")) }
                    .buttonStyle(.plain).hoverHighlight(radius: MusicCorner.control).accessibilityLabel(Localized.string("Other versions and recordings")).atlas("control.music.relatedVersions")
            }
            if let c = context, contextUID == track.uid, MusicGraphKeys.pagesOn, track.providerID != MusicStatsRules.localProviderID, track.isPodcast != true {
                if let m = c.musicDirector {
                    Button { hub.open(m.target, role: .musicDirector) } label: { rowLabel("music.quarternote.3", Localized.string("More from %@", m.name)) }
                        .buttonStyle(.plain).hoverHighlight(radius: MusicCorner.control).accessibilityLabel(Localized.string("More from %@", m.name)).atlas("control.music.relatedMoreFrom")
                }
                if let l = c.lyricist {
                    Button { hub.open(l.target, role: .lyricist) } label: { rowLabel("pencil.line", Localized.string("More from %@", l.name)) }
                        .buttonStyle(.plain).hoverHighlight(radius: MusicCorner.control).accessibilityLabel(Localized.string("More from %@", l.name)).atlas("control.music.relatedMoreFrom")
                }
                if let f = c.film {
                    Button { hub.open(f.target) } label: { rowLabel("film", Localized.string("More from the film %@", f.name)) }
                        .buttonStyle(.plain).hoverHighlight(radius: MusicCorner.control).accessibilityLabel(Localized.string("More from the film %@", f.name)).atlas("control.music.relatedMoreFrom")
                }
            }
        }
        .task(id: track.uid + "|\(rt.revision)") {
            let uid = track.uid
            if contextUID != uid { context = nil }
            let found = await rt.context(for: track)
            guard !Task.isCancelled, track.uid == uid else { return }
            context = found; contextUID = uid
        }
    }

    private func rowLabel(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: MusicSpace.xs) {
            Image(systemName: symbol).font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textSecondary).frame(width: 22).accessibilityHidden(true)
            Text(verbatim: title).font(Typography.body).foregroundStyle(ColorTokens.textPrimary).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textTertiary).accessibilityHidden(true)
        }
        .frame(minHeight: MusicTokens.hitTarget - 8).contentShape(Rectangle())
    }
}
