import Foundation

/// A small repeatable random number generator, so a given seed always shuffles the same way (and the shuffle can be tested).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Chooses the titles for the banner slideshow: a different mix each time the app is opened, movies and series taking turns, wide
/// pictures first, and nothing that is a cinema-camera copy.
enum FeaturedPicker {
    /// New every launch of the app and the same for the whole of it, so the banner does not change under you while you move between screens.
    static let launchSeed = UInt64.random(in: .min ... .max)

    static func pick(movies: [LibraryItem], series: [LibraryItem], count: Int, seed: UInt64) -> [LibraryItem] {
        var rng = SeededGenerator(seed: seed)
        func prepared(_ items: [LibraryItem]) -> [LibraryItem] {
            var seen = Set<String>()
            let usable = items.filter { isUsable($0) && seen.insert($0.id).inserted }
            let wide = usable.filter { $0.backdropURL.nilIfEmpty != nil }.shuffled(using: &rng)
            let tall = usable.filter { $0.backdropURL.nilIfEmpty == nil }.shuffled(using: &rng)
            return wide + tall
        }
        let m = prepared(movies), s = prepared(series)
        var out: [LibraryItem] = []
        var i = 0
        while out.count < count, i < max(m.count, s.count) {
            if i < m.count { out.append(m[i]) }
            if out.count < count, i < s.count { out.append(s[i]) }
            i += 1
        }
        return out
    }

    /// A banner needs a picture, and a cinema-camera copy ("CAM", "HDCAM", "TS") looks bad at that size.
    static func isUsable(_ item: LibraryItem) -> Bool {
        guard item.backdropURL.nilIfEmpty != nil || item.posterURL.nilIfEmpty != nil else { return false }
        let t = item.title.uppercased()
        return !["(CAM)", "HDCAM", "HD-CAM", "TELESYNC", " HDTS", "(TS)", "PREDVD"].contains { t.contains($0) }
    }
}

extension DiscoverService {
    /// Titles for the banner slideshow of Home (movies and series) or of the Movies or Series screen.
    func featured(sourceID: UUID?, kinds: Set<ContentKind>, count: Int = 6, seed: UInt64) throws -> [LibraryItem] {
        func pool(_ kind: ContentKind) throws -> [LibraryItem] {
            if kind == .movie {
                let recent = try catalog.movies(VODQuery(sourceID: sourceID, sort: .recentlyAdded, limit: 150))
                let best = try catalog.movies(VODQuery(sourceID: sourceID, sort: .rating, limit: 100))
                return (recent + best).map { .movie($0) }
            }
            let recent = try catalog.series(VODQuery(sourceID: sourceID, sort: .recentlyAdded, limit: 150))
            let best = try catalog.series(VODQuery(sourceID: sourceID, sort: .rating, limit: 100))
            return (recent + best).map { .series($0) }
        }
        let movies = kinds.contains(.movie) ? try pool(.movie) : []
        let series = kinds.contains(.series) ? try pool(.series) : []
        return FeaturedPicker.pick(movies: movies, series: series, count: count, seed: seed)
    }
}
