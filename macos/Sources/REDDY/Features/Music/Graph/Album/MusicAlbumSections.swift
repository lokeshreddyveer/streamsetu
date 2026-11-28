import SwiftUI
#if os(macOS)
import AppKit
#endif

// The sections the album page adds behind its pills: Versions, Credits by role, About, Your listening, the film card, the comparison and contributor
// sheets and the cover viewer. A section with nothing to show is not drawn. Nothing here names a source.

extension MusicAlbumPill {
    var title: String {
        switch self {
        case .overview: Localized.string("Overview")
        case .tracks: Localized.string("Tracks")
        case .film: Localized.string("Film")
        case .versions: Localized.string("Versions")
        case .credits: Localized.string("Credits")
        case .about: Localized.string("About")
        case .listening: Localized.string("Your listening")
        }
    }
}

extension MusicAlbumEditionBadge {
    var label: String {
        switch self {
        case .original: Localized.string("Original")
        case .standard: Localized.string("Standard")
        case .deluxe: Localized.string("Deluxe")
        case .extended: Localized.string("Extended")
        case .remastered: Localized.string("Remastered")
        case .language(let l): Localized.string("%@ edition", MusicFilmLanguageNames.name(for: l))
        }
    }
}

extension MusicAlbumVersion.Category {
    var title: String {
        switch self {
        case .edition: Localized.string("Editions")
        case .language: Localized.string("Other languages")
        case .soundtrack: Localized.string("Other soundtracks of this film")
        case .related: Localized.string("Related albums")
        }
    }
}

extension MusicAlbumCreditGroup {
    var title: String {
        switch self {
        case .primary: Localized.string("Primary artists")
        case .featured: Localized.string("Featured artists")
        case .vocals: Localized.string("Vocals")
        case .composition: Localized.string("Composition")
        case .songwriting: Localized.string("Songwriting")
        case .production: Localized.string("Production")
        case .arrangement: Localized.string("Arrangement")
        case .instruments: Localized.string("Instruments")
        case .conducting: Localized.string("Conducting")
        }
    }
}

// MARK: pill bar

struct MusicAlbumPillBar: View {
    let pills: [MusicAlbumPill]
    @Binding var tab: MusicAlbumPill
    var body: some View {
        if pills.count > 1 {
            MusicChipFlow(spacing: MusicSpace.xs) {
                ForEach(pills, id: \.self) { p in MusicChip(title: p.title, selected: tab == p) { tab = p } }
            }
        }
    }
}

// MARK: film card

struct MusicAlbumFilmCard: View {
    let page: MusicSoundtrackPageModel
    var body: some View {
        if let film = page.displayHeader?.film {
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                MusicSectionTitle(title: Localized.string("From the film"))
                Button { page.hub.open(film.id) } label: {
                    HStack(spacing: MusicSpace.sm) {
                        MusicArtwork(MusicGraphThumbs.thumbs(film.imageRef), size: MusicSpace.giant + MusicSpace.xl, corner: MusicCorner.control)
                        VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                            Text(verbatim: film.title).font(Typography.bodyMedium).foregroundStyle(ColorTokens.textPrimary).lineLimit(2)
                            Text(verbatim: [film.year.map(String.init), film.language.flatMap { MusicSoundtrackBuild.languageName($0) }].compactMap { $0 }.joined(separator: " · "))
                                .musicText(.caption).foregroundStyle(ColorTokens.textSecondary)
                            if film.isInferredLink { Text("Inferred film link").musicText(.caption).foregroundStyle(ColorTokens.textTertiary) }
                        }
                        Spacer(minLength: MusicSpace.xs)
                        Image(systemName: "chevron.right").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textTertiary).accessibilityHidden(true)
                    }
                    .padding(MusicSpace.xs).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(ColorTokens.elevated, in: RoundedRectangle(cornerRadius: MusicCorner.control, style: .continuous))
                .accessibilityLabel(Localized.string("Open the film %@", film.title))
                .atlas("control.music.albumFilmCard")
            }
        }
    }
}

// MARK: versions

struct MusicAlbumVersionsSection: View {
    let page: MusicSoundtrackPageModel
    let extras: MusicAlbumExtrasModel
    @State private var compareWith: MusicAlbumVersion?

