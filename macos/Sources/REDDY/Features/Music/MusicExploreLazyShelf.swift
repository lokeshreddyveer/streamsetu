import SwiftUI

/// What a lazy Explore shelf needs: a stable id, a title, and how to load it. A definition is a few values; no view, task or request exists for it until its row is built, and a row is
/// built only when scrolled near (the rows sit in a lazy stack). This is how Explore can list dozens of shelves without fetching them together.
struct MusicExploreShelfDefinition: Identifiable, Sendable {
    var id: String
    var load: @Sendable (MusicHub) async -> (section: MusicBrowseSection, provenance: MusicChartProvenance?)?
}

/// Loads one definition when it appears, shows it as a shelf, and shows nothing (not a placeholder) when the source has nothing for it.
struct MusicExploreLazyShelf: View {
    let definition: MusicExploreShelfDefinition
    let hub: MusicHub
    /// Bumped by the page's Try again, so a shelf that was left empty by a bad moment asks again.
    var retries = 0
    @State private var section: MusicBrowseSection?
    @State private var provenance: MusicChartProvenance?
    @State private var resolved = false
    /// The language the row's title was made in (see the task below).
    @State private var shownLanguage = Localized.activeCode

    init(definition: MusicExploreShelfDefinition, hub: MusicHub, retries: Int = 0) {
        self.definition = definition; self.hub = hub; self.retries = retries
        let kept = MusicExploreMemory.shelf(definition.id)
        _section = State(initialValue: kept?.section)
        _provenance = State(initialValue: kept?.provenance)
        _resolved = State(initialValue: kept != nil || MusicExploreMemory.isKnownEmpty(definition.id, retries: retries))
    }

    var body: some View {
        Group {
            if let s = section, s.items.count >= 3 {
                MusicShelf(title: s.title) { ForEach(Array(s.items.prefix(16)), id: \.self) { MusicCard(result: $0, queue: songs(of: s), hub: hub) } }
                    .onSeeAll { MusicExploreSeeAll.shared.section = s }
                    .padding(.bottom, MusicSpace.xl)
            } else if resolved {
                Color.clear.frame(height: 0)
            } else {
                // Room for the shelf until its answer says there is none (so only the rows near the screen are built), drawn as quiet placeholder cards and not as blank space.
                MusicShelfSkeleton(count: 4, shimmer: false).frame(height: 220, alignment: .top).accessibilityHidden(true)
            }
        }
        .task(id: "\(definition.id)|\(hub.gated)|\(retries)|\(Localized.activeCode)") {
            // The app language changed under a row that is still on screen: its title was made in the old one, so it takes the new language's answer (or asks again).
            if shownLanguage != Localized.activeCode {
                shownLanguage = Localized.activeCode
                let kept = MusicExploreMemory.shelf(definition.id)
                section = kept?.section; provenance = kept?.provenance; resolved = kept != nil
            }
            if retries > 0, section == nil { resolved = false }
            guard section == nil else { return }
            // Asked a moment ago and had nothing: not asked again on every scroll back over the row.
            if MusicExploreMemory.isKnownEmpty(definition.id, retries: retries) { resolved = true; return }
            if hub.gated { resolved = true; return }   // nothing is asked while gated, and the row does not hold its blank space
            // A row that was scrolled past while it waited gives up its place at once (it does not hold the queue for the rows that are on screen now).
            guard await MusicExploreLoadGate.shared.enter() else { return }
            let r = Task.isCancelled ? nil : await definition.load(hub)
            await MusicExploreLoadGate.shared.leave()
            if Task.isCancelled { return }
            if let r { section = r.section; provenance = r.provenance; MusicExploreMemory.setShelf(r.section, provenance: r.provenance, id: definition.id) }
            else { MusicExploreMemory.setShelfEmpty(id: definition.id, retries: retries) }
            resolved = true
        }
    }

    private func songs(of s: MusicBrowseSection) -> [MusicTrack] { s.items.compactMap { if case .track(let t) = $0 { t } else { nil } } }

}

