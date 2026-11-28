import SwiftUI

/// Recently Added: only what the person chose. New albums from the artists they follow or picked in setup, songs in the languages and genres they picked, and what they saved lately
/// (the dated list of everything they added). Nothing from Listen Now's recommender is used and there are no charts: with no choices made, it says so and offers the setup. Each shelf
/// appears as soon as its answer arrives; leaving the page stops the rest. Only the albums carry a release date (and only a recent one counts as new); the song shelves are what the
/// source returns for the person's languages and genres, so they are titled that way and are never called new.
struct MusicRecentlyAddedPage: View {
    @Bindable var hub: MusicHub
    @State private var releases: [MusicAlbum] = []
    /// Albums whose source gives only a year (YouTube Music, Subsonic): this year's are shown under their own honest title, never as "new".
    @State private var yearReleases: [MusicAlbum] = []
    @State private var languageShelves: [MusicBrowseSection] = []
    @State private var genreShelves: [MusicBrowseSection] = []
    @State private var loading = true
    /// True after the first load has finished: the "Found today / this week / this month" shelves stay through the reloads that a follow or a source change causes (they would vanish and come back).
    @State private var bucketsReady = false
    /// What earlier visits had shown, read once for this visit. It is the only log the page groups by: what this visit shows is written to disk for the next visit
    /// and never put in here, or everything just drawn would jump into "Found today".
    @State private var firstSeen = MusicFirstSeenLog()
    @State private var firstSeenRead = false
    @State private var generation = 0
    @State private var prefs = MusicTastePreferences.shared
    /// True when the person came from Library's "Recently added" link: the dated list of what they saved leads, so that is what they see first.
    /// Read from the hub on every draw, so the first frame already has the order the Library link asked for.
    private var libraryFirst: Bool { hub.recentlyAddedLeadsWithLibrary }

    /// Choices that can drive a shelf: languages, genres, artists or followed artists. Dislikes alone do not make a shelf.
    private var hasChoices: Bool {
        let p = prefs.prefs
        return !p.languages.isEmpty || !p.genres.isEmpty || !p.artists.isEmpty || !hub.library.followedArtists.isEmpty
    }
    private var signature: String {
        let p = prefs.prefs
        return "\(p.languages.sorted())|\(p.genres.sorted())|\(p.lovedGenres.sorted())|\(p.dislikedGenres.sorted())|\(p.artists.map(\.uid).sorted())|\(hub.library.followedRevision)|\(hub.library.blacklist.count)|\(hub.gated)|\(hub.registry.enabled.sorted())|\(hub.registry.activeMetadata?.id ?? "")"
    }

    private struct Shelf: Identifiable { var id: String; var title: String; var items: [MusicBrowseItem] }

    /// What is drawn, worked out once per pass: items Music already showed on an earlier visit are grouped by when it first saw them (once loading is done, so nothing shifts), and
    /// every other shelf follows. No item appears twice, and a shelf with fewer than three items is not drawn (its items stay available to the next shelf).
    private var layout: [Shelf] {
        var used = Set<String>()
        var out: [Shelf] = []
        func add(_ id: String, _ title: String, _ items: [MusicBrowseItem], min: Int = 3) {
            var seen = Set<String>()
            let fresh = items.filter { let k = MusicFirstSeenLog.key($0); return !used.contains(k) && seen.insert(k).inserted }
            guard fresh.count >= min else { return }
            let shown = Array(fresh.prefix(16))
            for i in shown { used.insert(MusicFirstSeenLog.key(i)) }
            out.append(Shelf(id: id, title: title, items: shown))
        }
        let now = Date()
        let all = (languageShelves + genreShelves).flatMap(\.items)   // albums keep their own shelf and are not grouped by first-seen
        add("releases", Localized.string("Latest releases from your artists"), releases.map { .album($0) }, min: 1)   // one new album from one followed artist is worth showing
        add("yearReleases", Localized.string("More from your artists this year"), yearReleases.map { .album($0) }, min: 1)
        if bucketsReady {
            for b in [MusicFirstSeenLog.Bucket.today, .thisWeek, .thisMonth] { add("bucket-\(b.rawValue)", bucketTitle(b), all.filter { if case .album = $0 { return false }; return firstSeen.bucket($0, now: now) == b }) }
        }
        for s in languageShelves + genreShelves { add(s.id, s.title, s.items) }
        return out
    }

