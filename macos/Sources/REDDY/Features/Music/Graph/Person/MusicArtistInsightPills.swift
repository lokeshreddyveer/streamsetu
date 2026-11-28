import SwiftUI

/// The Collaborators pill: the people of the existing collaboration sections, grouped by the role they were credited in, with the network sheet and, for a
/// collaborator whose role fits the Combine sheet (singer, composer, lyricist), "Combine" to find the songs the two made together.
struct MusicArtistCollaboratorsView: View {
    let hub: MusicHub
    let catalog: MusicArtistCatalog
    let person: MusicEntityID
    let name: String
    var showNetwork: Bool = true
    let openNetwork: () -> Void
    @State private var preset: MusicCombinePreset?
    @Environment(\.musicLayoutClass) private var layoutClass

    private struct CollabGroup: Identifiable { var title: String; var entries: [MusicPersonEntry]; var id: String { title } }

    private var groups: [CollabGroup] {
        let fallback = Localized.string("Collaborators")
        let by = Dictionary(grouping: catalog.collaborators) { MusicPersonWording.roleCaption($0.roles) ?? fallback }
        return by.map { CollabGroup(title: $0.key, entries: $0.value) }
            .sorted { $0.entries.count != $1.entries.count ? $0.entries.count > $1.entries.count : $0.title < $1.title }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            HStack {
                MusicSectionTitle(title: Localized.string("Collaborators"))
                Spacer()
                if showNetwork {
                    Button(action: openNetwork) { Label(Localized.string("Collaborator network"), systemImage: "point.3.connected.trianglepath.dotted") }
                        .musicButton(.secondary, size: .compact).atlas("control.music.networkOpenFromPerson")
                }
            }
            ForEach(groups) { g in
                VStack(alignment: .leading, spacing: MusicSpace.xs) {
                    Text(verbatim: g.title).font(Typography.bodyMedium).foregroundStyle(ColorTokens.textSecondary)
                    MusicCardGrid { ForEach(g.entries.prefix(60)) { e in cell(e) } }
                }
            }
        }
        .sheet(item: $preset) { p in MusicCombineSheet(hub: hub, close: { preset = nil }, initialPicks: p) }
    }

    private func cell(_ e: MusicPersonEntry) -> some View {
        let p = MusicCombinePreset.make(person: person, personName: name, view: catalog.view, other: e)
        return VStack(alignment: .leading, spacing: MusicSpace.xxs) {
            MusicGraphPersonCard(name: e.name, caption: MusicPersonWording.roleCaption(e.roles), imageRef: MusicPersonImage.address(e.imageRef), reason: MusicPersonWording.reason(e.reason),
                                 width: MusicGraphCardWidth.width(for: layoutClass), entity: e.id) { hub.open(e.id, role: e.openRole) }
            if p.isPair {
                Button(Localized.string("Combine")) { preset = p }
                    .musicButton(.tertiary, size: .compact).accessibilityLabel(Localized.string("Combine %1$@ and %2$@", name, e.name)).atlas("control.music.artistCombine")
            }
        }
    }
}

/// The Timeline pill: one row per year with what came out, oldest first, grouped by decade. Pressing a year scopes the Songs, Albums and Films lists to it.
struct MusicArtistTimelineView: View {
    let hub: MusicHub
    let header: MusicPersonHeaderData
    let catalog: MusicArtistCatalog
    let state: MusicArtistPageState
    @State private var awards: [MusicPersonAward] = []
    @State private var activeFrom: Int?
    /// The lookup reruns when the profile brings an id a restored pill did not have yet.
    private var lookupKey: String { "\(header.id)|\(header.wikidataID ?? "")|\(header.tmdbPersonID ?? "")" }