/// The shelves Explore lists, as data. Anything that can be listed is added here; nothing is fetched until its row is on screen.
@MainActor
enum MusicExploreRegistry {
    /// Top songs for a country: only the sources that publish a chart for it are asked.
    static func countryChart(_ region: String) -> MusicExploreShelfDefinition {
        MusicExploreShelfDefinition(id: "chart-" + region) { hub in
            for src in await hub.registry.discovery.compactMap({ $0 as? any MusicRegionalDiscovery }) {
                let id = (src as? any MusicProvider)?.info.id ?? ""
                // JioSaavn answers by the device's languages, so it is not used for a country chart: Explore is the same for everyone.
                guard id != JioSaavnDiscoveryProvider.id, MusicRegionalSources.followsRegion(providerID: id, region: region) else { continue }
                let answer = try? await MusicStreamResolver.withDeadline(7) { try await MusicDiscoveryFetch.regionalAnswer(src, providerID: id, region: region) }
                let secs = answer?.sections ?? []
                // The country's own Top songs list (not Most played, which is another list).
                if let found = secs.first(where: { $0.id.hasPrefix("itunes-songs-") }),
                   found.items.filter({ if case .track = $0 { true } else { false } }).count >= 6 {
                    // The chart's songs come from a catalogue-only source: keep the ones with a playable copy, as the main chart does (the whole list stays if matching runs out of time).
                    var s = found
                    if let p = src as? any MusicMetadataProvider {
                        let toResolve = found
                        let resolved = try? await MusicStreamResolver.withDeadline(MusicHomeLoaders.secondChance, { await MusicHomeLoaders.resolve([toResolve], from: p, strict: false) })
                        if let first = resolved?.first, !first.items.isEmpty { s = first }
                    }
                    let name = await hub.providerName(id)
                    return (MusicBrowseSection(id: "chart-" + region, title: Localized.string("Top songs in %@", MusicDiscoveryRegion.name(region)), items: s.items),
                            MusicChartProvenance(sourceName: name, region: MusicDiscoveryRegion.name(region), period: id == ITunesChartsDiscoveryProvider.id ? Localized.string("Daily") : "", fetchedAt: answer?.fetchedAt))
                }
            }
            return nil
        }
    }

    /// A language spotlight: what the sources that list music per language have for it (not a ranking, so no provenance popover).
    static func languageSpotlight(_ lang: MusicLanguage) -> MusicExploreShelfDefinition {
        MusicExploreShelfDefinition(id: "spotlight-" + lang.rawValue) { hub in
            for src in await hub.registry.discovery.compactMap({ $0 as? any MusicLanguageDiscovery }) {
                let id = (src as? any MusicProvider)?.info.id ?? ""
                let secs = (try? await MusicStreamResolver.withDeadline(7) { try await MusicDiscoveryFetch.languages(src, providerID: id, region: "", languages: [lang]) }) ?? []
                var seen = Set<String>()
                let items = secs.flatMap(\.items).filter { seen.insert(MusicFirstSeenLog.key($0)).inserted }   // a song in both Top and New is one card
                if items.count >= 3 {
                    var section = MusicBrowseSection(id: "spotlight-" + lang.rawValue, title: Localized.string("%@ music spotlight", lang.displayName), items: Array(items.prefix(24)))
                    // The songs come from a catalogue-only source: only the ones with a playable copy are shown (the whole list stays if matching runs out of time), as in the country charts.
                    if let p = src as? any MusicMetadataProvider {
                        let toResolve = section
                        let resolved = try? await MusicStreamResolver.withDeadline(MusicHomeLoaders.secondChance, { await MusicHomeLoaders.resolve([toResolve], from: p, strict: false) })
                        if let first = resolved?.first { if first.items.count >= 3 { section = first } else { continue } }
                    }
                    return (section, nil)
                }
            }
            // A language no source lists per language (Korean, Spanish...): the public playlists whose own title names it.
            let sources = await hub.registry.discovery
            guard let finder = sources.first(where: { $0.id == DeezerDiscoveryProvider.id }) as? any MusicLanguagePlaylistSearch else { return nil }
            let key = MusicFetch.key(DeezerDiscoveryProvider.id, "languagePlaylists", lang.rawValue, Localized.activeCode)
            let found = try? await MusicStreamResolver.withDeadline(7) {
                try await MusicFetch.shared.value(key, policy: MusicFetch.Kind.browse, keep: { !$0.items.isEmpty }) { () async throws -> MusicCachedSection in
                    let lists = try await finder.languagePlaylists(lang)
                    return MusicCachedSection(MusicBrowseSection(id: "spotlight-" + lang.rawValue, title: "", items: lists.map { .playlist($0) }))
                }
            }
            let lists = found?.value.section.items ?? []
            guard lists.count >= 3 else { return nil }
            return (MusicBrowseSection(id: "spotlight-" + lang.rawValue, title: Localized.string("%@ music spotlight", lang.displayName), items: Array(lists.prefix(24))), nil)
        }
    }

    /// The worldwide top albums or artists of one genre (Explore's catalogue shelves; a ranking, so it carries the chart info popover).
    static func genreTop(_ genreID: Int, kind: DeezerDiscoveryProvider.GenreChartKind) -> MusicExploreShelfDefinition {
        MusicExploreShelfDefinition(id: "genre-\(kind.rawValue)-\(genreID)") { hub in
            let sources = await hub.registry.discovery
            guard let dz = sources.first(where: { $0.id == DeezerDiscoveryProvider.id }) as? DeezerDiscoveryProvider else { return nil }
            let key = MusicFetch.key(DeezerDiscoveryProvider.id, "genreChart", kind.rawValue, String(genreID), Localized.activeCode)
            let answer = try? await MusicStreamResolver.withDeadline(7) {
                try await MusicFetch.shared.value(key, policy: MusicFetch.Kind.browse, keep: { !$0.items.isEmpty }) { () async throws -> MusicCachedSection in
                    let r = try await dz.genreChart(genreID, kind: kind)
                    let genre = Localized.string(r.name)
                    let title = kind == .albums ? Localized.string("Top %@ albums", genre) : Localized.string("Top %@ artists", genre)
                    return MusicCachedSection(MusicBrowseSection(id: "genre-\(kind.rawValue)-\(genreID)", title: title, items: r.items, scope: .global))
                }
            }
            guard let answer else { return nil }
            let section = answer.value.section
            let name = await hub.providerName(DeezerDiscoveryProvider.id)
            return (section, MusicChartProvenance(sourceName: name, region: Localized.string("Worldwide"), period: Localized.string("Current"), fetchedAt: answer.savedAt ?? Date()))
        }
    }

