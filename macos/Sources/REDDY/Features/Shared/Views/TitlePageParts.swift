import SwiftUI

// The pieces of the title page (movie and series), shared by iPhone, iPad and Mac so every page has one structure:
// hero, one metadata line, version picker, Play, action row, synopsis, genres, details, cast, other versions, extras, more like this.

enum TitlePage {
    /// A rating that may be shown: the shared junk rule (0, 10, 10.0, unknown are never shown).
    static func rating(_ raw: Double?) -> Double? { raw.flatMap { RatingRule.credible(String($0)) } }
    static func rating(text raw: String?) -> Double? { RatingRule.credible(raw) }

    /// "2006 · 2h 40m · U/A · FHD", every part only when known.
    static func metaParts(year: Int?, runtimeSeconds: Double?, age: String?, quality: String?) -> [String] {
        [year.map(String.init), runtimeSeconds.flatMap { $0 > 0 ? DurationFormatter.short($0) : nil }, age?.nilIfEmpty, quality?.nilIfEmpty].compactMap { $0 }
    }

    /// The first quality badge the title or folder names ("4K", "FHD", "HD").
    static func quality(_ texts: [String?]) -> String? { QualityBadges.from(texts).first { ["4K", "FHD", "HD"].contains($0) } }

    /// "English · FHD · 2 versions": the open version and how many there are. Nil when there is only one (the picker is then hidden).
    static func versionLine(_ versions: [OtherLanguages.Version]) -> String? {
        guard versions.count > 1 else { return nil }
        let cur = versions.first(where: \.isCurrent) ?? versions[0]
        return ([cur.title, cur.quality == cur.title ? nil : cur.quality].compactMap { $0 } + ["\(versions.count) versions"]).joined(separator: " · ")
    }

    /// The Play button's words: "Play", "Resume · 34m left", or for a series "Play S1 E3".
    static func playTitle(remainingSeconds: Double?, episode: (season: Int, number: Int)?) -> String {
        if let e = episode { return "Play S\(e.season) E\(e.number)" }
        if let r = remainingSeconds, r > 60 { return Localized.string("Resume · %@ left", DurationFormatter.short(r)) }
        return "Play"
    }
}

/// Which of the page's actions are shown and whether each is on.
struct TitleActions: Equatable {
    var isFavorite: Bool
    var isWatchLater: Bool
    var hasTrailer: Bool
    var canDownload: Bool
    var canShare: Bool

    /// The labels in order, as shown: Trailer only when one exists, Download only where supported.
    var labels: [String] { ["Favourite", "Watch Later"] + (hasTrailer ? ["Trailer"] : []) + (canDownload ? ["Download"] : []) + (canShare ? ["Share"] : []) }
}

// MARK: hero

/// The top picture: the backdrop; with none, a dimmed wash of the poster behind a sharp poster; with neither, the app's own tinted tile. Never a bare grey box.
struct TitleHeroImage: View {
    let backdrop: String?
    let poster: String?
    let title: String
    static func hasBackdrop(_ url: String?) -> Bool { !(url ?? "").isEmpty }

    var body: some View {
        // The base is always a designed picture (a wash of the poster, else the title's own tint), so a backdrop that is missing, still loading or fails never leaves an empty icon box.
        ZStack {
            base
            if Self.hasBackdrop(backdrop) { ArtworkImage(url: backdrop, kind: .backdrop, contentMode: .fill, alignment: .top, showsPlaceholder: false) }
            else if !(poster ?? "").isEmpty { sharpPoster }
        }
    }