    var body: some View {
        let entries = MusicArtistTimeline.build(catalog)
        let decades = Dictionary(grouping: entries, by: \.decade).keys.sorted()
        let milestones = MusicArtistMilestones.build(catalog: catalog, awards: awards, activeFrom: activeFrom)
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            MusicSectionTitle(title: Localized.string("Career timeline"))
            if !milestones.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Localized.string("Milestones")).font(Typography.title).accessibilityAddTraits(.isHeader).padding(.bottom, MusicSpace.xxs)
                    ForEach(milestones) { milestone($0) }
                    Text(Localized.string("Earliest means the earliest Music has found, not necessarily the first ever.")).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary).padding(.top, MusicSpace.xxs)
                }
            }
            Text(Localized.string("Press a year to see only that year's songs, albums and films.")).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
            ForEach(decades, id: \.self) { d in
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: MusicPersonWording.filterDecade(d)).font(Typography.bodyMedium).foregroundStyle(ColorTokens.textSecondary).padding(.bottom, MusicSpace.xxs)
                    LazyVStack(alignment: .leading, spacing: 0) { ForEach(entries.filter { $0.decade == d }) { row($0) } }
                }
            }
        }
        .task(id: lookupKey) { await loadMilestoneData() }
    }

    @ViewBuilder private func milestone(_ m: MusicArtistMilestone) -> some View {
        let content = HStack(alignment: .firstTextBaseline, spacing: MusicSpace.sm) {
            Text(verbatim: String(m.year)).font(Typography.bodyMedium).monospacedDigit().foregroundStyle(ColorTokens.textPrimary).frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: MusicArtistWording.milestoneTitle(m)).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                if !m.title.isEmpty { Text(verbatim: m.title).font(Typography.bodyMedium).foregroundStyle(ColorTokens.textPrimary).lineLimit(2) }
            }
            Spacer()
        }
        .frame(minHeight: MusicTokens.hitTarget).contentShape(Rectangle())
        if let id = m.entity {
            Button { hub.open(id) } label: { content }.buttonStyle(.plain).hoverHighlight().atlas("control.music.artistMilestone")
        } else { content }
    }

    private func loadMilestoneData() async {
        guard let transport = MusicEntityArtwork.shared.transportIfAllowed() else { return }
        var found = header.wikidataID
        if found?.isEmpty ?? true {
            // No stored link: the same name lookup the About pill makes (cached by the loader), so the Timeline gets the same person.
            let lookup = MusicPersonWikiInfoLoader.Lookup(name: header.names.display, isGroup: header.isGroup, roleWords: MusicPersonWikiRules.roleWords(forView: catalog.view.rawValue))
            let info = await MusicPersonWikiInfoLoader.shared.info(qid: header.wikidataID, tmdbID: header.tmdbPersonID, sitelinks: header.sitelinks, readingLanguages: MusicPersonNames.readerLanguages,
                                                                  transport: transport, tmdb: MusicEntityArtwork.shared.tmdbFetch, lookup: lookup)
            found = info?.qid
        }
        guard let qid = found, !qid.isEmpty, !Task.isCancelled else { return }
        async let loadedFacts = MusicPersonFactsLoader.shared.facts(qid: qid, readingLanguages: MusicPersonNames.readerLanguages, transport: transport)
        let list = await MusicPersonAwardsLoader.shared.awards(qid: qid, readingLanguages: MusicPersonNames.readerLanguages, transport: transport)
        if !Task.isCancelled { awards = list }
        let f = await loadedFacts
        if !Task.isCancelled { activeFrom = f?.activeFrom }
    }

    private func row(_ e: MusicArtistTimelineEntry) -> some View {
        var parts: [String] = []
        if e.albums > 0 { parts.append(MusicArtistWording.count(albums: e.albums)) }
        if e.films > 0 { parts.append(MusicArtistWording.count(films: e.films)) }
        if e.songs > 0 { parts.append(MusicArtistWording.count(songs: e.songs)) }
        return Button { state.year = e.year; state.pill = MusicArtistTimeline.target(e) } label: {
            HStack(alignment: .firstTextBaseline, spacing: MusicSpace.sm) {
                Text(verbatim: String(e.year)).font(Typography.bodyMedium).monospacedDigit().foregroundStyle(ColorTokens.textPrimary).frame(width: 52, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    if let h = e.highlight { Text(verbatim: h.name).font(Typography.bodyMedium).foregroundStyle(ColorTokens.textPrimary).lineLimit(1) }
                    Text(verbatim: parts.joined(separator: " · ")).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textTertiary).accessibilityHidden(true)
            }
            .frame(minHeight: MusicTokens.hitTarget).contentShape(Rectangle())
        }
        .buttonStyle(.plain).hoverHighlight().accessibilityLabel(Localized.string("Show only %d", e.year)).atlas("control.music.artistTimelineYear")
    }
}