    static let countryCodes: [String] = ["us", "gb", "ca", "au", "nz", "ie", "in", "pk", "bd", "lk", "np", "ae", "sa", "qa", "kw", "eg", "tr",
                                         "fr", "de", "it", "es", "pt", "nl", "se", "no", "dk", "fi", "pl", "ng", "za", "gh", "ke",
                                         "br", "mx", "ar", "co", "cl", "jp", "kr", "cn", "tw", "id", "ph", "th", "vn", "my", "sg"]

    /// The languages with a spotlight: those a source can list music for (JioSaavn has lists for the Indian languages; others are added when a source offers them).
    static var spotlightLanguages: [MusicLanguage] { MusicLanguage.allCases.filter { $0.jioSaavnCode != nil || playlistSpotlightLanguages.contains($0) } }

    /// Languages with no per-language list from a source: they get a spotlight made of public playlists named for the language.
    static let playlistSpotlightLanguages: [MusicLanguage] = [.english, .spanish, .korean, .japanese, .arabic]

    /// Genre rankings of albums and of artists, the two kinds the country charts above do not cover.
    static var genreShelves: [MusicExploreShelfDefinition] {
        DeezerDiscoveryProvider.chartGenreIDs.flatMap { [genreTop($0, kind: .albums), genreTop($0, kind: .artists)] }
    }

    static func all(excluding region: String) -> [MusicExploreShelfDefinition] {
        countryCodes.filter { $0 != region.lowercased() }.map(countryChart) + spotlightLanguages.map(languageSpotlight) + genreShelves
    }
}

/// Genre families (Discogs' broad genres) with their styles: choose a family to see its styles; each style opens songs for it.
struct MusicGenreFamilies: View {
    /// A style name as search words: "Funk / Soul" and "Folk, World, & Country" become plain words a search understands. An apostrophe or a full stop inside a
    /// word is dropped ("Children's" becomes "Childrens", "P.Funk" becomes "PFunk"), and an ampersand inside a word stays ("R&B"); a lone one is a separator.
    static func words(_ name: String) -> String {
        let chars = Array(name)
        var out = ""
        for (i, c) in chars.enumerated() {
            if c.isLetter || c.isNumber { out.append(c); continue }
            let insideWord = i > 0 && i + 1 < chars.count && (chars[i - 1].isLetter || chars[i - 1].isNumber) && (chars[i + 1].isLetter || chars[i + 1].isNumber)
            if insideWord, c == "'" || c == "\u{2019}" || c == "." { continue }
            if insideWord, c == "&" { out.append(c); continue }
            out.append(" ")
        }
        return out.split(separator: " ").joined(separator: " ")
    }
    let open: (MusicCategory) -> Void
    @State private var chosen: MusicGenreFamily?
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            MusicSectionTitle(title: Localized.string("Genre families"))
            MusicChipFlow(spacing: MusicSpace.xs) {
                ForEach(MusicGenreTaxonomy.families.filter { $0.name != "Non-Music" }) { f in
                    MusicChip(title: Localized.string(f.name), selected: chosen == f) { chosen = chosen == f ? nil : f }
                }
            }
            if let f = chosen {
                MusicCategoryGrid(categories: MusicCategory.unique([MusicCategory(name: f.name, kind: .genre, target: .search(MusicGenreFamilies.words(f.name) + " music"))] + f.styles.map { MusicCategory(name: $0, kind: .genre, target: .search(MusicGenreFamilies.words($0) + " music")) }),
                                  owner: "explore.family." + f.name, open: open)
            }
        }
    }
}

/// At most six shelf loads run at once, so a fast scroll does not start dozens of requests together. The row asked for last (the one scrolled to just now) goes first, and a row
/// that leaves the screen while it waits is taken out of the line: the rows on screen are never stuck behind rows already scrolled past.
actor MusicExploreLoadGate {
    static let shared = MusicExploreLoadGate()
    static let limit = 6
    private var running = 0
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    /// True when the caller may load (and must call `leave()` after); false when it was cancelled while waiting (and must not).
    func enter() async -> Bool {
        if Task.isCancelled { return false }
        if running < Self.limit { running += 1; return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled { cont.resume(returning: false) } else { waiting.append((id, cont)) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let i = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: i).continuation.resume(returning: false)
    }

    func leave() {
        if let next = waiting.popLast() { next.continuation.resume(returning: true) } else { running = max(0, running - 1) }
    }
}
