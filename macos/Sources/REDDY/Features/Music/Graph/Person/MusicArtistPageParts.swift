import SwiftUI
import Observation

/// What the artist pills share: the chosen pill, the filters, the year the timeline scoped the lists to, and the personal stats. One observable object, so typing in the
/// song search redraws the song list and nothing else of the page.
@MainActor @Observable
final class MusicArtistPageState {
    var pill: MusicArtistPill = .overview
    var songs = MusicArtistSongFilter()
    var year: Int?
    var albumType: MusicAlbumType?
    var albumDecade: Int?
    var albumGrid = true
    var filmLanguage: String?
    var filmDecade: Int?
    var filmFilter = MusicArtistFilmFilter()
    var listening: MusicArtistListeningStats?
    /// Plays and likes on this Mac for the Songs list's sort and filter; empty until the history has been read.
    var personal = MusicArtistPersonal.empty
    /// The provider ids of the catalog's recordings, read once from the graph (personal stats match by them).
    @ObservationIgnored var songUIDs: [MusicEntityID: [String]] = [:]

    init() {}

    /// The page as the person left it (Back from an opened song lands on the same pill and filters).
    init(restoring s: MusicArtistPageSnapshot) {
        pill = s.pill; year = s.year; albumType = s.albumType; albumDecade = s.albumDecade
        songs.language = s.songLanguage; songs.decade = s.songDecade; songs.sort = s.songSort; songs.performance = s.songPerformance
        songs.yearFrom = s.yearFrom; songs.yearTo = s.yearTo; songs.likedOnly = s.likedOnly
        filmLanguage = s.filmLanguage; filmDecade = s.filmDecade; filmFilter = MusicArtistFilmFilter(role: s.filmRole, withSoundtrack: s.filmSoundtrack, director: s.filmDirector, genre: s.filmGenre)
    }

    /// What page memory keeps; it changes exactly when something worth restoring does.
    var snapshot: MusicArtistPageSnapshot {
        MusicArtistPageSnapshot(pill: pill, songLanguage: songs.language, songDecade: songs.decade, songSort: songs.sort, songPerformance: songs.performance,
                                yearFrom: songs.yearFrom, yearTo: songs.yearTo, likedOnly: songs.likedOnly, year: year, albumType: albumType, albumDecade: albumDecade,
                                filmLanguage: filmLanguage, filmDecade: filmDecade, filmRole: filmFilter.role, filmSoundtrack: filmFilter.withSoundtrack,
                                filmDirector: filmFilter.director, filmGenre: filmFilter.genre)
    }

    /// A role switch starts the pills again: their lists belong to the role.
    func reset() {
        pill = .overview; songs = MusicArtistSongFilter(); year = nil
        albumType = nil; albumDecade = nil; filmLanguage = nil; filmDecade = nil; filmFilter = MusicArtistFilmFilter()
    }

    /// The Songs pill's "Clear filters": every filter, the search words and the timeline year go; the chosen sort stays.
    func clearSongFilters() { let sort = songs.sort; songs = MusicArtistSongFilter(); songs.sort = sort; year = nil }
    func clearAlbumFilters() { albumType = nil; albumDecade = nil; year = nil }
    func clearFilmFilters() { filmLanguage = nil; filmDecade = nil; filmFilter = MusicArtistFilmFilter(); year = nil }

    func openSongs(_ filter: MusicArtistSongFilter) { songs = filter; year = nil; pill = .songs }
}

/// Every sentence of the artist pills, in one place.
enum MusicArtistWording {
    static func pillTitle(_ p: MusicArtistPill, view: MusicPersonView) -> String {
        switch p {
        case .overview: Localized.string("Overview")
        case .songs: songsTitle(view)
        case .albums: Localized.string("Albums")
        case .films: Localized.string("Films")
        case .collaborators: Localized.string("Collaborators")
        case .timeline: Localized.string("Timeline")
        case .listening: Localized.string("Your listening")
        case .about: Localized.string("About")
        }
    }

    /// A composer has compositions, a lyricist songs written, an actor the songs of their films: never "songs" they did not make.
    static func songsTitle(_ view: MusicPersonView) -> String {
        switch view {
        case .composer: Localized.string("Compositions")
        case .lyricist: Localized.string("Songs written")
        case .actor: Localized.string("Songs from their films")
        default: Localized.string("Songs")
        }
    }

