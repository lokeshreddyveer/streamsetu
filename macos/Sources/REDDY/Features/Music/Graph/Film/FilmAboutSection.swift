import SwiftUI
import AppKit

/// The About destination of a film: the whole synopsis, the facts the film's source states (release date, runtime, certification with its country, rating with its vote count, genres,
/// languages, industry, original title, other names) and a link to the official trailer. Every row is shown only when the source stated it; nothing here is guessed.
struct MusicFilmAboutSection: View {
    let model: MusicFilmGraphModel
    let hub: MusicHub
    @ScaledMetric(relativeTo: .subheadline) private var labelWidth: CGFloat = 130
    @State private var extraRows: [(String, String)] = []

    var body: some View {
        let o = model.overview
        let rows = Self.rows(overview: o, entity: model.entity?.snapshot, isSeries: model.isSeries) + extraRows
        VStack(alignment: .leading, spacing: MusicSpace.lg) {
            if let text = o?.synopsis ?? o?.description, !text.isEmpty {
                VStack(alignment: .leading, spacing: MusicSpace.xs) {
                    Text(verbatim: Localized.string("Story")).font(Typography.title).accessibilityAddTraits(.isHeader)
                    Text(verbatim: text).musicText(.body).foregroundStyle(ColorTokens.textSecondary).frame(maxWidth: 640, alignment: .leading)
                }
            }
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                        if i > 0 { Divider().overlay(ColorTokens.line) }
                        HStack(alignment: .firstTextBaseline, spacing: MusicSpace.md) {
                            Text(verbatim: r.0).foregroundStyle(ColorTokens.textSecondary).frame(width: labelWidth, alignment: .leading)
                            Text(verbatim: r.1).foregroundStyle(ColorTokens.textPrimary).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }
                        .musicText(.body).padding(.vertical, MusicSpace.xs)
                    }
                }
                .padding(MusicSpace.lg).frame(maxWidth: 640, alignment: .leading)
                .background(ColorTokens.surface, in: RoundedRectangle(cornerRadius: MusicCorner.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: MusicCorner.card, style: .continuous).strokeBorder(ColorTokens.line, lineWidth: 0.75))
            }
            if let key = o?.trailerKey, let url = URL(string: "https://www.youtube.com/watch?v=" + key) {
                Button { NSWorkspace.shared.open(url) } label: { Label(Localized.string("Watch the trailer"), systemImage: "play.rectangle") }
                    .musicButton(.secondary, size: .regular).atlas("control.music.filmTrailer")
            }
            if rows.isEmpty && (o?.synopsis ?? o?.description) == nil {
                Text(verbatim: { switch model.section(MusicFilmSectionKey.overview).phase {
                case .idle, .loading, .partial: Localized.string("Loading details...")
                case .failed: Localized.string("The details could not be loaded.")
                default: Localized.string("No more details are available for this film.") } }())
                    .musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
            }
        }
        .task(id: (model.entity?.id.rawValue ?? "") + "|" + String(model.dubbedAlbums.count)) { await loadExtras() }
    }

    /// The other names sit on the entity's own rows (not in the snapshot), so they are read from the graph once the page knows the film.
    private func loadExtras() async {
        guard let id = model.entity?.id else { return }
        let graph = MusicEntityRuntime.shared.center.store.graph
        let aliases = (try? await graph.aliases(of: id)) ?? []
        if Task.isCancelled { return }
        extraRows = MusicFilmIdentifiers.rows(aliases: aliases, title: model.entity?.snapshot?.name ?? "", dubLanguages: model.dubbedAlbums.map(\.dubLanguage))
    }

    /// The rows, as pure data (label, value) so a test can hold them: a row exists only for a fact that is present.
    static func rows(overview o: MusicFilmOverview?, entity s: MusicEntitySnapshot?, isSeries: Bool) -> [(String, String)] {
        var out: [(String, String)] = []
        if let t = o?.originalTitle { out.append((Localized.string("Original title"), t)) }
        if let d = o?.releaseDate { out.append((Localized.string("Released"), displayDate(d))) } else if let y = o?.year ?? s?.year { out.append((Localized.string("Released"), String(y))) }
        if let m = o?.runtimeMinutes { out.append((Localized.string("Runtime"), runtime(m))) }
        if let l = o?.languages, !l.isEmpty { out.append((Localized.string("Language"), MusicFilmWording.joined(l))) }
        if !isSeries, let ind = MusicFilmIndustry.classify(language: s?.lang ?? o?.languages.first, country: s?.country) { out.append((Localized.string("Industry"), ind.title)) }
        if let g = o?.genres, !g.isEmpty { out.append((Localized.string("Genres"), MusicFilmWording.joined(g))) }
        if let c = o?.certification { out.append((Localized.string("Certificate"), o?.certificationRegion.map { "\(c) (\($0))" } ?? c)) }
        if let r = o?.rating { out.append((Localized.string("Rating"), o?.ratingVotes.map { Localized.string("%1$@ out of 10 from %2$@ votes", r, String($0)) } ?? r)) }
        if let n = o?.seasons { out.append((Localized.string("Seasons"), String(n))) }
        // The facts of the same TMDB reply. Each row exists only when the reply held it (a budget or box office of 0 is TMDB's "unknown" and is never shown).
        if let st = o?.status { out.append((Localized.string("Status"), MusicFilmWording.statusTitle(st))) }
        if let c = o?.companies, !c.isEmpty { out.append((Localized.string("Production companies"), MusicFilmWording.joined(c))) }
        if let c = o?.productionCountries, !c.isEmpty { out.append((Localized.string("Production countries"), MusicFilmWording.joined(c))) }
        if let l = o?.spokenLanguages, !l.isEmpty { out.append((Localized.string("Spoken languages"), MusicFilmWording.joined(l))) }
        if let b = o?.budget, b > 0 { out.append((Localized.string("Budget"), MusicFilmWording.money(b))) }
        if let r = o?.revenue, r > 0 { out.append((Localized.string("Box office"), MusicFilmWording.money(r))) }
        return out
    }

    /// "2023-08-10" in the reader's own date style; a value that is not a full date is shown as it came.
    nonisolated static func displayDate(_ iso: String) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(secondsFromGMT: 0)
        guard let d = f.date(from: iso) else { return iso }
        // The date was read at midnight UTC, so it is written in UTC too: in the local zone west of Greenwich it would show the day before.
        let style = Date.FormatStyle(locale: Locale(identifier: Localized.activeCode), timeZone: TimeZone(secondsFromGMT: 0) ?? .gmt).day().month(.wide).year()
        return d.formatted(style)
    }

    static func runtime(_ minutes: Int) -> String {
        minutes >= 60 ? Localized.string("%1$@ h %2$@ min", String(minutes / 60), String(minutes % 60)) : Localized.string("%1$@ min", String(minutes))
    }
}