    @ViewBuilder private var base: some View {
        if !(poster ?? "").isEmpty {
            ZStack {
                ArtworkImage(url: poster, kind: .poster, contentMode: .fill, alignment: .top, showsPlaceholder: false)
                Color.black.opacity(0.55)
            }
        } else {
            let h = ArtworkTile.Content(title: title, detail: nil).hue
            LinearGradient(colors: [Color(hue: h / 360, saturation: 0.30, brightness: 0.30), Color(hue: h / 360, saturation: 0.32, brightness: 0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var sharpPoster: some View {
        GeometryReader { g in
            let w = min(g.size.width * 0.3, 150)
            ArtworkImage(url: poster, kind: .poster, contentMode: .fill, showsPlaceholder: false)
                .frame(width: w, height: w * 1.5).background(Color.black.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                .position(x: g.size.width - w / 2 - 20, y: g.size.height * 0.46)
        }
    }

    /// Room the title leaves on the right for the sharp poster.
    static func titleTrailingInset(backdrop: String?, poster: String?, width: CGFloat) -> CGFloat {
        !hasBackdrop(backdrop) && !(poster ?? "").isEmpty ? min(width * 0.3, 150) + 36 : 0
    }
}

// MARK: version picker

@MainActor @Observable final class TitleVersionsModel {
    private(set) var versions: [OtherLanguages.Version] = []
    private(set) var loadedFor: String?

    func load(_ item: LibraryItem, container c: AppContainer?) async {
        if loadedFor != item.id { versions = [] }
        guard let c else { return }
        let service = OtherLanguagesService(catalog: c.catalog.recommendationView, preferredLanguage: c.settings.preferredAudioLanguage)
        let found = await Task.detached { service.versions(of: item) }.value
        if Task.isCancelled { return }
        versions = found.count > 1 ? found : []
        loadedFor = item.id
    }
}

/// One line above Play: "English · FHD · 2 versions ▾". Hidden with a single version. Choosing another switches the page to it.
struct VersionPickerLine: View {
    let versions: [OtherLanguages.Version]
    /// iPhone and iPad: a version is a navigation link (Back returns here). Mac: `choose` opens it.
    var useLinks = false
    let choose: (LibraryItem) -> Void

    var body: some View {
        if let line = TitlePage.versionLine(versions) {
            Menu {
                ForEach(versions) { v in
                    if v.isCurrent { Button {} label: { Label(v.versionText, systemImage: "checkmark") } }
                    else if useLinks { NavigationLink(value: v.item) { Text(v.versionText) }.atlas("control.title.version") }
                    else { Button { choose(v.item) } label: { Text(v.versionText) } }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "character.bubble").font(.footnote)
                    Text(line).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                    Spacer(minLength: 0)
                }.foregroundStyle(ColorTokens.textPrimary).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Version: \(line)").accessibilityHint("Choose another version").atlas("control.title.version")
        }
    }
}

extension OtherLanguages.Version {
    /// "Hindi · Dubbed · FHD": language and quality, never a playlist or profile name.
    var versionText: String { ([title, dubbed && caption != "Dubbed" ? "Dubbed" : nil, caption, quality == title ? nil : quality].compactMap { $0 }).reduce(into: [String]()) { if !$1.isEmpty, !$0.contains($1) { $0.append($1) } }.joined(separator: " · ") }
}

// MARK: Play and actions

struct TitlePlayButton: View {
    let title: String
    var enabled = true
    let action: () -> Void
    #if os(macOS)
    @Environment(\.reddyAccent) private var accent
    #else
    private var accent: Color { ColorTokens.accent }
    #endif

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "play.fill").font(.title3.weight(.bold)).foregroundStyle(ColorTokens.onAccent(accent))
                .frame(maxWidth: .infinity, minHeight: 52).padding(.vertical, 4)
                .background(Capsule().fill(accent)).contentShape(Capsule())
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.45)
        .accessibilitySortPriority(10)
        .accessibilityLabel(title).atlas("screen.title.movie")
    }
}

/// The icon with a small label, drawn the same for every action.
struct ActionLabel: View {
    let text: String
    let symbol: String
    var active = false
    @Environment(\.dynamicTypeSize) private var type
    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 22, weight: .regular)).frame(height: 26).symbolRenderingMode(.hierarchical)
            Text(text).font(.caption2.weight(.medium)).lineLimit(type.isAccessibilitySize ? 3 : 1).minimumScaleFactor(0.75).multilineTextAlignment(.center)
        }
        .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(ColorTokens.textPrimary))
        .frame(maxWidth: .infinity, minHeight: 56).contentShape(Rectangle())
    }
}

/// The action row: equal items directly under Play.
struct TitleActionRow<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.dynamicTypeSize) private var type
    var body: some View {
        // At accessibility sizes the items wrap onto two lines rather than clip.
        if type.isAccessibilitySize { LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) { content } }
        else { HStack(spacing: 4) { content } }
    }
}

// MARK: synopsis, genres

struct TitleSynopsis: View {
    let text: String
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.callout).lineSpacing(3).foregroundStyle(ColorTokens.textPrimary.opacity(0.88)).lineLimit(open ? nil : 3).fixedSize(horizontal: false, vertical: true)
            if text.count > 140 {
                Button(open ? "Less" : "More") { withAnimation(.smooth(duration: 0.25)) { open.toggle() } }.buttonStyle(.plain).font(.callout.weight(.semibold)).foregroundStyle(.tint).atlas("screen.title.movie")
            }
        }
    }
}

/// Quiet capsules; plain text, because the app has no genre filter to open.
struct GenreChips: View {
    let genres: [String]
    var body: some View {
        if !genres.isEmpty {
            FlowLayout(spacing: 8) {
                ForEach(genres, id: \.self) { g in
                    Text(g).font(.footnote).foregroundStyle(ColorTokens.textSecondary).padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().strokeBorder(ColorTokens.line, lineWidth: 1))
                }
            }
        }
    }
}