    var body: some View {
        let visible = extras.visibleVersions
        VStack(alignment: .leading, spacing: MusicSpace.lg) {
            if let own = extras.own {
                VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                    MusicSectionTitle(title: Localized.string("This edition"))
                    Text(verbatim: [MusicAlbumEditionRules.badge(own, siblings: extras.versions.filter { $0.category == .edition || $0.category == .language }.map(\.facts) + [own]).label, own.year.map(String.init),
                                    own.trackCount > 0 ? Localized.plural(own.trackCount, one: "%@ song", other: "%@ songs") : nil].compactMap { $0 }.joined(separator: " · "))
                        .musicText(.body).foregroundStyle(ColorTokens.textSecondary)
                    if extras.preferredEdition == page.entity { Label(Localized.string("Your preferred edition"), systemImage: "star.fill").musicText(.caption).foregroundStyle(ColorTokens.textSecondary) }
                }
            }
            ForEach(MusicAlbumVersion.Category.allCases, id: \.self) { cat in
                let items = visible.filter { $0.category == cat }
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: MusicSpace.xs) {
                        MusicSectionTitle(title: cat.title)
                        ForEach(items) { v in row(v) }
                    }
                }
            }
            let hidden = extras.hiddenVersions
            if !hidden.isEmpty {
                VStack(alignment: .leading, spacing: MusicSpace.xs) {
                    MusicSectionTitle(title: Localized.string("Hidden editions"))
                    ForEach(hidden) { v in
                        HStack {
                            Text(verbatim: v.facts.title).musicText(.body).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
                            Spacer()
                            Button(Localized.string("Restore")) { extras.setHidden(v.id, false) }.musicButton(.tertiary, size: .compact, accentText: true).atlas("control.music.albumRestoreEdition")
                        }
                    }
                }
            }
        }
        .sheet(item: $compareWith) { v in MusicAlbumCompareSheet(page: page, extras: extras, other: v) { compareWith = nil } }
    }

    private func row(_ v: MusicAlbumVersion) -> some View {
        HStack(spacing: MusicSpace.xs) {
            Button { page.hub.open(v.id) } label: {
                HStack(spacing: MusicSpace.sm) {
                    MusicArtwork(MusicGraphThumbs.thumbs(v.imageRef), size: MusicSpace.giant, corner: MusicCorner.control)
                    VStack(alignment: .leading, spacing: MusicSpace.xxs / 2) {
                        Text(verbatim: v.facts.title).font(Typography.bodyMedium).foregroundStyle(ColorTokens.textPrimary).lineLimit(2)
                        Text(verbatim: caption(v)).musicText(.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: MusicSpace.xs)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel(Localized.string("Open %@", v.facts.title)).atlas("control.music.albumVersionOpen")
            Menu {
                Button(Localized.string("Compare with this edition"), systemImage: "rectangle.split.2x1") { compareWith = v }.atlas("control.music.albumCompareEditions")
                if v.category == .edition || v.category == .language {
                    if extras.preferredEdition == v.id {
                        Button(Localized.string("Clear preferred edition"), systemImage: "star.slash") { extras.setPreferred(nil) }.atlas("control.music.albumSetPreferred")
                    } else {
                        Button(Localized.string("Set as preferred edition"), systemImage: "star") { extras.setPreferred(v.id) }.atlas("control.music.albumSetPreferred")
                    }
                    Button(Localized.string("Hide this edition"), systemImage: "eye.slash") { extras.setHidden(v.id, true) }.atlas("control.music.albumHideEdition")
                }
            } label: { Image(systemName: "ellipsis").font(MusicTokens.iconMedium) }
            .menuStyle(.button).menuIndicator(.hidden).musicButton(.icon, size: .compact).fixedSize()
            .accessibilityLabel(Localized.string("Edition options")).atlas("control.music.albumVersionMenu")
        }
    }

    private func caption(_ v: MusicAlbumVersion) -> String {
        var parts: [String] = []
        if v.category == .edition || v.category == .language, v.badge != .standard { parts.append(v.badge.label) }
        if let y = v.facts.year { parts.append(String(y)) }
        if v.facts.trackCount > 0 { parts.append(Localized.plural(v.facts.trackCount, one: "%@ song", other: "%@ songs")) }
        if extras.preferredEdition == v.id { parts.append(Localized.string("Preferred")) }
        return parts.joined(separator: " · ")
    }
}

struct MusicAlbumCompareSheet: View {
    let page: MusicSoundtrackPageModel
    let extras: MusicAlbumExtrasModel
    let other: MusicAlbumVersion
    let close: () -> Void
    @State private var comparison: MusicAlbumEditionComparison?

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            HStack {
                Text("Compare editions").font(MusicTokens.sheetTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.musicButton(.glassIcon, size: .regular)
                    .accessibilityLabel(Localized.string("Close")).keyboardShortcut(.cancelAction).atlas("control.music.albumCompareClose")
            }
            if let c = comparison {
                Grid(alignment: .leading, horizontalSpacing: MusicSpace.lg, verticalSpacing: MusicSpace.xs) {
                    GridRow {
                        Text(verbatim: "").gridColumnAlignment(.leading)
                        Text(verbatim: c.left.title).font(Typography.bodyMedium).lineLimit(2)
                        Text(verbatim: c.right.title).font(Typography.bodyMedium).lineLimit(2)
                    }
                    line(Localized.string("Songs"), c.left.trackCount > 0 ? String(c.left.trackCount) : nil, c.right.trackCount > 0 ? String(c.right.trackCount) : nil, c.trackCountDiffers)
                    line(Localized.string("Length"), c.left.durationMs > 0 ? MusicDurationText.total(ms: c.left.durationMs) : nil, c.right.durationMs > 0 ? MusicDurationText.total(ms: c.right.durationMs) : nil, c.durationDiffers)
                    line(Localized.string("Year"), c.left.year.map(String.init), c.right.year.map(String.init), c.yearDiffers)
                    line(Localized.string("Language"), c.left.dubLanguage.map { MusicFilmLanguageNames.name(for: $0) }, c.right.dubLanguage.map { MusicFilmLanguageNames.name(for: $0) }, c.languageDiffers)
                }
                if c.left.trackTitles.isEmpty || c.right.trackTitles.isEmpty {
                    Text(Localized.string("The songs of one edition are not known yet.")).musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
                }
                if !c.onlyLeft.isEmpty || !c.onlyRight.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: MusicSpace.xs) {
                            if !c.onlyLeft.isEmpty { bonus(Localized.string("Only on %@", c.left.title), c.onlyLeft) }
                            if !c.onlyRight.isEmpty { bonus(Localized.string("Only on %@", c.right.title), c.onlyRight) }
                        }
                    }
                }
            } else {
                MusicLoadingIcon(size: MusicIconSize.small).frame(maxWidth: .infinity, minHeight: 80)
            }
            HStack {
                Spacer()
                Button(Localized.string("Open that edition")) { close(); page.hub.open(other.id) }.musicButton(.secondary, size: .regular).atlas("control.music.albumCompareOpen")
            }
        }
        .padding(MusicSpace.lg)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 360)
        .task { await load() }
    }

    @ViewBuilder private func line(_ label: String, _ a: String?, _ b: String?, _ differs: Bool) -> some View {
        if a != nil || b != nil {
            GridRow {
                Text(verbatim: label).musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
                Text(verbatim: a ?? "–").musicText(.body).monospacedDigit().foregroundStyle(differs ? ColorTokens.textPrimary : ColorTokens.textSecondary)
                Text(verbatim: b ?? "–").musicText(.body).monospacedDigit().foregroundStyle(differs ? ColorTokens.textPrimary : ColorTokens.textSecondary)
            }
        }
    }

    private func bonus(_ title: String, _ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: MusicSpace.xxs) {
            Text(verbatim: title).musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
            ForEach(Array(names.enumerated()), id: \.offset) { _, n in Text(verbatim: n).musicText(.body).foregroundStyle(ColorTokens.textPrimary) }
        }
    }

    private func load() async {
        let r = MusicSoundtrackReader(MusicEntityRuntime.shared.store.graph)
        let theirs = await MusicAlbumReads.editionTracks(r, other.id)
        var mine = extras.own ?? MusicAlbumEditionFacts(id: page.entity.rawValue, title: page.displayHeader?.title ?? "")
        mine.trackTitles = page.tracks.isEmpty ? page.rows.map(\.title) : page.tracks.map(\.title)
        mine.durationMs = page.totalDurationMs
        if mine.trackCount == 0 { mine.trackCount = mine.trackTitles.count }
        var o = other.facts
        o.trackTitles = theirs.titles; o.durationMs = theirs.durationMs
        if o.trackCount == 0 { o.trackCount = theirs.titles.count }
        comparison = MusicAlbumEditionComparison.compare(mine, o)
    }
}