/// The Your listening pill: personal and private, from this Mac's play history. It never changes a credit or the order of a list elsewhere on the page.
struct MusicArtistListeningView: View {
    let hub: MusicHub
    let playback: MusicPersonPlayback
    let name: String
    let stats: MusicArtistListeningStats
    @State private var unplayedShown = 25

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            MusicSectionTitle(title: Localized.string("Your listening"))
            Text(Localized.string("Only you see this. It comes from what you played on this Mac and changes nothing about the artist's songs or credits.")).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
            MusicChipFlow(spacing: MusicSpace.lg) {
                tile(Localized.plural(stats.plays, one: "%@ play", other: "%@ plays"), Localized.string("Plays"))
                tile(MusicArtistWording.duration(ms: stats.listenedMs), Localized.string("Listening time"))
                if let f = stats.first { tile(f.formatted(date: .abbreviated, time: .omitted), Localized.string("First played")) }
                if let l = stats.last { tile(l.formatted(date: .abbreviated, time: .omitted), Localized.string("Last played")) }
            }
            if !stats.top.isEmpty {
                VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                    Text(Localized.string("Most played")).font(Typography.title).accessibilityAddTraits(.isHeader)
                    let playable = stats.top.compactMap(\.track)
                    ForEach(Array(stats.top.enumerated()), id: \.element.id) { i, s in
                        let start = s.track.flatMap { t in playable.firstIndex { $0.uid == t.uid } }
                        Button { if let start { hub.play(playable, at: start, sourceName: playback.sourceName ?? name) } } label: {
                        HStack(spacing: MusicSpace.sm) {
                            Text(verbatim: String(i + 1)).font(Typography.caption).monospacedDigit().foregroundStyle(ColorTokens.textTertiary).frame(width: 24, alignment: .trailing)
                            Text(verbatim: s.title).font(Typography.bodyMedium).foregroundStyle(ColorTokens.textPrimary).lineLimit(1)
                            Spacer()
                            Text(verbatim: Localized.plural(s.plays, one: "%@ play", other: "%@ plays")).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                        }
                        .frame(minHeight: MusicTokens.hitTarget).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).hoverHighlight().disabled(start == nil).atlas("control.music.artistTopPlayed")
                    }
                }
            }
            if !stats.unplayed.isEmpty {
                VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                    Text(Localized.string("Not played yet")).font(Typography.title).accessibilityAddTraits(.isHeader)
                    Text(Localized.string("Songs of the catalog loaded here that you have not played: %d", stats.unplayed.count)).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
                    LazyVStack(alignment: .leading, spacing: MusicSpace.xxs) {
                        ForEach(Array(stats.unplayed.prefix(unplayedShown).enumerated()), id: \.element.id) { i, e in
                            MusicPersonSongRow(entry: e, hub: hub, play: { let rest = stats.unplayed.dropFirst(i + 1).map(\.id); Task { await playback.playSong(e.id, queue: Array(rest.prefix(MusicArtistPlayCap.songs))) } })
                        }
                    }
                    if stats.unplayed.count > unplayedShown {
                        Button(Localized.string("Show more")) { unplayedShown += 25 }.musicButton(.secondary).atlas("control.music.artistListeningMore")
                    }
                }
            }
        }
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value).font(Typography.title).foregroundStyle(ColorTokens.textPrimary)
            Text(verbatim: label).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
        }
    }
}

/// The About pill: the biography, the names, life dates, roles and languages, what the catalog holds, and awards when Wikidata lists any. Nothing is invented.
struct MusicArtistAboutView: View {
    let model: MusicPersonGraphModel
    let header: MusicPersonHeaderData
    let catalog: MusicArtistCatalog?
    @State private var wiki: MusicPersonWikiInfo?
    @State private var awards: [MusicPersonAward] = []
    @State private var awardsShown = 8
    @State private var personFacts: MusicPersonFacts?
    /// The lookup reruns when the profile brings an id a restored pill did not have yet.
    private var lookupKey: String { "\(header.id)|\(header.wikidataID ?? "")|\(header.tmdbPersonID ?? "")" }

    private var bio: String? { wiki?.extract ?? wiki?.description.flatMap { $0.isEmpty ? nil : $0 } ?? header.bio?.text }

