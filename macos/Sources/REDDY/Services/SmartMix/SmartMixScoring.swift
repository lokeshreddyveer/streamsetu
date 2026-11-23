import Foundation

/// Feature functions (each 0...1000) and the weight table. Every number is an Int; no floating point anywhere.
enum SmartMixScoring {
    // MARK: features
    static func release(year: Int?, nowYear: Int) -> Int {
        guard let year else { return 300 }
        switch max(0, nowYear - year) {
        case 0: return 1000
        case 1: return 850
        case 2: return 700
        case 3: return 560
        case 4: return 450
        case 5: return 360
        case 6...8: return 260
        case 9...15: return 150
        default: return 80
        }
    }

    static func added(days: Int?) -> Int {
        guard let d = days else { return 300 }
        let v = max(0, d)
        if v <= 7 { return 1000 }
        if v <= 30 { return 800 }
        if v <= 90 { return 600 }
        if v <= 180 { return 450 }
        if v <= 365 { return 300 }
        return 150
    }

    static func quality(_ rank: Int) -> Int {
        switch rank { case 5: return 1000; case 4: return 800; case 3: return 600; case 2: return 450; case 1: return 250; default: return 0 }
    }

    static func language(_ lang: String?, preferred: String?) -> Int {
        guard let preferred, let lang else { return 500 }
        return lang == preferred ? 1000 : 150
    }

    /// Tenths of a rating text, or nil when unusable. Grammar `^[0-9]{1,2}(\.[0-9]{1,2})?$`, parsed with integers only; usable range 1...99.
    static func ratingTenths(_ text: String?) -> Int? {
        guard let text else { return nil }
        let b = Array(text.utf8)
        func digit(_ i: Int) -> Int? { i < b.count && b[i] >= 48 && b[i] <= 57 ? Int(b[i]) - 48 : nil }
        var i = 0, whole = 0, wholeDigits = 0
        while let d = digit(i), wholeDigits < 2 { whole = whole * 10 + d; i += 1; wholeDigits += 1 }
        if wholeDigits == 0 { return nil }
        var frac = 0
        if i < b.count {
            guard b[i] == 46 else { return nil }
            i += 1
            var fd = 0
            while let d = digit(i) { if fd == 0 { frac = d }; fd += 1; i += 1 }
            if fd == 0 || fd > 2 || i != b.count { return nil }
        }
        let tenths = whole * 10 + frac
        return (1...99).contains(tenths) ? tenths : nil
    }

    static func rating(_ text: String?) -> Int {
        guard let t = ratingTenths(text) else { return 500 }
        let raw = min(1000, max(0, 500 + (t - 60) * 12))
        return 500 + ((raw - 500) * 40) / 100      // Int "/" truncates toward zero, as in Kotlin
    }

    static func popularity(p7: Int, p30: Int) -> Int {
        switch p7 * 2 + p30 {
        case ...0: return 0
        case 1: return 400
        case 2: return 600
        case 3...4: return 750
        case 5...9: return 900
        default: return 1000
        }
    }

    static func affinity(_ c: SMCandidate, _ a: SMAffinity) -> Int {
        var s = 0
        if let l = c.lang {
            if a.topLangs.first == l { s += 400 } else if a.topLangs.dropFirst().prefix(2).contains(l) { s += 250 }
        }
        if let f = c.folder, a.topFolders.prefix(5).contains(f) { s += 200 }
        if let g = c.genre, a.topGenres.prefix(5).contains(g) { s += 100 }
        if let y = c.year, a.topDecades.prefix(2).contains((y / 10) * 10) { s += 150 }
        return min(1000, s)
    }

    static func fresh(loadsAgo: Int?) -> Int {
        switch loadsAgo { case 1?: return 100; case 2?: return 400; case 3?: return 700; default: return 1000 }
    }

    // MARK: weights (percent; every row sums to 100)
    struct Shelf: Sendable {
        /// release, added, quality, language, rating, popularity, affinity, fresh
        let w: [Int]
        let sharp: Bool
        let pool: Int
        let size: Int
        let minCount: Int
        let mixesKinds: Bool
    }