// MARK: credits by role

struct MusicAlbumCreditsSection: View {
    let page: MusicSoundtrackPageModel
    @State private var sheetFor: MusicSoundtrackCredit?

    var body: some View {
        let all = page.rawCredits.filter { !$0.isFilmCredit }   // film crew credits are the film page's, not this album's
        let grouped = Dictionary(grouping: all.compactMap { c in MusicAlbumCreditGroup.of(c.role).map { ($0, c) } }, by: { $0.0 })
        if grouped.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: MusicSpace.lg) {
                MusicSectionTitle(title: Localized.string("Credits"))
                ForEach(MusicAlbumCreditGroup.allCases, id: \.self) { g in
                    if let list = grouped[g]?.map({ $0.1 }), !list.isEmpty {
                        VStack(alignment: .leading, spacing: MusicSpace.xs) {
                            Text(verbatim: g.title).musicText(.caption).foregroundStyle(ColorTokens.textTertiary).accessibilityAddTraits(.isHeader)
                            ForEach(Array(list.enumerated()), id: \.offset) { _, c in
                                HStack(spacing: MusicSpace.xs) {
                                    MusicInlineLink(title: c.person.name, font: Typography.bodyMedium, label: Localized.string("Open %@", c.person.name), rest: ColorTokens.textPrimary) {
                                        page.hub.open(c.person.id, role: c.role)
                                    }
                                    if c.songCount > 0 {
                                        Button { sheetFor = c } label: {
                                            Text(verbatim: Localized.plural(c.songCount, one: "%@ song", other: "%@ songs")).musicText(.caption)
                                        }
                                        .musicButton(.tertiary, size: .compact, accentText: true)
                                        .accessibilityLabel(Localized.string("Songs by %@ on this album", c.person.name)).atlas("control.music.albumContributorSongs")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .sheet(item: $sheetFor) { c in MusicAlbumContributorSheet(page: page, credit: c) { sheetFor = nil } }
        }
    }
}

extension MusicSoundtrackCredit: Identifiable {
    var id: String { person.id.rawValue + "|" + role.rawValue }
}

struct MusicAlbumContributorSheet: View {
    let page: MusicSoundtrackPageModel
    let credit: MusicSoundtrackCredit
    let close: () -> Void
    @State private var titles: [String]?

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            HStack {
                Text(verbatim: credit.person.name).font(MusicTokens.sheetTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.musicButton(.glassIcon, size: .regular)
                    .accessibilityLabel(Localized.string("Close")).keyboardShortcut(.cancelAction).atlas("control.music.albumContributorClose")
            }
            if let titles {
                if titles.isEmpty {
                    Text("No songs are credited to this person individually.").musicText(.secondary).foregroundStyle(ColorTokens.textTertiary)
                } else {
                    ScrollView { VStack(alignment: .leading, spacing: MusicSpace.xs) { ForEach(Array(titles.enumerated()), id: \.offset) { _, t in Text(verbatim: t).musicText(.body) } } }
                }
            } else {
                MusicLoadingIcon(size: MusicIconSize.small).frame(maxWidth: .infinity, minHeight: 80)
            }
            HStack {
                Spacer()
                Button(Localized.string("Open page")) { close(); page.hub.open(credit.person.id, role: credit.role) }.musicButton(.secondary, size: .regular).atlas("control.music.albumContributorOpen")
            }
        }
        .padding(MusicSpace.lg)
        .frame(minWidth: 400, idealWidth: 440, minHeight: 300)
        .task {
            let rows = page.rows
            let hits = await MusicAlbumReads.tracks(of: credit.person.id, among: rows.map(\.id), graph: MusicEntityRuntime.shared.store.graph)
            titles = rows.filter { hits.contains($0.id) }.map(\.title)
        }
    }
}

// MARK: about

struct MusicAlbumAboutSection: View {
    let page: MusicSoundtrackPageModel
    let extras: MusicAlbumExtrasModel

    var body: some View {
        let i = extras.info
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            MusicSectionTitle(title: Localized.string("About this release"))
            if let d = i.description { Text(verbatim: d).musicText(.body).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true) }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: MusicSpace.lg, verticalSpacing: MusicSpace.xs) {
                row(Localized.string("Released"), i.releaseDate)
                row(Localized.string("Original year"), i.originalYear.map(String.init))
                row(Localized.string("Language"), i.language)
                row(Localized.string("Genres"), i.genres.isEmpty ? nil : i.genres.joined(separator: ", "))
                row(Localized.string("Label"), i.label)
                row(Localized.string("Catalogue number"), i.catalogueNumber)
                row(Localized.string("Barcode"), i.barcode)
                row(Localized.string("Songs"), page.rows.isEmpty ? nil : String(page.rows.count))
                row(Localized.string("Discs"), Set(page.rows.compactMap(\.disc)).count > 1 ? String(Set(page.rows.compactMap(\.disc)).count) : nil)
                row(Localized.string("Length"), page.totalDurationMs > 0 ? MusicDurationText.total(ms: page.totalDurationMs) : nil)
                row(Localized.string("Copyright"), i.copyright)
            }
        }
    }

    @ViewBuilder private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(verbatim: label).musicText(.caption).foregroundStyle(ColorTokens.textTertiary).gridColumnAlignment(.leading)
                Text(verbatim: value).musicText(.body).foregroundStyle(ColorTokens.textPrimary).textSelection(.enabled)
            }
        }
    }
}

