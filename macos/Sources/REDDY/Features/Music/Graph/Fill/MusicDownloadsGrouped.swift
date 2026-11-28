import SwiftUI

// Downloads grouped by film or album, with real metadata: each group has a header (cover, film or album, music director, count) that opens the typed page,
// and the songs below with their context line. Songs from no album sit under "Singles".

struct MusicDownloadsGroupedView: View {
    let hub: MusicHub
    let items: [MusicDownloadItem]
    let offline: [MusicTrack]
    let row: (MusicDownloadItem, [MusicTrack]) -> AnyView
    @State private var contexts: [String: MusicTrackContext] = [:]
    @State private var rt = MusicFillRuntime.shared

    private func info(_ i: MusicDownloadItem) -> MusicDownloadRowInfo {
        let t = i.track
        return MusicDownloadRowInfo(uid: t.uid, title: t.title, artistLine: t.artistLine, providerID: t.providerID, albumID: t.album?.id, albumTitle: t.album?.title,
                                    thumbURL: MusicArtworkService.pickThumbnail(t.thumbnails, neededPixels: 120), context: contexts[t.uid])
    }

    var body: some View {
        let _ = rt.revision
        let byUID = Dictionary(items.map { ($0.track.uid, $0) }, uniquingKeysWith: { a, _ in a })
        let groups = MusicDownloadGrouping.group(items.map(info), singlesTitle: Localized.string("Singles"))
        LazyVStack(alignment: .leading, spacing: MusicSpace.lg) {
            ForEach(groups) { g in
                VStack(alignment: .leading, spacing: MusicSpace.xs) {
                    header(g)
                    ForEach(Array(g.rows.enumerated()), id: \.element.uid) { i, r in
                        if i > 0 { Divider().overlay(ColorTokens.line) }
                        if let item = byUID[r.uid] { row(item, offline) }
                    }
                }
            }
        }
        .task(id: items.map(\.track.uid).joined(separator: ",") + "|\(rt.revision)") {
            for i in items.prefix(200) where contexts[i.track.uid] == nil { contexts[i.track.uid] = await rt.context(for: i.track) }
        }
    }

    @ViewBuilder private func header(_ g: MusicDownloadGroup) -> some View {
        HStack(spacing: MusicSpace.sm) {
            MusicCoverImage(thumbs: g.thumbURL.map { [MusicThumbnail(url: $0)] } ?? [], size: MusicSpace.giant, corner: MusicCorner.control)
            VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                if let e = g.entity {
                    MusicInlineLink(title: g.title, font: Typography.title, label: Localized.string("Open %@", g.title)) { hub.open(e) }.atlas("control.music.downloadsGroupOpen")
                } else { Text(verbatim: g.title).font(Typography.title).foregroundStyle(ColorTokens.textPrimary) }
                Text(verbatim: MusicFillLine.join([g.kind == .film ? Localized.string("Film") : (g.kind == .album ? Localized.string("Album") : nil), g.subtitle.isEmpty ? nil : g.subtitle,
                                                   Localized.plural(g.rows.count, one: "%@ song", other: "%@ songs")]))
                    .musicText(.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, MusicSpace.xs)
        .accessibilityElement(children: .contain)
    }
}
