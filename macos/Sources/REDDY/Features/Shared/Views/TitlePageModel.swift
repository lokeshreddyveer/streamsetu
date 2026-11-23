import SwiftUI
import os

/// What the Mac title page shows and when. Everything the page needs is gathered here in stages that never block each other:
/// the library row is on screen at once; the saved TMDB details come from the database (not the network) a moment later; the provider's
/// extras and a refresh of stale details arrive last and replace what is shown without moving anything. Views read the finished `info`,
/// built once per change, never rebuilt in a view body.
@MainActor @Observable final class TitlePageModel {
    /// The facts the page prints, derived once from the library row and the saved details.
    struct Info {
        var chips: [TitlePageLogic.Chip] = []
        var chipsSpoken = ""
        var rating: Double?
        var genreLine: String?
        var story: String?
        var tagline: String?
        var rows: [DetailRow] = []
        var cast: [CastEntry] = []
        var hasPeopleRow = false
    }

    struct CastEntry: Identifiable, Equatable {
        let name: String
        let role: String?
        let photo: String?
        let route: PersonRoute
        var id: String { route.id + (role ?? "") }
    }

    let facts = TitleFactsModel()
    let versions = TitleVersionsModel()
    private(set) var info = Info()
    /// The saved details have been read (they may have been empty). Until then, sections that depend on them show quiet placeholders of their own size.
    private(set) var detailsRead = false
    /// Every stage finished, including the provider's extras: a section still empty now really has nothing.
    private(set) var settled = false
    /// The other versions have been looked for.
    private(set) var versionsRead = false
    /// Enough is known to show the whole body in one go.
    var bodyReady: Bool { detailsRead && versionsRead }
    private(set) var progress: WatchProgress?
    private(set) var item: LibraryItem?
    private var seasons: Int?
    private var hasKey = false

    nonisolated static let signposter = OSSignposter(subsystem: "app.streamsetu.mac", category: "TitlePage")

    /// Points the model at the (possibly refreshed) library row and rebuilds `info`.
    func update(_ item: LibraryItem, seasons: Int? = nil) {
        self.item = item
        if let seasons { self.seasons = seasons }
        rebuild()
    }

    func reloadProgress(_ c: AppContainer?) {
        guard let c, let id = item?.id else { return }
        progress = try? c.historyRepo.progress(for: id)
    }

    func load(_ item: LibraryItem, container c: AppContainer?) async {
        let sp = Self.signposter, sid = sp.makeSignpostID(), whole = sp.beginInterval("load", id: sid)
        defer { sp.endInterval("load", whole) }
        let open = SmoothSignpost.begin("TitleOpen"); defer { SmoothSignpost.end(open, "TitleOpen") }
        update(item)
        guard let c else { detailsRead = true; versionsRead = true; settled = true; return }
        hasKey = c.metadata.hasKey
        let cand = MetadataMatchService.Candidate(id: item.id, isSeries: item.isSeries, title: item.title, year: item.year)
        async let saved: Void = loadSaved(c, cand)
        async let extras: Void = loadExtras(c, item)
        async let other: Void = loadVersions(c, item)
        _ = await (saved, extras, other)
        settled = true
    }

    /// Saved details, no network (any age): the cast, runtime, age rating and story appear at once. Then a refresh when they are stale.
    private func loadSaved(_ c: AppContainer, _ cand: MetadataMatchService.Candidate) async {
        let sp = Self.signposter, sid = sp.makeSignpostID(), st = sp.beginInterval("savedDetails", id: sid)
        facts.tmdb = await c.metadata.details(for: cand, maxAge: .infinity)
        sp.endInterval("savedDetails", st)
        detailsRead = true; rebuild()
        let fresh = await c.metadata.details(for: cand)
        if let fresh, fresh != facts.tmdb { facts.tmdb = fresh; rebuild() }
    }

    /// The provider's extras (director, country, cast names): a network call that may be slow or fail; it never holds anything else.
    private func loadExtras(_ c: AppContainer, _ item: LibraryItem) async {
        let sp = Self.signposter, sid = sp.makeSignpostID(), st = sp.beginInterval("providerExtras", id: sid)
        facts.extras = item.isSeries ? await c.details.extras(series: item.id) : await c.details.extras(movie: item.id)
        sp.endInterval("providerExtras", st)
        rebuild()
    }

    private func loadVersions(_ c: AppContainer, _ item: LibraryItem) async {
        await versions.load(item, container: c)
        versionsRead = true
    }