    var body: some View {
        let shelves = layout
        MusicOverlayHostView(hub: hub) {
            MusicPageColumn(spacing: MusicSpace.xl, memoryKey: "music.recentlyAdded") {
                VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                    Text(Localized.string("Recently Added")).font(Typography.pageTitle).accessibilityAddTraits(.isHeader)
                    Text(Localized.string("The latest releases from your artists, languages and genres, and what you saved.")).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
                }
                if libraryFirst { libraryBlock }
                if !hasChoices {
                    MusicEmptyState(symbol: "sparkles", title: Localized.string("Tell Music what you like"),
                                    message: Localized.string("Pick your languages, genres and artists, and what is new in them shows up here."),
                                    actionTitle: Localized.string("Set up")) { MusicChromeState.shared.setupOpen = true }
                } else {
                    if loading && shelves.isEmpty { MusicShelfSkeleton(count: 5) }
                    ForEach(shelves) { s in
                        MusicShelf(title: s.title) { ForEach(s.items, id: \.self) { MusicCard(result: $0, queue: s.items.compactMap { if case .track(let t) = $0 { t } else { nil } }, hub: hub) } }
                    }
                    if !loading && shelves.isEmpty {
                        MusicEmptyState(symbol: "sparkles", title: Localized.string("Nothing new yet"),
                                        message: hub.gated ? Localized.string("Music is not online right now.") : hub.registry.activeMetadata == nil ? Localized.string("No music source is switched on.") : Localized.string("Nothing new turned up for your choices. Check back soon, or change them in Settings."),
                                        actionTitle: hub.gated ? nil : Localized.string("Change choices")) { MusicChromeState.shared.setupOpen = true }
                    }
                }
                if !libraryFirst { libraryBlock }
            }
        }
        .task(id: signature) { await load() }
    }

    private var libraryBlock: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            MusicSectionTitle(title: Localized.string("Added to your library"))
            MusicRecentlyAddedView(hub: hub)
        }
    }

    private func bucketTitle(_ b: MusicFirstSeenLog.Bucket) -> String {
        switch b {
        case .today: Localized.string("New to you today")   // what an earlier visit today already showed
        case .thisWeek: Localized.string("New to you this week")
        case .thisMonth: Localized.string("New to you this month")
        }
    }

    /// A release counts as new when its date says so: a full date in the last 28 days, or a year and month whose days reach into the last 28 days (and has begun). A bare year, no date,
    /// or a date that is not a real calendar date says nothing, so it is not "new".
    nonisolated static func isRecent(_ releaseDate: String?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let s = releaseDate else { return false }
        let parts = s.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count >= 2, (1...12).contains(parts[1]) else { return false }
        let from = now.addingTimeInterval(-28 * 86_400)
        var c = DateComponents(); c.year = parts[0]; c.month = parts[1]; c.day = parts.count >= 3 ? parts[2] : 1
        guard let start = calendar.date(from: c), calendar.dateComponents([.month, .day], from: start).month == parts[1] else { return false }
        if parts.count >= 3 {
            guard calendar.component(.day, from: start) == parts[2] else { return false }
            return start <= now.addingTimeInterval(86_400) && start >= from
        }
        guard let end = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: start) else { return false }
        return start <= now && end >= from
    }

    /// A date that is only a year, and is this year (or last year in January and February, when the year has barely begun).
    nonisolated static func isThisYear(_ releaseDate: String?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let s = releaseDate, s.count == 4, let y = Int(s) else { return false }
        let n = calendar.dateComponents([.year, .month], from: now)
        guard let year = n.year, let month = n.month else { return false }
        return y == year || (month <= 2 && y == year - 1)
    }

    /// A full or year-and-month date inside this year that is not recent: it still belongs under "this year", whatever form the source gives its dates in.
    nonisolated static func isEarlierThisYear(_ releaseDate: String?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let s = releaseDate, s.count >= 7, let y = Int(s.prefix(4)), y == calendar.component(.year, from: now) else { return false }
        // Only what has already come out: a date after today (an announced album) is not "from your artists this year".
        let parts = s.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count >= 2 else { return false }
        var c = DateComponents(); c.year = parts[0]; c.month = parts[1]; c.day = parts.count >= 3 ? parts[2] : 1
        guard let start = calendar.date(from: c) else { return false }
        return start <= now.addingTimeInterval(86_400)
    }

    /// True for a date after tomorrow (a pre-order, an announced album); an unreadable date is not in the future.
    nonisolated static func isFuture(_ releaseDate: String?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let s = releaseDate else { return false }
        let parts = s.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard let y = parts.first else { return false }
        var c = DateComponents(); c.year = y; c.month = parts.count >= 2 ? parts[1] : 1; c.day = parts.count >= 3 ? parts[2] : 1
        guard let start = calendar.date(from: c) else { return false }
        return start > now.addingTimeInterval(86_400)
    }

    /// An artist's newest album that is already out and has a title and a cover. A pre-order never wins, so the real recent album is still found.
    nonisolated static func newestReleased(_ albums: [MusicAlbum], now: Date, calendar: Calendar = .current) -> MusicAlbum? {
        let out = albums.filter { !$0.title.isEmpty && !$0.thumbnails.isEmpty && !isFuture($0.releaseDate, now: now, calendar: calendar) }
        return out.reduce(nil as MusicAlbum?) { best, a in (best == nil || (a.releaseDate ?? "") > (best?.releaseDate ?? "")) ? a : best }
    }

    /// An artist's newest albums that are already out (up to `limit`, newest first), each with a title and a cover: a latest-releases page shows more than the single newest one.
    nonisolated static func latestReleased(_ albums: [MusicAlbum], now: Date, limit: Int, calendar: Calendar = .current) -> [MusicAlbum] {
        let out = albums.filter { !$0.title.isEmpty && !$0.thumbnails.isEmpty && !isFuture($0.releaseDate, now: now, calendar: calendar) }
        return Array(out.sorted { ($0.releaseDate ?? "") > ($1.releaseDate ?? "") }.prefix(limit))
    }

    private func load() async {
        generation += 1
        let mine = generation
        loading = true
        defer { if mine == generation { loading = false; bucketsReady = true } }
        if !firstSeenRead {
            firstSeenRead = true
            // Back from an album or artist page builds this page again: the same earlier-visit log is kept, so the shelves come back as they were left.
            firstSeen = MusicRecentlyAddedVisit.snapshot(returning: hub.nav.arrivedByReturn)
        }
        // The shelves already shown stay until the new answers arrive, so a follow or a source change does not flash the skeleton; the first load fills them as they come.
        let firstLoad = releases.isEmpty && yearReleases.isEmpty && languageShelves.isEmpty && genreShelves.isEmpty
        var newReleases: [MusicAlbum] = [], newYear: [MusicAlbum] = [], newLang: [MusicBrowseSection] = [], newGenre: [MusicBrowseSection] = []
        func publish() {
            // A reload that came back with nothing at all (offline, a timeout) keeps the shelves that were already on screen: it must not wipe them into "Nothing new yet".
            let gotNothing = newReleases.isEmpty && newYear.isEmpty && newLang.isEmpty && newGenre.isEmpty
            let hadSomething = !(releases.isEmpty && yearReleases.isEmpty && languageShelves.isEmpty && genreShelves.isEmpty)
            if gotNothing && hadSomething { return }
            releases = newReleases; yearReleases = newYear; languageShelves = newLang; genreShelves = newGenre
        }
        guard !hub.gated else { releases = []; yearReleases = []; languageShelves = []; genreShelves = []; return }
        // Picks saved by an earlier version with the wrong source are put back before they are asked about (not only when Settings is opened).
        prefs.repairArtistSources(MusicStats.shared.file, library: hub.library)
        let p = prefs.prefs
        // New albums from the artists followed or picked (one newest album each), four at a time.
        var seen = Set<String>()
        // Setup picks and followed artists take turns, so neither list starves the other when there are many; a source the person switched off is not asked.
        let followed = hub.library.followedArtists, picked = p.artists
        var mixed: [MusicArtist] = []
        for i in 0..<max(followed.count, picked.count) { if i < picked.count { mixed.append(picked[i]) }; if i < followed.count { mixed.append(followed[i]) } }
        // More followed or picked artists than fit in one visit: the window moves by the day, so each gets its turn.
        if mixed.count > 12 { let shift = (Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0) % mixed.count; mixed = Array(mixed[shift...] + mixed[..<shift]) }
        let seeds = mixed.filter { seen.insert($0.uid).inserted && hub.registry.enabled.contains($0.providerID) }.prefix(12)
        let pairs = seeds.compactMap { a in hub.registry.metadataProvider(id: a.providerID).map { (a, $0) } }
        let source = hub.registry.activeMetadata
        let langs = Array(MusicTasteBias.languages(p).prefix(3)), genres = Array(MusicTasteBias.genres(p).prefix(3))
        let blocked: (MusicTrack) -> Bool = { hub.library.isBlacklisted($0) || p.dislikesGenre($0) }
        enum Found: Sendable { case albums([MusicAlbum]), lang(MusicBrowseSection), genre(MusicBrowseSection) }
        func apply(_ r: Found?) {
            switch r {
            case .albums(let list):
                for a in list {
                    guard !a.artists.contains(where: { hub.library.isBlacklisted(artist: $0) }),
                          !(newReleases + newYear).contains(where: { $0.id == a.id && $0.providerID == a.providerID }) else { continue }
                    if Self.isRecent(a.releaseDate, now: Date()) {
                        newReleases.append(a)
                    } else if Self.isThisYear(a.releaseDate, now: Date()) || Self.isEarlierThisYear(a.releaseDate, now: Date()) {
                        newYear.append(a)
                    }
                }
                // Newest first in both lists, so the page reads as a latest-releases feed.
                newReleases.sort { ($0.releaseDate ?? "") > ($1.releaseDate ?? "") }
                newYear.sort { ($0.releaseDate ?? "") > ($1.releaseDate ?? "") }
            case .lang(let s): if let s = filtered(s, blocked) { newLang.append(s) }
            case .genre(let s): if let s = filtered(s, blocked) { newGenre.append(s) }
            case nil: break
            }
            if firstLoad { publish() }
        }
        await withTaskGroup(of: Found?.self) { group in
            var running = 0
            for (artist, prov) in pairs {
                if running >= 4 { let r = await group.next() ?? nil; if !Task.isCancelled, mine == generation { apply(r) }; running -= 1 }   // a finished answer is used, never dropped
                if Task.isCancelled || mine != generation { group.cancelAll(); return }
                group.addTask {
                    let page = try? await MusicStreamResolver.withDeadline(6) { try await prov.artistAlbums(id: artist.id, page: nil) }
                    return .albums(Self.latestReleased(page?.items ?? [], now: Date(), limit: 3))
                }
                running += 1
            }
            if let source {
                for lang in langs {
                    group.addTask {
                        let page = try? await MusicStreamResolver.withDeadline(8) { try await source.searchTracks("new \(lang.englishName) songs \(Calendar.current.component(.year, from: Date()))", page: nil) }
                        let tracks = (page?.items ?? []).filter { !$0.thumbnails.isEmpty }
                        return .lang(MusicBrowseSection(id: "songs-lang-" + lang.rawValue, title: Localized.string("Songs in %@", Localized.string(lang.englishName)), items: tracks.map { .track($0) }))
                    }
                }
                for g in genres {
                    let query = MusicTasteBias.genreQuery(g.name, prefs: p)
                    group.addTask {
                        let page = try? await MusicStreamResolver.withDeadline(8) { try await source.searchTracks(query, page: nil) }
                        let tracks = (page?.items ?? []).filter { !$0.thumbnails.isEmpty }
                        return .genre(MusicBrowseSection(id: "songs-genre-" + g.name, title: Localized.string("Songs in %@", Localized.string(g.name)), items: tracks.map { .track($0) }))
                    }
                }
            }
            for await r in group {
                if Task.isCancelled || mine != generation { group.cancelAll(); return }
                apply(r)
            }
        }
        if Task.isCancelled || mine != generation { return }
        publish()
        // Remember only what the page actually shows, so "found this week" never claims something the person was not shown.
        loading = false; bucketsReady = true
        MusicFirstSeenLog.recordShown(layout.flatMap(\.items).filter { if case .album = $0 { return false }; return true }, now: Date())   // albums are never grouped by first-seen, so they are not logged
    }

    private func filtered(_ s: MusicBrowseSection, _ blocked: (MusicTrack) -> Bool) -> MusicBrowseSection? {
        let items = s.items.filter { if case .track(let t) = $0 { !blocked(t) } else { true } }
        return items.count >= 3 ? MusicBrowseSection(id: s.id, title: s.title, items: items) : nil
    }
}

/// The first-seen log of the visit in progress, kept so that coming back to the page with Back groups it exactly as it was when it was left.
@MainActor
enum MusicRecentlyAddedVisit {
    private static var kept: MusicFirstSeenLog?

    /// A wipe forgets the visit that a Back would have returned to.
    static func forget() { kept = nil }

    /// The log to group by: the one of the visit being returned to, or a fresh read from disk for a new visit.
    static func snapshot(returning: Bool, defaults: UserDefaults = .standard) -> MusicFirstSeenLog {
        if returning, let kept { return kept }
        let log = MusicFirstSeenLog.load(defaults)
        kept = log
        return log
    }
}