    static func albumTypeTitle(_ t: MusicAlbumType) -> String {
        switch t {
        case .album: Localized.string("Albums")
        case .soundtrack: Localized.string("Soundtracks")
        case .single: Localized.string("Singles & EPs")
        case .compilation: Localized.string("Compilations")
        case .score: Localized.string("Scores")
        }
    }

    static func sortTitle(_ s: MusicArtistSongSort) -> String {
        switch s {
        case .title: Localized.string("Title")
        case .newest: Localized.string("Newest first")
        case .oldest: Localized.string("Oldest first")
        case .duration: Localized.string("Longest first")
        case .mostPlayed: Localized.string("Most played by you")
        }
    }

    static func radioTitle(_ m: MusicArtistRadioMode) -> String {
        switch m {
        case .essentials: Localized.string("Artist essentials")
        case .deepCuts: Localized.string("Deep cuts")
        case .catalog: Localized.string("Complete catalog shuffle")
        case .language(let c): Localized.string("In %1$@", MusicPersonReader.languageName(c))
        case .decade(let d): Localized.string("From the %ds", d)
        case .filmMusic: Localized.string("Film music")
        case .recent: Localized.string("Recent songs")
        case .performance(let k): performanceTitle(k)
        case .liked: Localized.string("Songs you liked")
        case .unplayed: Localized.string("Not played yet")
        }
    }

    static func performanceTitle(_ k: MusicSongPerformance) -> String {
        switch k {
        case .live: Localized.string("Live")
        case .acoustic: Localized.string("Acoustic")
        case .remix: Localized.string("Remixes")
        case .instrumental: Localized.string("Instrumental")
        case .featured: Localized.string("Featured appearances")
        }
    }

    /// The credit a song row names when it is not the page's main one: a featured appearance, a remix, an arrangement, words. Nil for the main credit.
    static func songRole(_ e: MusicPersonEntry) -> String? {
        switch e.roles.first {
        case .featured: Localized.string("Featured")
        case .remixer: Localized.string("Remixer")
        case .arranger: Localized.string("Arranger")
        case .writer: Localized.string("Writer")
        default: nil
        }
    }

    static func milestoneTitle(_ m: MusicArtistMilestone) -> String {
        switch m.kind {
        case .careerStart: Localized.string("Career begins")
        case .earliestSong: Localized.string("Earliest song found")
        case .earliestAlbum: Localized.string("Earliest album found")
        case .earliestFilm: Localized.string("Earliest film found")
        case .award: Localized.string("Award")
        case .latestRelease: Localized.string("Latest release")
        case .newLanguage: Localized.string("First work in another language")
        }
    }

    static func industryLabel(_ code: String) -> String {
        let lang = MusicPersonReader.languageName(code)
        return MusicCombineRules.industry(forLanguage: code).map { lang + " · " + Localized.string($0) } ?? lang
    }

    static func count(songs n: Int) -> String { Localized.plural(n, one: "%@ song", other: "%@ songs") }
    static func count(albums n: Int) -> String { Localized.plural(n, one: "%@ album", other: "%@ albums") }
    static func count(films n: Int) -> String { Localized.plural(n, one: "%@ film", other: "%@ films") }
    static func count(collaborators n: Int) -> String { Localized.plural(n, one: "%@ collaborator", other: "%@ collaborators") }
    static func count(languages n: Int) -> String { Localized.plural(n, one: "%@ language", other: "%@ languages") }

    /// The line under the name: the years the catalog covers, the languages and the counts, all from loaded data. Empty parts are left out.
    static func headerLine(_ s: MusicArtistStats, country: String?, active: (from: Int, to: Int?)? = nil) -> String {
        var parts: [String] = []
        // The years the person was really active, when Wikidata states them; else the span of the credits the catalog holds.
        if let a = active { parts.append(a.to.map { $0 == a.from ? Localized.string("Active %1$@", "\(a.from)") : Localized.string("Active %1$@", "\(a.from)–\($0)") } ?? Localized.string("Active since %1$@", "\(a.from)")) }
        else if let r = s.span, r.lowerBound != r.upperBound { parts.append(Localized.string("Credits %1$@", "\(r.lowerBound)–\(r.upperBound)")) }
        if let c = country, !c.isEmpty { parts.append(Locale(identifier: Localized.activeCode).localizedString(forRegionCode: c) ?? c) }
        if !s.languages.isEmpty { parts.append(count(languages: s.languages.count)) }
        if s.songs > 0 { parts.append(count(songs: s.songs)) }
        if s.albums > 0 { parts.append(count(albums: s.albums)) }
        if s.films > 0 { parts.append(count(films: s.films)) }
        return parts.joined(separator: " · ")
    }

