import SwiftUI

// The person screen: an about-the-person header from TMDB, then the complete filmography as a poster grid, each film marked as in the library or not.

/// One tile of the filmography.
struct FilmTile: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let year: Int?
    let date: String?
    let rating: Double?
    let posterURL: String?
    let isSeries: Bool
    let popularity: Double
    let overview: String?
    let role: String?
    /// Set only for a title that is in the library and may be shown (never a restricted one).
    var kind = FilmRole.lead
    /// "Voice", "Narrator", "Cameo" or "Guest" when this is not an on-screen part.
    var tag: String? = nil
    var item: LibraryItem?
    var versions = 1
    var otherLanguages: [String] = []
    var inLibrary: Bool { item != nil }

    var accessibilityText: String {
        [title, year.map(String.init), isSeries ? "series" : nil, tag.map { $0.lowercased() + " credit" }, rating.map { "rated \(String(format: "%.1f", $0))" }, inLibrary ? "in your library" : "not in your library"].compactMap { $0 }.joined(separator: ", ")
    }
}

enum FilmScope: String, Sendable { case all, library }
enum FilmSort: String, CaseIterable, Sendable { case newest = "Newest", popular = "Popular", rating = "Rating" }
enum FilmKind: String, CaseIterable, Sendable { case all = "All", movies = "Movies", series = "Series" }

enum Filmography {
    /// Tiles for the credits: the matched ones carry their library item.
    static func tiles(credits: [FilmCredit], matches: [String: FilmographyMatcher.Match], items: [String: LibraryItem]) -> [FilmTile] {
        credits.map { c in
            var t = FilmTile(id: c.id, title: DisplayTitle.clean(c.title), year: c.year, date: c.date, rating: c.rating, posterURL: c.posterURL, isSeries: c.isSeries, popularity: c.popularity, overview: c.overview, role: c.isCrewMaker ? nil : c.role)
            t.kind = c.kind; t.tag = FilmRole.tag(character: c.role, kind: c.kind)
            if let m = matches[c.id], let item = items[m.representative] { t.item = item; t.versions = m.versions; t.otherLanguages = m.languages }
            return t
        }
    }

    /// The local list (what the cast index knows) as tiles, used without TMDB.
    static func tiles(local entries: [PersonTitles.Entry]) -> [FilmTile] {
        entries.map { e in
            let raw: String? = { switch e.item { case .movie(let m): m.rating; case .series(let s): s.rating } }()
            return FilmTile(id: e.item.id, title: DisplayTitle.clean(e.item.title), year: e.item.year, date: e.item.year.map(String.init), rating: RatingRule.credible(raw), posterURL: e.item.posterURL,
                            isSeries: e.item.isSeries, popularity: 0, overview: e.item.overview, role: nil, item: e.item, versions: 1 + e.otherLanguages.count, otherLanguages: e.otherLanguages)
        }
    }

    struct Arranged: Equatable {
        var shown: [FilmTile]
        var allCount: Int
        var libraryCount: Int
        /// On-screen parts first, then voice, narration and cameo credits (under their own quiet heading).
        var onScreen: [FilmTile] { shown.filter { $0.kind == .lead } }
        var voiceAndCameo: [FilmTile] { shown.filter { $0.kind != .lead } }
    }

    /// Filter by Movies/Series, count both buttons on that filter, apply the scope, then sort.
    static func arrange(_ tiles: [FilmTile], kind: FilmKind, scope: FilmScope, sort: FilmSort, actingOnly: Bool = false) -> Arranged {
        let base = tiles.filter { (kind == .all || (kind == .series) == $0.isSeries) && (!actingOnly || $0.kind == .lead) }
        let lib = base.filter(\.inLibrary)
        let list = scope == .library ? lib : base
        func tie(_ a: FilmTile, _ b: FilmTile) -> Bool { a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending }
        let sorted: [FilmTile]
        switch sort {
        case .newest: sorted = list.sorted { a, b in
            switch (a.date, b.date) { case let (x?, y?): x != y ? x > y : tie(a, b); case (nil, _?): false; case (_?, nil): true; default: tie(a, b) } }
        case .popular: sorted = list.sorted { $0.popularity != $1.popularity ? $0.popularity > $1.popularity : tie($0, $1) }
        case .rating: sorted = list.sorted { a, b in
            switch (a.rating, b.rating) { case let (x?, y?): x != y ? x > y : tie(a, b); case (nil, _?): false; case (_?, nil): true; default: tie(a, b) } }
        }
        // stable: on-screen parts first, each group in the chosen order
        let grouped = sorted.filter { $0.kind == .lead } + sorted.filter { $0.kind != .lead }
        return Arranged(shown: grouped, allCount: base.count, libraryCount: lib.count)
    }