/// Lays children left to right and wraps to the next line; never runs off the edge.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.init(width: width, height: nil))
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing; row = max(row, size.height); maxX = max(maxX, x - spacing)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.init(width: bounds.width, height: nil))
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .init(size))
            x += size.width + spacing; row = max(row, size.height)
        }
    }
}

// MARK: details

/// One row of the details list.
struct DetailRow: Identifiable {
    enum Value { case text(String), people([PersonRoute]), folder(name: String, open: () -> Void) }
    let label: String
    let value: Value
    var id: String { label }
}

enum TitleDetails_ {
    /// The rows that have something to say, in order. `starring` names carry the route that opens the person screen.
    static func rows(directors: [String], isSeries: Bool, starring: [PersonRoute], country: String?, studio: String?, released: String?, folder: String?, openFolder: @escaping () -> Void) -> [DetailRow] {
        var out: [DetailRow] = []
        if !directors.isEmpty { out.append(DetailRow(label: isSeries ? "Created by" : "Directed by", value: .text(directors.prefix(3).joined(separator: ", ")))) }
        if !starring.isEmpty { out.append(DetailRow(label: "Starring", value: .people(Array(starring.prefix(6))))) }
        if let country = country?.nilIfEmpty { out.append(DetailRow(label: "Country", value: .text(country))) }
        if let studio = studio?.nilIfEmpty { out.append(DetailRow(label: "Studio", value: .text(studio))) }
        if let released = released?.nilIfEmpty { out.append(DetailRow(label: "Released", value: .text(released))) }
        if let folder = folder?.trimmingCharacters(in: .whitespaces).nilIfEmpty { out.append(DetailRow(label: "In folder", value: .folder(name: folder, open: openFolder))) }
        return out
    }
}

/// A two-column key/value list: it wraps, never runs off the edge, and stacks label over value at accessibility sizes.
struct DetailsBlock: View {
    let rows: [DetailRow]
    var useLinks = false
    var onPerson: (PersonRoute) -> Void = { _ in }
    @Environment(\.dynamicTypeSize) private var type
    @ScaledMetric(relativeTo: .subheadline) private var labelWidth: CGFloat = 104

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Details").font(.headline).accessibilityAddTraits(.isHeader)
                ForEach(rows) { r in
                    if type.isAccessibilitySize { VStack(alignment: .leading, spacing: 3) { label(r); value(r) } }
                    else { HStack(alignment: .firstTextBaseline, spacing: 12) { label(r).frame(width: labelWidth, alignment: .leading); value(r).frame(maxWidth: .infinity, alignment: .leading) } }
                    Divider().overlay(ColorTokens.line)
                }
            }
        }
    }

    private func label(_ r: DetailRow) -> some View { Text(r.label).font(.subheadline).foregroundStyle(ColorTokens.textSecondary) }

    @ViewBuilder private func value(_ r: DetailRow) -> some View {
        switch r.value {
        case .text(let t): Text(t).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        case .people(let people):
            FlowLayout(spacing: 6) {
                ForEach(Array(people.enumerated()), id: \.offset) { i, p in
                    Group {
                        #if os(iOS)
                        if useLinks { NavigationLink(value: p) { Text(p.name + (i < people.count - 1 ? "," : "")).font(.subheadline.weight(.medium)).foregroundStyle(.tint) }.buttonStyle(.plain).atlas("screen.person") }
                        else { personButton(p, comma: i < people.count - 1) }
                        #else
                        personButton(p, comma: i < people.count - 1)
                        #endif
                    }
                    .accessibilityLabel(p.name).accessibilityHint("Opens this person's films").accessibilityAddTraits(.isLink)
                }
            }
        case .folder(let name, let open):
            Button(action: open) {
                HStack(spacing: 4) { Text(name).font(.subheadline.weight(.medium)).lineLimit(3).multilineTextAlignment(.leading); Image(systemName: "chevron.right").font(.caption2) }.foregroundStyle(.tint)
            }.buttonStyle(.plain).accessibilityHint("Opens the folder").atlas("control.title.folderPath")
        }
    }

    private func personButton(_ p: PersonRoute, comma: Bool) -> some View {
        Button { onPerson(p) } label: { Text(p.name + (comma ? "," : "")).font(.subheadline.weight(.medium)).foregroundStyle(.tint) }.buttonStyle(.plain).atlas("screen.person")
    }
}

// MARK: facts for the Mac pages

/// What the provider and TMDB say about a title besides the library row: director, cast, country, age rating, runtime.
@MainActor @Observable final class TitleFactsModel {
    var extras: ProviderExtras?
    var tmdb: TitleDetails?

