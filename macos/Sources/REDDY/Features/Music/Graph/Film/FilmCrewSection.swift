import SwiftUI

/// The film's credits as a Details card, the way the app's own movie page lists them: one row per role (Directed by, Music by, Written by, Produced by...), the label on the left and
/// the people on the right as names that open their page on that role, then the year and languages. A row with many names shows the first few and "+N more". Hidden when nothing is known.
struct MusicFilmCrewSection: View {
    let model: MusicFilmGraphModel
    let hub: MusicHub
    /// nil: every credit with the film's facts (the Overview card). true: only the music department. false: only the rest of the film crew (the Crew page shows both).
    var musicOnly: Bool? = nil
    /// The Crew tab's search text: a group stays when its label matches, else only the people whose names match.
    var query = ""
    @State private var expanded: Set<String> = []
    @State private var showFranchise = false
    /// True once the graph holds another film of the franchise; until then (or when none) the row is the franchise name alone, with no button that opens an empty sheet.
    @State private var franchiseHasMore = false
    @ScaledMetric(relativeTo: .subheadline) private var labelWidth: CGFloat = 120
    private static let shown = 4
    /// The roles of the film's music department. A film's producer or screenwriter belongs to the film crew, not to its music.
    static let musicDepartment: Set<MusicRole> = [.musicDirector, .composer, .arranger, .lyricist, .conductor, .singer, .instrumentalist, .performer]