    /// Matches the credits to the library and loads the items of the matches (restricted titles never match).
    @MainActor static func build(file: PersonFile, container c: AppContainer) async -> [FilmTile] {
        let preferred = OtherLanguages.preferredName(c.settings.preferredAudioLanguage)
        return await Task.detached { () -> [FilmTile] in
            let matches = FilmographyMatcher(db: c.db, preferredLanguage: preferred).match(file.credits)
            let view = c.catalog.recommendationView
            var items: [String: LibraryItem] = [:]
            for m in matches.values {
                let id = m.representative
                if m.kind == .series { if let s = (try? view.seriesItem(id: id)) ?? nil { items[id] = .series(s) } }
                else if let mv = (try? view.movie(id: id)) ?? nil { items[id] = .movie(mv) }
            }
            return tiles(credits: file.credits, matches: matches, items: items)
        }.value
    }
}

@MainActor @Observable final class PersonPageModel {
    enum Phase: Equatable { case loading, ready }
    private(set) var phase = Phase.loading
    private(set) var profile: PersonProfile?
    private(set) var tiles: [FilmTile] = []
    /// A quiet line under the header when the full filmography is not available.
    private(set) var note: String?
    /// Only the local list is shown (no TMDB credential, offline, kids profile, or the person was not found).
    private(set) var localOnly = false
    /// The request failed (offline or an error): the empty state offers Retry.
    private(set) var failed = false
    var kind = FilmKind.all
    var sort = FilmSort.newest
    var scope: FilmScope { didSet { UserDefaults.standard.set(scope.rawValue, forKey: Self.scopeKey) } }
    static let scopeKey = "person.scope"
    static let actingKey = "person.actingOnly"
    /// Hides voice, narration and cameo credits (remembered on this device).
    var actingOnly: Bool { didSet { UserDefaults.standard.set(actingOnly, forKey: Self.actingKey) } }
    /// A saved copy is refreshed when it is older than this.
    static let refreshAfter: TimeInterval = Retention.personRefresh

    init() { scope = FilmScope(rawValue: UserDefaults.standard.string(forKey: Self.scopeKey) ?? "") ?? .all; actingOnly = UserDefaults.standard.bool(forKey: Self.actingKey) }

    var arranged: Filmography.Arranged { Filmography.arrange(tiles, kind: kind, scope: scope, sort: sort, actingOnly: actingOnly) }

    func load(_ route: PersonRoute, container c: AppContainer) async {
        phase = .loading; profile = nil; tiles = []; note = nil; localOnly = false; failed = false
        let m = c.metadata
        let language = MetadataMatchService.tmdbLanguage(for: c.settings.language)
        let hints = route.fromTitle.map { [DisplayTitle.clean($0)] } ?? []
        if c.parental.kidsMode { await fallback(route, c, note: nil); return }
        var id = route.tmdbID ?? m.savedPersonID(name: route.name, hints: hints)
        var cachedAge: TimeInterval?
        if let id, let saved = m.savedPerson(id: id, language: language) {
            await apply(saved, c); cachedAge = Date().timeIntervalSince1970 - saved.fetchedAt          // instantly
        }
        guard m.hasKey else { if cachedAge == nil { await fallback(route, c, note: "Add an artwork and details key for the full filmography") }; return }
        guard m.lookupsAllowed() else { if cachedAge == nil { await fallback(route, c, note: nil) }; return }
        if let a = cachedAge, a < Self.refreshAfter { return }
        do {
            if id == nil { id = try await m.resolvePerson(name: route.name, hints: hints) }
            guard let id else { if cachedAge == nil { await fallback(route, c, note: nil) }; return }
            let file = try await m.refreshPerson(id: id, language: language)
            if Task.isCancelled { return }
            await apply(file, c)
        } catch is CancellationError { return }
        catch {
            if cachedAge == nil { failed = true; await fallback(route, c, note: (error as? MetadataMatchService.MatchError) == .offline ? (c.matchNetwork.isOnline ? "The details service did not answer, try again" : "You are offline") : nil) }
        }
    }

    private func apply(_ file: PersonFile, _ c: AppContainer) async {
        let built = await Filmography.build(file: file, container: c)
        if Task.isCancelled { return }
        profile = file.profile; tiles = built; localOnly = false; note = nil; phase = .ready
    }

