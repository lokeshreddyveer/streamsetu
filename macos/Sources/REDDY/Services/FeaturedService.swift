import Foundation

/// One slide of the Featured slideshow. Only titles with a real backdrop and a real synopsis ever become slides.
struct FeaturedSlide: Identifiable, Hashable, Sendable {
    let item: LibraryItem
    let title: String
    let year: Int?
    let genre: String?
    let durationMinutes: Int?
    /// The provider's rating, shown only when it exists and is above zero. Never invented.
    let rating: String?
    let synopsis: String
    let backdropURL: String
    let posterURL: String?
    var id: String { item.id }
}

/// Which titles may be featured, and in what order. Pure functions, so every rule is testable.
enum FeaturedPolicy {
    static let target = 12
    static let minimumSlides = 10
    static let minimumSynopsis = 40

    // MARK: eligibility

    /// A title is featurable with a usable backdrop, a real synopsis, and a way to describe it (year or genre).
    static func slide(_ item: LibraryItem) -> FeaturedSlide? {
        guard let backdrop = item.backdropURL, isUsableArtwork(backdrop),
              let synopsis = item.overview?.trimmingCharacters(in: .whitespacesAndNewlines), synopsis.count >= minimumSynopsis,
              !item.title.trimmingCharacters(in: .whitespaces).isEmpty,
              item.year != nil || (item.genre?.isEmpty == false) else { return nil }
        var rating: String?
        var minutes: Int?
        switch item {
        case .movie(let m):
            if let r = m.rating, let v = Double(r), v > 0 { rating = String(format: "%.1f", v) }
            if let d = m.durationSeconds, d > 60 { minutes = Int((d / 60).rounded()) }
        case .series(let s):
            if let r = s.rating, let v = Double(r), v > 0 { rating = String(format: "%.1f", v) }
        }
        return FeaturedSlide(item: item, title: displayTitle(item.title), year: item.year, genre: item.genre, durationMinutes: minutes, rating: rating,
                             synopsis: synopsis, backdropURL: backdrop, posterURL: item.posterURL)
    }

    static func isUsableArtwork(_ url: String) -> Bool {
        guard let u = URL(string: url), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https", u.host != nil else { return false }
        return true
    }

    /// "Alien: Romulus (2024) (Tamil) (CAM)" → "Alien: Romulus". Provider tags are noise on a banner.
    static func displayTitle(_ raw: String) -> String {
        var t = raw
        while let r = t.range(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, options: .regularExpression) { t.removeSubrange(r) }
        let cleaned = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? raw : cleaned
    }

    /// Identity used to keep one title from appearing twice (the same film listed in several languages or qualities).
    static func uniquenessKey(_ item: LibraryItem) -> String {
        "\(item.isSeries ? "s" : "m"):\(MetadataNormalizer.normalize(displayTitle(item.title))):\(item.year.map(String.init) ?? "")"
    }

    // MARK: daily rotation

    /// Local calendar day, so the selection changes at midnight for the user and stays put for the rest of the day.
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func seed(day: String, scope: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in (day + "|" + scope).utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    /// Deterministic shuffle (SplitMix64 + Fisher–Yates): the same seed always gives the same order.
    static func seededShuffle<T>(_ items: [T], seed: UInt64) -> [T] {
        var a = items, state = seed
        func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        guard a.count > 1 else { return a }
        for i in stride(from: a.count - 1, to: 0, by: -1) { a.swapAt(i, Int(next() % UInt64(i + 1))) }
        return a
    }

    // MARK: selection

    /// Movies → Featured. Candidates are the best-rated, recent titles of the local catalog; which of them are tried first
    /// rotates once a day. The order is not provider order and is not presented as a chart.
    static func moviePool(_ candidates: [Movie], day: String, scope: String, year: Int = Calendar.current.component(.year, from: Date()), poolSize: Int = 80) -> [Movie] {
        let good = candidates.filter { m in
            guard let r = m.rating.flatMap(Double.init), r >= 6.0, m.posterURL.map(isUsableArtwork) == true, m.releaseYear != nil else { return false }
            return true
        }
        func quality(_ m: Movie) -> Double { (Double(m.rating ?? "") ?? 0) * 10 + ((m.releaseYear ?? 0) >= year - 6 ? 8 : 0) + (m.backdropURL != nil ? 20 : 0) }
        let best = good.sorted { (quality($0), $1.id) > (quality($1), $0.id) }.prefix(poolSize)
        return seededShuffle(Array(best), seed: seed(day: day, scope: scope + "|movies"))
    }

    /// Takes eligible items in the order given, skipping repeats of the same title, up to `limit`.
    static func slides(from items: [LibraryItem], limit: Int = target) -> [FeaturedSlide] {
        var seen = Set<String>(), out: [FeaturedSlide] = []
        for item in items {
            guard let s = slide(item), seen.insert(uniquenessKey(item)).inserted else { continue }
            out.append(s)
            if out.count == limit { break }
        }
        return out
    }
}

/// Builds the slideshows. Everything comes from the local catalog; the provider is asked for details only for the few
/// titles being considered, only when the catalog does not already hold them, never on a slide change, and each answer is
/// kept in the database. The finished list is also kept for the day, so tab switches and refreshes don't rebuild it.
final class FeaturedService: Sendable {
    private let catalog: CatalogRepository
    private let details: DetailService
    private let cache = FeaturedCache()
    /// Most provider detail requests one slideshow may make, and how many run at once.
    static let maxDetailRequests = 40
    static let concurrency = 3

