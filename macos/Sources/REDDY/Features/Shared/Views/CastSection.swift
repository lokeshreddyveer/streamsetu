import SwiftUI

/// A person in a title's cast, opened from the cast row. Used as a navigation value on iPhone and iPad.
struct PersonRoute: Hashable {
    let name: String
    /// TMDB's id for the person, when the cast row had it.
    var tmdbID: Int? = nil
    /// The title the person was tapped from (to tell two people of one name apart).
    var fromTitle: String? = nil
    var fromYear: Int? = nil
}

/// The titles of one person in the library: each title once (its other-language versions folded into it), restricted titles never listed.
enum PersonTitles {
    struct Entry: Identifiable, Sendable {
        let item: LibraryItem
        /// The other languages this title is also in ("Hindi", "Tamil").
        let otherLanguages: [String]
        var id: String { item.id }
    }

    @MainActor static func load(name: String, container c: AppContainer) async -> [Entry] {
        let preferred = OtherLanguages.preferredName(c.settings.preferredAudioLanguage)
        return await Task.detached { () -> [Entry] in
            var people = PeopleIndex(db: c.db); people.alwaysRestricted = true
            let hits = people.hits(term: name, kinds: [.movie, .series], sourceID: nil, limit: 300, exact: true)
            let view = c.catalog.recommendationView
            // One read per 300 ids and kind (not one per hit); the hits' order (best rated first) is kept.
            var byID: [String: LibraryItem] = [:]
            for kind in [ContentKind.movie, .series] {
                let ids = hits.filter { $0.kind == kind }.map(\.itemID)
                for chunk in stride(from: 0, to: ids.count, by: 300).map({ Array(ids[$0..<min($0 + 300, ids.count)]) }) {
                    var q = VODQuery(); q.ids = chunk; q.limit = nil
                    if kind == .series { for s in (try? view.series(q)) ?? [] { byID[s.id] = .series(s) } }
                    else { for m in (try? view.movies(q)) ?? [] { byID[m.id] = .movie(m) } }
                }
            }
            let items = hits.compactMap { byID[$0.itemID] }
            var lang: [String: String] = [:]
            let ids = items.map(\.id)
            for chunk in stride(from: 0, to: ids.count, by: 300).map({ Array(ids[$0..<min($0 + 300, ids.count)]) }) {
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                for r in (try? c.db.read { try $0.query("SELECT item_id, lang FROM content_identity WHERE item_id IN (\(marks))", chunk.map { $0 as (any SQLConvertible)? }) { ($0.string(0), $0.optString(1)) } }) ?? [] { if let l = r.1 { lang[r.0] = l } }
            }
            // One entry per title: the same identity key within a year of each other is the same title.
            var groups: [(key: String, year: Int?, members: [LibraryItem])] = []
            for it in items {
                let key = (it.isSeries ? "s|" : "m|") + IdentityKey.make(it.title)
                if let i = groups.firstIndex(where: { $0.key == key && (($0.year == nil || it.year == nil) || abs($0.year! - it.year!) <= 1) }) { groups[i].members.append(it) }
                else { groups.append((key, it.year, [it])) }
            }
            return groups.map { g in
                let best = g.members.first { preferred != nil && lang[$0.id] == preferred } ?? g.members[0]
                let others = Array(Set(g.members.filter { $0.id != best.id }.compactMap { lang[$0.id] }.filter { $0 != lang[best.id] })).sorted()
                return Entry(item: best, otherLanguages: others)
            }
        }.value
    }
}

/// What the cast row shows for one title. A load that was overtaken by another title (or cancelled) never shows its answer, and the row is emptied the moment the title changes.
@MainActor @Observable final class CastModel {
    private(set) var people: [TitleDetails.Person] = []
    private(set) var showPhotos = false
    private(set) var itemID: String?
    private var requested: String?

    func load(itemID id: String, _ loader: () async -> (people: [TitleDetails.Person], photos: Bool)) async {
        requested = id
        if itemID != id { people = []; showPhotos = false; itemID = nil }
        let r = await loader()
        guard !Task.isCancelled, requested == id else { return }
        people = r.people; showPhotos = r.photos; itemID = id
    }

