import SwiftUI

/// A film as a poster card, with the "In your library" chip when the host app's bridge says the library holds it. The bridge answers only for films the
/// person may see (locked, hidden, adult and Kids restrictions are applied on the app's side); with nothing installed every film is simply "not in the library".
struct MusicPersonFilmCard: View {
    let hub: MusicHub
    let entry: MusicPersonEntry
    var width: CGFloat
    /// A line of plain data after the character: the credited role and the language (the artist's Films pill).
    var extraLine: String? = nil
    @State private var inLibrary = false

    private var subtitle: String? {
        let parts = [entry.detail.map { Localized.string("as %1$@", $0) }, extraLine].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        MusicGraphFilmCard(title: entry.name, year: entry.year, subtitle: subtitle, imageRef: MusicPersonImage.address(entry.imageRef),
                           reason: MusicPersonWording.reason(entry.reason), tag: inLibrary ? MusicGraphTag.custom(MusicPersonWording.inYourLibrary) : MusicGraphTag(status: entry.status ?? .verified, level: .film),
                           width: width, entity: entry.id) { hub.open(entry.id) }
            .task(id: entry.id) {
                let ids = (try? await MusicEntityRuntime.shared.store.graph.externalIDs(of: entry.id)) ?? []
                let series = entry.kind == .series
                let tmdb = ids.first { $0.scheme == (series ? .tmdbTV : .tmdbMovie) }.flatMap { Int($0.value) }
                let ref = MusicFilmWatchRef(tmdbID: tmdb, title: entry.name, year: entry.year, isSeries: series)
                inLibrary = MusicFilmWatchBridgeHost.shared.isInLibrary(ref)
            }
    }
}

/// One song of a list: play button, title (opens the song page), the line under it (singers, or the film), the year.
struct MusicPersonSongRow: View {
    let entry: MusicPersonEntry
    let hub: MusicHub
    let play: () -> Void
    /// The credit that is not the page's main one ("Featured", "Remixer"); nil when it is the main credit.
    var role: String? = nil

    var body: some View {
        HStack(spacing: MusicSpace.xs) {
            Button(action: play) {
                Image(systemName: "play.fill").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textSecondary)
                    .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
            }
            .buttonStyle(.plain).hoverHighlight().accessibilityLabel(MusicPersonWording.playLabel(entry.name)).atlas("control.music.personSongPlay")
            Button { hub.open(entry.id) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: entry.name).font(Typography.bodyMedium).foregroundStyle(ColorTokens.textPrimary).lineLimit(1)
                    if let line = subtitle { Text(verbatim: line).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).hoverHighlight().atlas("control.music.personSongOpen")
            if let y = entry.year { Text(verbatim: String(y)).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary).monospacedDigit() }
        }
        .frame(minHeight: MusicTokens.hitTarget)
        .accessibilityElement(children: .contain)
    }

    /// Singers, else the film ("From the film ..."), else nothing: only what the graph holds.
    private var subtitle: String? {
        let base: String?
        if let d = entry.detail, !d.isEmpty { base = entry.filmTitle.map { "\(d) · \($0)" } ?? d }
        else if let f = entry.filmTitle { base = MusicPersonWording.reason(entry.reason) ?? Localized.string("From the film %1$@", f) }
        else { base = nil }
        let line = [role, base].compactMap { $0 }.joined(separator: " · ")
        return line.isEmpty ? nil : line
    }
}