    static let hero = Shelf(w: [10, 10, 15, 15, 5, 10, 20, 15], sharp: true, pool: 2000, size: 12, minCount: 3, mixesKinds: true)
    static let forYou = Shelf(w: [5, 5, 10, 15, 5, 10, 40, 10], sharp: true, pool: 2000, size: 14, minCount: 6, mixesKinds: false)
    static let rediscover = Shelf(w: [10, 0, 15, 15, 10, 0, 35, 15], sharp: true, pool: 2000, size: 14, minCount: 6, mixesKinds: false)
    static let langPref = Shelf(w: [15, 15, 25, 0, 5, 15, 15, 10], sharp: true, pool: 2000, size: 14, minCount: 6, mixesKinds: false)
    static let topWeek = Shelf(w: [10, 15, 10, 10, 5, 40, 0, 10], sharp: true, pool: 2000, size: 14, minCount: 6, mixesKinds: false)
    static let trendingLibrary = Shelf(w: [10, 15, 10, 10, 5, 40, 0, 10], sharp: true, pool: 2000, size: 14, minCount: 3, mixesKinds: false)
    /// Genre shelves: best rated, recent and popular first; no affinity (the genre is the topic), fresh keeps repeat suppression.
    static let genre = Shelf(w: [15, 10, 10, 5, 25, 25, 0, 10], sharp: true, pool: 2000, size: SMGenres.shelfSize, minCount: SMGenres.minTitles, mixesKinds: true)
    /// Weights of the all-time view (genre shelves and Trending in Your Library) when TMDB has no list to follow: rating first.
    static let allTimeWeights = [5, 0, 15, 5, 50, 15, 0, 10]
    static let folder = Shelf(w: [10, 25, 30, 20, 0, 0, 0, 15], sharp: false, pool: 200, size: 12, minCount: 1, mixesKinds: false)

    static func shelf(_ id: String, mode: SMShelfMode) -> Shelf {
        let base = shelf(id)
        guard mode == .allTime, SMShelf.isGenre(id) || id == SMShelf.trendingLibrary else { return base }
        return Shelf(w: allTimeWeights, sharp: base.sharp, pool: base.pool, size: base.size, minCount: base.minCount, mixesKinds: base.mixesKinds)
    }

    static let fresh = Shelf(w: [0, 50, 10, 5, 10, 15, 0, 10], sharp: true, pool: 2000, size: 14, minCount: 6, mixesKinds: true)
    static let movieNight = Shelf(w: [10, 0, 20, 10, 35, 15, 0, 10], sharp: true, pool: 2000, size: 14, minCount: 6, mixesKinds: false)
    static let binge = Shelf(w: [5, 5, 10, 10, 35, 25, 0, 10], sharp: true, pool: 2000, size: 14, minCount: 6, mixesKinds: false)
    static let mood = Shelf(w: [15, 10, 10, 5, 25, 25, 0, 10], sharp: true, pool: 2000, size: 14, minCount: 6, mixesKinds: true)

    static func shelf(_ id: String) -> Shelf {
        switch id {
        case SMShelf.fresh: return fresh
        case SMShelf.movieNight: return movieNight
        case SMShelf.binge: return binge
        case SMShelf.hero: return hero
        case SMShelf.forYou: return forYou
        case SMShelf.rediscover: return rediscover
        case SMShelf.langPref: return langPref
        case SMShelf.topWeek: return topWeek
        case SMShelf.trendingLibrary: return trendingLibrary
        default: return SMShelf.isGenre(id) ? genre : (SMShelf.isMood(id) ? mood : folder)
        }
    }

    /// 0...1100.
    static func score(_ c: SMCandidate, loadsAgo: Int?, shelfId: String, shelf: Shelf, ctx: SMContext, tier: Int) -> Int {
        let f = [release(year: c.year, nowYear: ctx.nowYear), added(days: c.added), quality(c.q),
                 language(c.lang, preferred: ctx.preferredLang), rating(c.rating), popularity(p7: c.p7, p30: c.p30),
                 affinity(c, ctx.affinity), tier >= 1 ? 1000 : fresh(loadsAgo: loadsAgo)]
        var sum = 0
        for i in 0..<8 { sum += shelf.w[i] * f[i] }
        var s = sum / 100
        if shelfId == SMShelf.hero {
            if c.backdrop { s += 50 }
            if c.trend != nil { s += 60 }
        } else if shelfId == SMShelf.topWeek || shelfId == SMShelf.trendingLibrary {
            if c.trend != nil { s += 100 }
        }
        if tier >= 3 && c.watched && shelfId != SMShelf.rediscover { s -= 200 }
        return max(0, min(1100, s))
    }

    /// Sampling weight. Max 1 + 1100*1100/100 = 12101; times 2000 candidates stays far below Int64.
    static func weight(score s: Int, sharp: Bool) -> Int64 {
        sharp ? 1 + Int64(s) * Int64(s) / 100 : 1 + Int64(s)
    }
}