    private func rebuild() {
        guard let item else { return }
        var i = Info()
        let year = item.year ?? facts.tmdb?.year
        let runtime = (item.durationSeconds.flatMap { $0 > 0 ? $0 : nil }) ?? facts.runtimeSeconds
        let quality = TitlePage.quality([item.title, item.categoryName, item.genre])
        i.chips = TitlePageLogic.chips(year: year, runtimeSeconds: runtime, age: facts.age, quality: quality, seasons: item.isSeries ? seasons : nil)
        i.rating = facts.rating(for: item)
        i.chipsSpoken = TitlePageLogic.chipsSpoken(i.chips, rating: i.rating, runtimeSeconds: runtime)
        let own = ProviderExtras.names(item.genre)
        i.genreLine = TitlePageLogic.genreLine(own.isEmpty ? facts.genres : own)
        i.story = facts.story
        i.tagline = facts.tmdb?.tagline?.nilIfEmpty
        i.rows = facts.detailRows(for: item) {}
        i.hasPeopleRow = i.rows.contains { if case .people = $0.value { true } else { false } }
        i.cast = castEntries(item)
        info = i
    }

    private func castEntries(_ item: LibraryItem) -> [CastEntry] {
        func route(_ name: String, _ id: Int?) -> PersonRoute { PersonRoute(name: name, tmdbID: id, fromTitle: item.title, fromYear: item.year) }
        if let people = facts.tmdb?.cast, !people.isEmpty {
            return people.prefix(14).map { CastEntry(name: $0.name, role: $0.role, photo: TitlePageLogic.photoURL($0, hasKey: hasKey), route: route($0.name, $0.tmdbID)) }
        }
        return facts.castNames.prefix(12).map { CastEntry(name: $0, role: nil, photo: nil, route: route($0, nil)) }
    }
}

// MARK: hero artwork

/// The pictures of the hero, loaded off the main thread, and the colour taken from them. A title opened before shows at once from memory;
/// a new one fades in over a placeholder wash that already has the title's own colour, so nothing pops.
@MainActor @Observable final class HeroArtwork {
    private(set) var backdrop: CGImage?
    private(set) var poster: CGImage?
    private(set) var wash: TitlePalette.RGB?

    private struct Entry { let image: CGImage?; let wash: TitlePalette.RGB? }
    private static let memory: NSCache<NSString, Box> = { let c = NSCache<NSString, Box>(); c.countLimit = Retention.heroPictureCount; return c }()
    private final class Box { let image: CGImage; let wash: TitlePalette.RGB?; init(_ i: CGImage, _ w: TitlePalette.RGB?) { image = i; wash = w } }

    static func preloaded(backdrop: String?, poster: String?) -> HeroArtwork { let a = HeroArtwork(); a.peek(backdrop: backdrop, poster: poster); return a }

    /// Whatever is already in memory, synchronously, so a reopened title has its picture in the very first frame.
    func peek(backdrop b: String?, poster p: String?) {
        if backdrop == nil, let b, let hit = Self.memory.object(forKey: b as NSString) { backdrop = hit.image }
        if poster == nil, let p, let hit = Self.memory.object(forKey: p as NSString) { poster = hit.image; wash = hit.wash }
    }

    func load(backdrop b: String?, poster p: String?, artwork: ArtworkService?) async {
        guard let artwork else { return }
        let sp = TitlePageModel.signposter, sid = sp.makeSignpostID(), st = sp.beginInterval("heroArtwork", id: sid)
        defer { sp.endInterval("heroArtwork", st) }
        async let pi = fetch(p, kind: .poster, artwork)
        async let bi = fetch(b, kind: .backdrop, artwork)
        let (pe, be) = await (pi, bi)
        if Task.isCancelled { return }
        if let pe { poster = pe.image; wash = pe.wash ?? wash }
        if let be { backdrop = be.image; wash = be.wash ?? wash }
    }

    private func fetch(_ url: String?, kind: ArtworkKind, _ artwork: ArtworkService) async -> Entry? {
        guard let url = url.nilIfEmpty else { return nil }
        if let hit = Self.memory.object(forKey: url as NSString) { return Entry(image: hit.image, wash: hit.wash) }
        guard let img = await artwork.image(url, kind: kind) else { return nil }
        let wash = await Task.detached(priority: .userInitiated) { TitlePalette.dominant(of: img) }.value
        Self.memory.setObject(Box(img, wash), forKey: url as NSString)
        return Entry(image: img, wash: wash)
    }
}