    static func duration(ms: Int64) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = ms >= 86_400_000 ? [.day, .hour] : [.hour, .minute]
        f.unitsStyle = .abbreviated; f.maximumUnitCount = 2
        return f.string(from: TimeInterval(ms) / 1000) ?? "0"
    }
}

/// The pill row under the header. Only pills with content are passed in.
struct MusicArtistPillBar: View {
    let pills: [MusicArtistPill]
    let view: MusicPersonView
    let state: MusicArtistPageState
    /// The pill whose content is shown now: the saved pill when it is available, else Overview.
    let active: MusicArtistPill

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MusicSpace.xs) {
                ForEach(pills, id: \.self) { p in
                    MusicChip(title: MusicArtistWording.pillTitle(p, view: view), selected: active == p) { state.pill = p }
                        .atlas("control.music.artistPill")
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityElement(children: .contain)
    }
}

/// "Year 1994" chip that clears the timeline's scope on the lists it filtered.
struct MusicArtistYearChip: View {
    let state: MusicArtistPageState
    var body: some View {
        if let y = state.year {
            MusicChip(title: Localized.string("Year %d", y), selected: true) { state.year = nil }
                .accessibilityLabel(Localized.string("Clear the year %d", y)).atlas("control.music.artistYearClear")
        }
    }
}

/// Explore by language and decade on the Overview: each chip opens the Songs pill already filtered. (The singer's Languages chips do the same, so languages are
/// offered here only when that section is not on the page.)
struct MusicArtistExploreRow: View {
    let options: MusicArtistExplore.Options
    let state: MusicArtistPageState

    var body: some View {
        if !options.isEmpty {
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                MusicSectionTitle(title: Localized.string("Explore songs by"))
                MusicChipFlow(spacing: MusicSpace.xs) {
                    ForEach(Array(options.languages.enumerated()), id: \.offset) { _, l in
                        MusicChip(title: MusicArtistWording.industryLabel(l.code) + " · \(l.count)", selected: false) {
                            var f = MusicArtistSongFilter(); f.language = l.code; state.openSongs(f)
                        }.atlas("control.music.artistExplore")
                    }
                    ForEach(Array(options.decades.enumerated()), id: \.offset) { _, d in
                        MusicChip(title: MusicPersonWording.filterDecade(d.decade) + " · \(d.count)", selected: false) {
                            var f = MusicArtistSongFilter(); f.decade = d.decade; state.openSongs(f)
                        }.atlas("control.music.artistExplore")
                    }
                }
            }
        }
    }
}

/// The newest release of the catalog, up front on the Overview. Derived from the release years the catalog holds; nothing is shown when none states a year, and
/// never for an actor or director (a soundtrack of their film is not their release).
struct MusicArtistLatestRelease: View {
    let hub: MusicHub
    let catalog: MusicArtistCatalog
    @Environment(\.musicLayoutClass) private var layoutClass

    var body: some View {
        if catalog.view != .actor, catalog.view != .director, let a = MusicArtistSpotlight.latest(catalog) {
            let e = a.entry
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                MusicSectionTitle(title: Localized.string("Latest release"))
                MusicGraphAlbumCard(title: e.name, subtitle: [Self.typeName(a.type), e.year.map(String.init)].compactMap { $0 }.joined(separator: " · "),
                                    imageRef: MusicPersonImage.address(e.imageRef), reason: MusicPersonWording.reason(e.reason),
                                    tag: MusicGraphTag(status: e.status ?? .verified, level: .film, forFilmLink: e.filmID != nil), width: MusicGraphCardWidth.width(for: layoutClass), entity: e.id) { hub.open(e.id) }
            }
        }
    }

    static func typeName(_ t: MusicAlbumType) -> String {
        switch t {
        case .album: Localized.string("Album")
        case .soundtrack: Localized.string("Soundtrack")
        case .single: Localized.string("Single")
        case .compilation: Localized.string("Compilation")
        case .score: Localized.string("Score")
        }
    }
}

enum MusicArtistChipRules {
    /// A filter chip is offered when it has a real choice (more than `above` options) or when it holds a value: a filter that is applied (restored from page memory, or set
    /// while the catalog was still filling) must always have its control on screen to clear it.
    static func offered(_ options: Int, above: Int = 1, selected: Bool) -> Bool { options > above || selected }
}