    init(catalog: CatalogRepository, details: DetailService) { self.catalog = catalog; self.details = details }

    func movieSlides(sourceID: UUID?, now: Date = Date()) async -> [FeaturedSlide] {
        let day = FeaturedPolicy.dayKey(now), scope = sourceID?.uuidString ?? "all"
        let key = "movies|\(scope)|\(day)"
        if let hit = await cache.get(key) { return hit }
        let candidates = await Task.detached { [catalog] in (try? catalog.movies(VODQuery(sourceID: sourceID, sort: .rating, limit: 400))) ?? [] }.value
        let pool = FeaturedPolicy.moviePool(candidates, day: day, scope: scope)
        let slides = await enrich(pool.map { LibraryItem.movie($0) })
        if !slides.isEmpty { await cache.set(key, slides) }
        return slides
    }

    /// Discover keeps the order of the ranking it is given (the library's own ratings and plays), only dropping titles that
    /// can't be featured. The order is that ranking's, never reshuffled.
    func discoverSlides(ranked: [LibraryItem], sourceID: UUID?, now: Date = Date()) async -> [FeaturedSlide] {
        let day = FeaturedPolicy.dayKey(now), scope = sourceID?.uuidString ?? "all"
        let key = "discover|\(scope)|\(day)|\(ranked.prefix(24).map(\.id).joined(separator: ",").hashValue)"
        if let hit = await cache.get(key) { return hit }
        let slides = await enrich(ranked)
        if !slides.isEmpty { await cache.set(key, slides) }
        return slides
    }

    /// Walks `items` in order, fetching details for movies that lack a backdrop/synopsis (bounded), until there are enough slides.
    private func enrich(_ items: [LibraryItem]) async -> [FeaturedSlide] {
        var ready: [LibraryItem] = []
        var requests = 0
        var index = 0
        let want = FeaturedPolicy.target
        while index < items.count, FeaturedPolicy.slides(from: ready, limit: want).count < want {
            // a small batch at a time, so we stop asking the provider as soon as there are enough
            var batch: [LibraryItem] = []
            while index < items.count, batch.count < Self.concurrency {
                let item = items[index]; index += 1
                batch.append(item)
            }
            let resolved = await withTaskGroup(of: (Int, LibraryItem).self) { group -> [(Int, LibraryItem)] in
                for (i, item) in batch.enumerated() {
                    group.addTask { [self] in
                        if FeaturedPolicy.slide(item) != nil { return (i, item) }
                        guard case .movie(let m) = item, m.detailFetchedAt == nil, requestAllowed() else { return (i, item) }
                        if let updated = try? await details.movie(id: m.id) { return (i, .movie(updated)) }
                        return (i, item)
                    }
                }
                var out: [(Int, LibraryItem)] = []
                for await r in group { out.append(r) }
                return out
            }
            ready += resolved.sorted { $0.0 < $1.0 }.map(\.1)
            requests += batch.count
            if requests > Self.maxDetailRequests * 4 { break }
        }
        return FeaturedPolicy.slides(from: ready, limit: want)
    }

    private let budget = LockedBox(0)
    private func requestAllowed() -> Bool {
        let n = budget.value
        guard n < Self.maxDetailRequests else { return false }
        budget.value = n + 1
        return true
    }
}

actor FeaturedCache {
    private var store: [String: [FeaturedSlide]] = [:]
    func get(_ k: String) -> [FeaturedSlide]? { store[k] }
    func set(_ k: String, _ v: [FeaturedSlide]) {
        if store.count > 16 { store.removeAll() }                 // a day's worth is a handful of entries
        store[k] = v
    }
}