// MARK: your listening

struct MusicAlbumListeningSection: View {
    let page: MusicSoundtrackPageModel

    static func stats(_ page: MusicSoundtrackPageModel) -> MusicAlbumListeningStats {
        MusicAlbumListening.stats(trackUIDs: page.tracks.map(\.uid), history: page.hub.library.history, liked: Set(page.hub.library.liked.map(\.uid)))
    }

    var body: some View {
        let s = Self.stats(page)
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            MusicSectionTitle(title: Localized.string("Your listening"))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: MusicSpace.lg, verticalSpacing: MusicSpace.xs) {
                row(Localized.string("Songs explored"), Localized.string("%1$@ of %2$@", String(s.explored), String(s.trackCount)))
                row(Localized.string("Plays"), String(s.totalPlays))
                row(Localized.string("Favourite songs"), String(s.favourites))
                if s.listenedMs > 0 { row(Localized.string("Listening time"), MusicDurationText.total(ms: s.listenedMs)) }
                row(Localized.string("Most played"), s.mostPlayed.flatMap { m in page.tracks.first { $0.uid == m.uid }.map { "\($0.title) (\(m.plays))" } })
                row(Localized.string("First listened"), s.firstListened.map { $0.formatted(date: .abbreviated, time: .omitted) })
                row(Localized.string("Last listened"), s.lastListened.map { $0.formatted(date: .abbreviated, time: .omitted) })
            }
            if !s.unplayed.isEmpty, s.unplayed.count < s.trackCount {
                Button { play(.unplayedOnly, s) } label: { Label(Localized.string("Play unplayed songs"), systemImage: "play") }
                    .musicButton(.secondary, size: .regular).atlas("control.music.albumPlayUnplayed")
            }
        }
    }

    private func play(_ mode: MusicAlbumPlaybackMode, _ s: MusicAlbumListeningStats) {
        let played = Set(page.tracks.map(\.uid)).subtracting(s.unplayed)
        if let plan = MusicAlbumPlayback.plan(mode, tracks: page.tracks, liked: [], played: played) { page.hub.play(plan.tracks, at: plan.startIndex, sourceName: page.displayHeader?.title) }
    }

    @ViewBuilder private func row(_ label: String, _ value: String?) -> some View {
        if let value {
            GridRow {
                Text(verbatim: label).musicText(.caption).foregroundStyle(ColorTokens.textTertiary).gridColumnAlignment(.leading)
                Text(verbatim: value).musicText(.body).foregroundStyle(ColorTokens.textPrimary)
            }
        }
    }
}

// MARK: export

enum MusicAlbumExporter {
    @MainActor static func save(title: String, items: [MusicAlbumTrackItem], csv: Bool) {
        #if os(macOS)
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r")
        let name = title.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (name.isEmpty ? "Album" : String(name.prefix(80))) + (csv ? ".csv" : ".txt")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = csv ? MusicAlbumExport.csv(items: items) : MusicAlbumExport.plainText(title: title, items: items)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            MusicToasts.shared.show(Localized.string("Saved “%@”.", url.lastPathComponent), kind: .success)
        } catch {
            MusicToasts.shared.error(Localized.string("Could not save the file."))
        }
        #else
        MusicToasts.shared.show(Localized.string("Saving a playlist file needs the Mac app."), kind: .info)
        #endif
    }
}