    private func fallback(_ route: PersonRoute, _ c: AppContainer, note: String?) async {
        let entries = await PersonTitles.load(name: route.name, container: c)
        if Task.isCancelled { return }
        tiles = Filmography.tiles(local: entries); localOnly = true; self.note = note; phase = .ready
    }
}

struct PersonPage: View {
    let route: PersonRoute
    /// Mac: opens the title page. On iPhone and iPad a title is pushed with a link instead.
    var open: (LibraryItem) -> Void = { _ in }
    @Environment(\.container) private var container
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = PersonPageModel()
    @State private var info: FilmTile?
    @State private var photo: String?
    @State private var bioOpen = false
    @FocusState private var scopeFocus: Bool

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 150 : 112, maximum: 180), spacing: 14, alignment: .top)] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                controls          // always drawn, from the first moment, so this screen can never be taken for the film page
                if let n = model.note { Text(n).font(.footnote).foregroundStyle(.secondary) }
                content
                Text(MetadataMatchService.attribution).font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(route.name)
        .task(id: route) { if let c = container { await model.load(route, container: c) } }
        .modifier(PersonOverlays(info: $info, photo: $photo))
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                portrait
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.profile?.name ?? route.name).font(.title.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    if model.phase == .loading && model.profile == nil {
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: 3).fill(ColorTokens.card).frame(width: 220, height: 11)
                            RoundedRectangle(cornerRadius: 3).fill(ColorTokens.card).frame(width: 300, height: 11)
                        }.padding(.top, 4).accessibilityHidden(true)
                    }
                    if let p = model.profile {
                        if let born = PersonFacts.bornLine(p) { Text(born).font(.subheadline).foregroundStyle(.secondary) }
                        if let known = PersonFacts.knownFor(p, credits: model.tiles.isEmpty ? [] : knownCredits) { Text("Known for: " + known).font(.subheadline).foregroundStyle(.secondary) }
                        if let aka = PersonFacts.alsoKnownAs(p) { Text("Also known as " + aka).font(.footnote).foregroundStyle(.tertiary) }
                    }
                }
                Spacer(minLength: 0)
            }
            if model.phase == .loading && model.profile == nil {
                Text("Loading the biography of \(route.name). Born, known for and more appear here.").font(.callout).redacted(reason: .placeholder).lineLimit(3).accessibilityHidden(true)
            }
            if let bio = model.profile?.biography {
                VStack(alignment: .leading, spacing: 4) {
                    Text(bio).font(.callout).lineLimit(bioOpen ? nil : 4).fixedSize(horizontal: false, vertical: true)
                    if bio.count > 240 { Button(bioOpen ? "Less" : "More") { bioOpen.toggle() }.buttonStyle(.plain).font(.callout.weight(.semibold)).foregroundStyle(.tint).atlas("screen.person") }
                }
            }
            if let photos = model.profile?.photos, photos.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(photos, id: \.self) { path in
                            Button { photo = path } label: {
                                ArtworkImage(url: MetadataMatchService.imageBase + "w185" + path, kind: .poster, contentMode: .fill, symbol: "person.fill").frame(width: 52, height: 78).clipShape(RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain).accessibilityLabel("Photo of \(route.name)").atlas("screen.person")
                        }
                    }
                }.frame(height: 78)
            }
        }
    }

    /// The best-known titles are the popular ones among the credits shown.
    private var knownCredits: [FilmCredit] {
        model.tiles.sorted { $0.popularity > $1.popularity }.prefix(4).map { FilmCredit(tmdbID: 0, isSeries: $0.isSeries, title: $0.title, date: nil, popularity: $0.popularity) }
    }

    private var portrait: some View {
        let side: CGFloat = typeSize.isAccessibilitySize ? 80 : 96
        return ZStack {
            Circle().fill(ColorTokens.elevated)
            Text(String(route.name.split(separator: " ").prefix(2).compactMap(\.first))).font(.title.weight(.semibold)).foregroundStyle(.secondary)
            if let u = model.profile?.photoURL { ArtworkImage(url: u, kind: .poster, contentMode: .fill, symbol: "person.fill", showsPlaceholder: false) }
        }
        .frame(width: side, height: side).clipShape(Circle()).accessibilityHidden(true)
    }

    // MARK: controls

    private var controls: some View {
        let loading = model.phase == .loading
        let a = loading ? Filmography.Arranged(shown: [], allCount: 0, libraryCount: 0) : model.arranged
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                scopeButton("All films", count: loading ? nil : a.allCount, scope: .all)
                scopeButton("In your library", count: loading ? nil : a.libraryCount, scope: .library)
            }
            .padding(3).background(ColorTokens.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous)).fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: false)
            .padding(2).overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(scopeFocus ? ColorTokens.accent : .clear, lineWidth: 2))
            .focusable().focused($scopeFocus).focusEffectDisabled()
            .onKeyPress(.leftArrow) { model.scope = .all; return .handled }
            .onKeyPress(.rightArrow) { model.scope = .library; return .handled }
            .accessibilityElement(children: .contain)
            HStack(spacing: 14) {
                Menu {
                    Picker("Sort", selection: $model.sort) { ForEach(FilmSort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                } label: { Label("Sort: " + model.sort.rawValue, systemImage: "arrow.up.arrow.down") }.buttonStyle(.plain).font(.subheadline).fixedSize().atlas("screen.person")
                Picker("Type", selection: $model.kind) { ForEach(FilmKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 240)
                    .accessibilityLabel("Movies or series")
                Toggle("Acting only", isOn: $model.actingOnly).toggleStyle(.button).font(.subheadline).accessibilityHint("Hides voice, narration and cameo credits").atlas("screen.person")
            }
        }
    }

    private func scopeButton(_ title: String, count: Int?, scope: FilmScope) -> some View {
        let on = model.scope == scope
        return Button { model.scope = scope } label: {
            Text(count.map { "\(title) (\($0))" } ?? title).font(.subheadline.weight(on ? .semibold : .regular)).lineLimit(1).padding(.horizontal, 14).padding(.vertical, 7).frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil)
                .background(on ? ColorTokens.elevated : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(on ? Color.primary : Color.secondary).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)\(count.map { ", \($0)" } ?? "")\(on ? ", selected" : "")")
        .accessibilityAddTraits(on ? .isSelected : []).atlas("screen.person")
    }

    // MARK: grid

    @ViewBuilder private var content: some View {
        if model.phase == .loading { skeleton }
        else {
            let a = model.arranged
            if a.shown.isEmpty { empty }
            else {
                if !a.onScreen.isEmpty {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) { ForEach(a.onScreen) { t in tile(t) } }
                }
                if !a.voiceAndCameo.isEmpty {
                    Text("Voice and cameo credits").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.top, a.onScreen.isEmpty ? 0 : 8).accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) { ForEach(a.voiceAndCameo) { t in tile(t) } }
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "film.stack").font(.largeTitle).foregroundStyle(.tertiary)
            Text(model.scope == .library || model.localOnly ? "None of \(route.name)'s films are in your library yet." : "No films found.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if model.failed { Button("Retry") { Task { if let c = container { await model.load(route, container: c) } } }.buttonStyle(.plain).foregroundStyle(.tint).font(.callout.weight(.semibold)).atlas("screen.person") }
            if model.scope == .library && !model.localOnly { Button("Show all films") { model.scope = .all }.buttonStyle(.plain).foregroundStyle(.tint).font(.callout.weight(.semibold)).atlas("screen.person") }
        }.frame(maxWidth: .infinity).padding(.vertical, 24)
    }

    private var skeleton: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
            ForEach(0..<12, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ColorTokens.card).aspectRatio(2.0 / 3.0, contentMode: .fit)
                    RoundedRectangle(cornerRadius: 3).fill(ColorTokens.card).frame(height: 10)
                    RoundedRectangle(cornerRadius: 3).fill(ColorTokens.card).frame(width: 60, height: 8)
                }
            }
        }.redacted(reason: .placeholder).accessibilityLabel("Loading films")
    }

    @ViewBuilder private func tile(_ t: FilmTile) -> some View {
        if let item = t.item {
            #if os(iOS)
            NavigationLink(value: item) { FilmTileView(tile: t) }.buttonStyle(.plain)
                .accessibilityLabel(t.accessibilityText).accessibilityAddTraits(.isButton)
                .titleTileMenu(item).expressArtwork(item).atlas("screen.person")
            #else
            Button { open(item) } label: { FilmTileView(tile: t) }.buttonStyle(.plain)
                .accessibilityLabel(t.accessibilityText).accessibilityHint("Opens the title")
                .macTileMenu(item).expressArtwork(item).atlas("screen.person")
            #endif
        } else {
            Button { info = t } label: { FilmTileView(tile: t) }.buttonStyle(.plain)
                .accessibilityLabel(t.accessibilityText).accessibilityHint("Shows details").atlas("screen.person")
        }
    }
}