    var body: some View {
        let facts = self.facts
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            MusicSectionTitle(title: Localized.string("About"))
            if let bio { Text(verbatim: bio).font(Typography.body).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 680, alignment: .leading) }
            if !facts.isEmpty || personFacts?.website != nil {
                MusicSheetCard {
                    VStack(alignment: .leading, spacing: MusicSpace.xs) {
                        ForEach(facts, id: \.label) { f in fact(f.label, f.value) }
                        if let site = personFacts?.website, let url = URL(string: site) { website(site, url) }
                    }
                }
            }
            if let c = catalog, !MusicArtistStats(c).isEmpty {
                VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                    Text(Localized.string("Known to Music")).font(Typography.title).accessibilityAddTraits(.isHeader)
                    let s = MusicArtistStats(c)
                    Text(verbatim: MusicArtistWording.headerLine(s, country: nil)).font(Typography.body).foregroundStyle(ColorTokens.textSecondary)
                    if s.collaborators > 0 { Text(verbatim: MusicArtistWording.count(collaborators: s.collaborators)).font(Typography.body).foregroundStyle(ColorTokens.textSecondary) }
                    Text(Localized.string("Counts come from what Music has loaded for this person, not from every release in the world.")).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
                }
            }
            if !awards.isEmpty {
                VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                    Text(Localized.string("Awards")).font(Typography.title).accessibilityAddTraits(.isHeader)
                    ForEach(awards.prefix(awardsShown)) { a in
                        HStack { Text(verbatim: a.label).font(Typography.body).foregroundStyle(ColorTokens.textPrimary); Spacer(); if let y = a.year { Text(verbatim: String(y)).font(Typography.caption).monospacedDigit().foregroundStyle(ColorTokens.textSecondary) } }
                    }
                    if awards.count > awardsShown { Button(Localized.string("Show more")) { awardsShown += 20 }.musicButton(.secondary, size: .compact).atlas("control.music.artistAwardsMore") }
                }
            }
        }
        .task(id: lookupKey) { await load() }
    }

    private struct Fact { var label: String; var value: String }

    private var facts: [Fact] {
        var out: [Fact] = []
        let display = header.names.display
        var seen = Set<String>([display])
        let aka = header.aliases.map(\.text).filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(6)
        if let o = header.names.otherScript, !o.isEmpty { out.append(Fact(label: Localized.string("Name in its own script"), value: o)) }
        if !aka.isEmpty { out.append(Fact(label: Localized.string("Also known as"), value: aka.joined(separator: ", "))) }
        if let l = header.life { out.append(Fact(label: Localized.string("Life"), value: MusicPersonWording.life(l))) }
        let roles = (model.roles.views.map(\.label) + model.roles.extras.map(\.label)).map { MusicPersonWording.roleLabel($0) }
        if !roles.isEmpty { out.append(Fact(label: Localized.string("Roles"), value: roles.joined(separator: ", "))) }
        if let c = catalog {
            let langs = c.languages.map { MusicPersonReader.languageName($0.code) }
            if !langs.isEmpty { out.append(Fact(label: Localized.string("Languages"), value: langs.joined(separator: ", "))) }
        }
        if let c = model.snapshot?.country, !c.isEmpty { out.append(Fact(label: Localized.string("Country"), value: Locale(identifier: Localized.activeCode).localizedString(forRegionCode: c) ?? c)) }
        if let f = personFacts {
            if let a = MusicPersonFactsRules.activeYears(f) {
                out.append(Fact(label: Localized.string("Active"), value: a.to.map { $0 == a.from ? "\(a.from)" : "\(a.from)–\($0)" } ?? Localized.string("Since %1$@", "\(a.from)")))
            }
            if let b = f.birthPlace { out.append(Fact(label: Localized.string("Born in"), value: b)) }
            if !f.education.isEmpty { out.append(Fact(label: Localized.string("Studied at"), value: f.education.joined(separator: ", "))) }
            if !f.instruments.isEmpty { out.append(Fact(label: Localized.string("Instruments"), value: f.instruments.joined(separator: ", "))) }
            if !f.genres.isEmpty { out.append(Fact(label: Localized.string("Genres"), value: f.genres.joined(separator: ", "))) }
            if !f.labels.isEmpty { out.append(Fact(label: Localized.string("Record labels"), value: f.labels.joined(separator: ", "))) }
        }
        return out
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MusicSpace.sm) {
            Text(verbatim: label).font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary).frame(width: 150, alignment: .leading)
            Text(verbatim: value).font(Typography.body).foregroundStyle(ColorTokens.textPrimary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The person's own website, as a link.
    private func website(_ site: String, _ url: URL) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MusicSpace.sm) {
            Text(verbatim: Localized.string("Official website")).font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary).frame(width: 150, alignment: .leading)
            Link(destination: url) { Text(verbatim: MusicPersonFactsRules.displayHost(site)).font(Typography.body) }
                .accessibilityLabel(Localized.string("Open the official website of %1$@", header.names.display)).atlas("control.music.artistWebsite")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func load() async {
        guard let transport = MusicEntityArtwork.shared.transportIfAllowed() else { return }
        let lookup = MusicPersonWikiInfoLoader.Lookup(name: header.names.display, isGroup: header.isGroup, roleWords: MusicPersonWikiRules.roleWords(forView: model.activeView?.rawValue))
        let info = await MusicPersonWikiInfoLoader.shared.info(qid: header.wikidataID, tmdbID: header.tmdbPersonID, sitelinks: header.sitelinks, readingLanguages: MusicPersonNames.readerLanguages,
                                                              transport: transport, tmdb: MusicEntityArtwork.shared.tmdbFetch, lookup: lookup)
        if !Task.isCancelled { wiki = info }
        let qid = header.wikidataID ?? info?.qid
        if let qid, !qid.isEmpty {
            async let loadedFacts = MusicPersonFactsLoader.shared.facts(qid: qid, readingLanguages: MusicPersonNames.readerLanguages, transport: transport)
            let list = await MusicPersonAwardsLoader.shared.awards(qid: qid, readingLanguages: MusicPersonNames.readerLanguages, transport: transport)
            if !Task.isCancelled { awards = list }
            let f = await loadedFacts
            if !Task.isCancelled { personFacts = f }
        }
    }
}