    /// Photos from TMDB (their own key); with no cast from TMDB, the names the provider sent, as monograms in the same row.
    static func fetch(item: LibraryItem, container c: AppContainer) async -> (people: [TitleDetails.Person], photos: Bool) {
        let cand = MetadataMatchService.Candidate(id: item.id, isSeries: item.isSeries, title: item.title, year: item.year)
        var list = await c.metadata.details(for: cand)?.cast ?? []
        if list.isEmpty {
            let e = item.isSeries ? await c.details.extras(series: item.id) : await c.details.extras(movie: item.id)
            list = (e?.cast ?? []).prefix(12).map { TitleDetails.Person(name: $0, role: nil, photoPath: nil) }
        }
        return (list, c.metadata.hasKey)
    }
}

/// Round photos with name and role. Photos come from TMDB (the person's own key); without it, a plain monogram is drawn.
struct CastSection: View {
    let item: LibraryItem
    var useLinks = false
    var onPerson: (PersonRoute) -> Void = { _ in }
    @Environment(\.container) private var container
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .caption) private var photo: CGFloat = 72
    @State private var model = CastModel()

    private var cellWidth: CGFloat { photo + 12 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.people.isEmpty {
                TitleSectionHeader(title: "Cast")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(model.people) { p in
                            if useLinks { NavigationLink(value: route(p)) { cell(p) }.buttonStyle(.plain).atlas("screen.person") }
                            else { Button { onPerson(route(p)) } label: { cell(p) }.buttonStyle(.plain).atlas("screen.person") }
                        }
                    }.padding(.vertical, 2)
                }
            }
        }
        .task(id: item.id) {
            guard let c = container else { return }
            await model.load(itemID: item.id) { await CastModel.fetch(item: item, container: c) }
        }
        // Details that landed after the row was drawn (the title was matched a moment later): the same people stay on screen until the photos replace them, so nothing flickers.
        .onMetadataLanded(for: item.id) {
            guard let c = container else { return }
            Task { await model.load(itemID: item.id) { await CastModel.fetch(item: item, container: c) } }
        }
    }

    private func route(_ p: TitleDetails.Person) -> PersonRoute { PersonRoute(name: p.name, tmdbID: p.tmdbID, fromTitle: item.title, fromYear: item.year) }

    private func cell(_ p: TitleDetails.Person) -> some View {
        VStack(spacing: 5) {
            Group {
                if model.showPhotos, let url = p.photoURL { ArtworkImage(url: url, kind: .poster, contentMode: .fill, symbol: "person.fill") }
                else { Text(String(p.name.split(separator: " ").prefix(2).compactMap(\.first))).font(.title3.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gray.opacity(0.2)) }
            }
            .frame(width: photo, height: photo).clipShape(Circle())
            Text(p.name).font(.caption.weight(.semibold)).lineLimit(typeSize.isAccessibilitySize ? 3 : 2).multilineTextAlignment(.center).frame(width: cellWidth)
            if let r = p.role { Text(r).font(.caption2).foregroundStyle(.secondary).lineLimit(typeSize.isAccessibilitySize ? 3 : 2).multilineTextAlignment(.center).frame(width: cellWidth) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(p.name)\(p.role.map { ", as \($0)" } ?? "")")
        .accessibilityHint("Shows this person's films")
    }
}

/// One person's titles in the library. The caller draws each title and decides what opening it does.
struct PersonTitlesList<Card: View>: View {
    let name: String
    @ViewBuilder let card: (PersonTitles.Entry) -> Card
    @Environment(\.container) private var container
    @State private var entries: [PersonTitles.Entry]?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(name).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                if let entries {
                    if entries.isEmpty { Text("None of \(name)'s titles are in your library yet. They appear once their cast has been read.").foregroundStyle(.secondary) }
                    else {
                        Text(verbatim: Localized.plural(entries.count, one: "%@ title in your library", other: "%@ titles in your library")).font(.caption).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 160), spacing: 12, alignment: .top)], alignment: .leading, spacing: 14) {
                            ForEach(entries) { card($0) }
                        }
                    }
                } else { ProgressView().frame(maxWidth: .infinity).padding(.top, 40) }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: name) { if let c = container { entries = await PersonTitles.load(name: name, container: c) } }
    }
}
extension PersonRoute: Identifiable { var id: String { name + "#" + String(tmdbID ?? 0) } }