    var body: some View {
        let crew = visibleCrew()
        let headings = musicOnly == false && Set(crew.map(MusicFilmCrewHeading.of)).count > 1
        let facts = musicOnly == nil ? factRows : []
        if crew.isEmpty, musicOnly == false, !query.isEmpty, MusicFilmCrewSearch.filter(model.crew, query: query, label: MusicFilmWording.crewTitle).isEmpty {
            Text(verbatim: Localized.string("No results")).musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
        }
        if !crew.isEmpty || !facts.isEmpty {
            let detail = MusicFilmWording.disambiguators(crew.flatMap(\.people) + model.cast)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: musicOnly == true ? Localized.string("Music department") : musicOnly == false ? Localized.string("Film crew") : Localized.string("Details")).musicText(.caption).tracking(1.2).foregroundStyle(ColorTokens.textTertiary)
                    .accessibilityAddTraits(.isHeader).padding(.bottom, MusicSpace.sm)
                ForEach(Array(crew.enumerated()), id: \.element.id) { i, group in
                    let heading = MusicFilmCrewHeading.of(group)
                    let starts = headings && (i == 0 || MusicFilmCrewHeading.of(crew[i - 1]) != heading)
                    if i > 0 && !starts { Divider().overlay(ColorTokens.line) }
                    if starts {
                        Text(verbatim: MusicFilmWording.headingTitle(heading)).musicText(.caption).foregroundStyle(ColorTokens.textSecondary)
                            .padding(.top, i == 0 ? 0 : MusicSpace.md).padding(.bottom, MusicSpace.xxs).accessibilityAddTraits(.isHeader)
                    }
                    row(label: MusicFilmWording.crewTitle(group)) { people(group, detail: detail) }
                }
                ForEach(Array(facts.enumerated()), id: \.offset) { i, f in
                    if i > 0 || !crew.isEmpty { Divider().overlay(ColorTokens.line) }
                    row(label: f.0) { Text(verbatim: f.1).foregroundStyle(ColorTokens.textPrimary) }
                }
                if musicOnly == nil, let name = model.entity?.snapshot?.attrs["franchise"], !name.isEmpty, let id = model.entity?.id {
                    if !crew.isEmpty || !facts.isEmpty { Divider().overlay(ColorTokens.line) }
                    row(label: Localized.string("Franchise")) {
                        if franchiseHasMore {
                            Button { showFranchise = true } label: { Text(verbatim: name).foregroundStyle(ColorTokens.textPrimary).underline() }.buttonStyle(.plain).atlas("control.music.franchiseOpen")
                        } else {
                            Text(verbatim: name).foregroundStyle(ColorTokens.textPrimary)
                        }
                    }
                    .task(id: id) { franchiseHasMore = await MusicFranchise.load(for: id, store: MusicEntityRuntime.shared.center.store.graph) != nil }
                    .sheet(isPresented: $showFranchise) { MusicFranchiseSheet(hub: hub, film: id, fallbackName: name) { showFranchise = false } }
                }
            }
            .padding(MusicSpace.lg)
            .frame(maxWidth: 640, alignment: .leading)
            .background(ColorTokens.surface, in: RoundedRectangle(cornerRadius: MusicCorner.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: MusicCorner.card, style: .continuous).strokeBorder(ColorTokens.line, lineWidth: 0.75))
        }
    }

    /// The groups this card lists: its scope, then the search, and on the film-crew card in heading order.
    private func visibleCrew() -> [MusicFilmCrewItem] {
        let scoped = model.crew.filter { g in
            switch musicOnly {
            case nil: g.department == nil   // the Details card lists the film's own credits; the TMDB departments are on the Crew tab
            case true?: g.department == nil && Self.musicDepartment.contains(g.role)
            case false?: g.department != nil || !Self.musicDepartment.contains(g.role)
            }
        }
        let found = MusicFilmCrewSearch.filter(scoped, query: query, label: MusicFilmWording.crewTitle)
        return musicOnly == false ? MusicFilmCrewHeading.ordered(found) : found
    }

    private var factRows: [(String, String)] {
        var out: [(String, String)] = []
        let o = model.overview
        if let y = o?.year ?? model.entity?.snapshot?.year { out.append((Localized.string("Released"), String(y))) }
        if let l = o?.languages, !l.isEmpty { out.append((Localized.string("Language"), MusicFilmWording.joined(l))) }
        // The industry comes from the film's own language and country; a film with neither, or made outside India, has none.
        let snap = model.entity?.snapshot
        if !model.isSeries, let ind = MusicFilmIndustry.classify(language: snap?.lang ?? o?.languages.first, country: snap?.country) { out.append((Localized.string("Industry"), ind.title)) }
        return out
    }

    private func row<V: View>(label: String, @ViewBuilder value: () -> V) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MusicSpace.md) {
            Text(verbatim: label).foregroundStyle(ColorTokens.textSecondary).frame(width: labelWidth, alignment: .leading)
            value().frame(maxWidth: .infinity, alignment: .leading)
        }
        .musicText(.body)
        .padding(.vertical, MusicSpace.xs)
    }

    private func name(_ p: MusicFilmPersonItem, _ detail: [MusicEntityID: String]) -> String {
        guard let d = detail[p.person] else { return p.name }
        return p.name + " (" + d + ")"
    }

    private func people(_ group: MusicFilmCrewItem, detail: [MusicEntityID: String]) -> some View {
        let key = group.id
        let all = group.people
        let open = expanded.contains(key) || all.count <= Self.shown + 1
        let list = open ? all : Array(all.prefix(Self.shown))
        return MusicGraphFlowLayout(spacing: MusicSpace.xs) {
            ForEach(list, id: \.person) { p in
                Button { hub.open(p.person, role: group.department == nil ? group.role : nil) } label: {
                    Text(verbatim: name(p, detail)).foregroundStyle(ColorTokens.textPrimary).lineLimit(1)
                }
                .buttonStyle(.plain).hoverHighlight()
                .accessibilityLabel(Localized.string("%1$@, %2$@", p.name, p.job ?? MusicFilmWording.crewTitle(group)))
                .atlasCovers("control.music.graphCreditChip")
            }
            if all.count > list.count {
                Button { expanded.insert(key) } label: { Text(verbatim: Localized.string("+%d more", all.count - list.count)).foregroundStyle(ColorTokens.accent) }
                    .buttonStyle(.plain).atlasCovers("control.music.graphCreditChip")
            } else if open && all.count > Self.shown + 1 {
                Button { expanded.remove(key) } label: { Text(verbatim: Localized.string("Show less")).foregroundStyle(ColorTokens.accent) }
                    .buttonStyle(.plain).atlasCovers("control.music.graphCreditChip")
            }
        }
    }
}