private struct PhotoRoute: Identifiable { let path: String; var id: String { path } }

/// The film info and the enlarged photo. On the Mac they are panels inside the same window (never a second sheet over the title's sheet); on iPhone and iPad, ordinary sheets.
private struct PersonOverlays: ViewModifier {
    @Binding var info: FilmTile?
    @Binding var photo: String?

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .overlay { if let t = info { panel(dismiss: { info = nil }) { FilmInfoSheet(tile: t) { info = nil } } } }
            .overlay { if let p = photo { panel(dismiss: { photo = nil }) { photoView(p) } } }
        #else
        content
            .sheet(item: $info) { FilmInfoSheet(tile: $0) { info = nil } }
            .sheet(item: Binding(get: { photo.map { PhotoRoute(path: $0) } }, set: { photo = $0?.path })) { photoView($0.path) }
        #endif
    }

    private func photoView(_ path: String) -> some View { photoView(path: path) }
    private func photoView(path: String) -> some View {
        ZStack(alignment: .topTrailing) {
            ArtworkImage(url: MetadataMatchService.imageBase + "w780" + path, kind: .poster, contentMode: .fit, symbol: "person.fill").frame(minWidth: 300, minHeight: 420)
            Button { photo = nil } label: { Image(systemName: "xmark.circle.fill").font(.title2).padding(12) }.buttonStyle(.plain).accessibilityLabel("Close").atlas("screen.person")
        }.frame(minWidth: 320, minHeight: 440)
    }

    #if os(macOS)
    private func panel<C: View>(dismiss: @escaping () -> Void, @ViewBuilder _ content: () -> C) -> some View {
        ZStack {
            Color.black.opacity(0.5).contentShape(Rectangle()).onTapGesture(perform: dismiss)
            content().background(ColorTokens.card).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)).frame(maxWidth: 540, maxHeight: 520).shadow(radius: 20)
        }
    }
    #endif
}