    func load(_ item: LibraryItem, container c: AppContainer?) async {
        guard let c else { return }
        extras = item.isSeries ? await c.details.extras(series: item.id) : await c.details.extras(movie: item.id)
        tmdb = await c.metadata.details(for: .init(id: item.id, isSeries: item.isSeries, title: item.title, year: item.year))
    }

    var makerNames: [String] { (extras?.directors.isEmpty == false ? extras?.directors : nil) ?? tmdb?.makers ?? [] }
    var castNames: [String] { (extras?.cast.isEmpty == false ? extras?.cast : nil) ?? tmdb?.cast.map(\.name) ?? [] }
    var age: String? { extras?.ageRating?.nilIfEmpty ?? tmdb?.certification?.nilIfEmpty }
    var runtimeSeconds: Double? { tmdb?.runtimeMinutes.flatMap { $0 > 0 ? Double($0) * 60 : nil } }
    var genres: [String] { tmdb?.genres ?? [] }
    var story: String? { tmdb?.overview?.nilIfEmpty }

    func starring(for item: LibraryItem) -> [PersonRoute] {
        if let c = tmdb?.cast, !c.isEmpty { return c.prefix(6).map { PersonRoute(name: $0.name, tmdbID: $0.tmdbID, fromTitle: item.title, fromYear: item.year) } }
        return castNames.prefix(6).map { PersonRoute(name: $0, fromTitle: item.title, fromYear: item.year) }
    }

    /// "15 Jul 2026" (DateText makes its formatters once: this runs for every refresh of the page).
    var releasedText: String? { DateText.short(iso: tmdb?.releaseDate) ?? tmdb?.year.map(String.init) }

    /// Meta line pieces for any item (library row first, then TMDB).
    func metaParts(for item: LibraryItem) -> [String] {
        TitlePage.metaParts(year: item.year ?? tmdb?.year, runtimeSeconds: (item.durationSeconds.flatMap { $0 > 0 ? $0 : nil }) ?? runtimeSeconds, age: age, quality: TitlePage.quality([item.title, item.categoryName, item.genre]))
    }

    func rating(for item: LibraryItem) -> Double? {
        let own: String? = { switch item { case .movie(let m): m.rating; case .series(let s): s.rating } }()
        return DisplayRating.value(tmdbAverage: tmdb?.rating, tmdbVotes: tmdb?.votes, provider: own)
    }

    func detailRows(for item: LibraryItem, openFolder: @escaping () -> Void) -> [DetailRow] {
        TitleDetails_.rows(directors: makerNames, isSeries: item.isSeries, starring: starring(for: item), country: extras?.country, studio: nil, released: releasedText ?? item.year.map(String.init), folder: item.categoryName, openFolder: openFolder)
    }
}

// MARK: next episode (from the metadata hub)

/// When a series' next episode airs, in words a person reads at a glance. Comes from the hub's ISO time stamp; past or unreadable stamps give nothing.
enum TitleNextEpisode: Equatable {
    case today, tomorrow, days(Int), on(String)

    static func from(stamp: String?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> TitleNextEpisode? {
        guard let stamp = stamp?.trimmingCharacters(in: .whitespaces), !stamp.isEmpty else { return nil }
        let plain = ISO8601DateFormatter(), fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let day = ISO8601DateFormatter(); day.formatOptions = [.withFullDate]
        guard let date = plain.date(from: stamp) ?? fractional.date(from: stamp) ?? day.date(from: String(stamp.prefix(10))) else { return nil }
        let n = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? -1
        switch n {
        case ..<0: return nil
        case 0: return .today
        case 1: return .tomorrow
        case 2...14: return .days(n)
        default:
            let f = DateFormatter(); f.locale = locale; f.calendar = calendar; f.timeZone = calendar.timeZone; f.setLocalizedDateFormatFromTemplate("d MMM")
            return .on(f.string(from: date))
        }
    }

    var text: LocalizedStringKey {
        switch self {
        case .today: "Next episode today"
        case .tomorrow: "Next episode tomorrow"
        case .days(let n): "Next episode in \(n) days"
        case .on(let d): "Next episode \(d)"
        }
    }
}

/// A quiet chip: "Next episode in 3 days". `onDark` for the hero picture.
struct NextEpisodeChip: View {
    let stamp: String?
    var onDark = false
    var body: some View {
        if let next = TitleNextEpisode.from(stamp: stamp) {
            Label { Text(next.text) } icon: { Image(systemName: "calendar") }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(onDark ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(onDark ? Color.white.opacity(0.14) : Color.gray.opacity(0.18)))
                .accessibilityElement(children: .combine)
        }
    }
}