/// One poster with its quiet lines and the in-library label.
struct FilmTileView: View {
    let tile: FilmTile
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ArtworkImage(url: tile.posterURL, kind: .poster, contentMode: .fill, tile: .init(title: tile.title, detail: tile.year.map(String.init), showsTitle: false))
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(hovering ? Color.white.opacity(0.28) : ColorTokens.line, lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    if let tag = tile.tag { Text(tag.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.5).padding(.horizontal, 6).padding(.vertical, 3).background(.black.opacity(0.72), in: Capsule()).foregroundStyle(.white).padding(6) }
                }
                .overlay(alignment: .topTrailing) { if let r = tile.rating { RatingBadge(value: r).padding(6) } }
                .opacity(tile.inLibrary ? 1 : 0.82)
                .scaleEffect(hovering && !reduceMotion ? 1.03 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering)
            Text(tile.title).font(.caption.weight(.medium)).lineLimit(2, reservesSpace: true).padding(.top, 7)
            Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1).padding(.top, 2)
            if let r = tile.role, tile.tag == nil { Text("as " + r).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
            label.padding(.top, 3)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
    }

    private var sub: String {
        [tile.year.map(String.init), tile.isSeries ? "Series" : nil].compactMap { $0 }.joined(separator: " · ")          // the rating is the star badge on the poster
    }

    @ViewBuilder private var label: some View {
        if tile.inLibrary {
            Label(tile.versions > 1 ? "In your library · \(tile.versions)" : "In your library", systemImage: "checkmark.circle.fill").font(.caption2.weight(.semibold)).foregroundStyle(accent).lineLimit(1)
        } else {
            Text("Not in your library").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
    }
}

/// A film that is not in the library: what TMDB says, nothing to play.
struct FilmInfoSheet: View {
    let tile: FilmTile
    let close: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    ArtworkImage(url: tile.posterURL, kind: .poster, contentMode: .fill, tile: .init(title: tile.title, detail: tile.year.map(String.init), showsTitle: false))
                        .frame(width: 120, height: 180).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tile.title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                        HStack(spacing: 8) {
                            Text([tile.year.map(String.init), tile.isSeries ? "Series" : "Film"].compactMap { $0 }.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
                            if let r = tile.rating { RatingBadge(value: r) }
                        }
                        if let r = tile.role { Text("As " + r).font(.subheadline).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                }
                if let o = tile.overview { Text(o).font(.callout).fixedSize(horizontal: false, vertical: true) }
                Text("Not in your library").font(.footnote).foregroundStyle(.tertiary)
                Button("Close", action: close).keyboardShortcut(.cancelAction)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 320, minHeight: 320)
        .presentationDetents([.medium, .large])
    }
}
