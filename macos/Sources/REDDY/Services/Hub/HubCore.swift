import Foundation

// The metadata hub, pure part: the vocabulary, the quality scorer and the arbiter. No network, no database, no clock except what is passed in.
// Shared fixtures (Kotlin matches these later): artwork/fixtures/arbiter-poster.json, arbiter-logo.json, identity.json, arbiter-episode-text.json, tvmaze-*.json, display-rating.json.
// Provider names are internal: nothing here is shown to a person outside Settings and About.

enum HubSource: String, CaseIterable, Sendable, Codable {
    case tmdb, fanart, tvdb, tvmaze, playlist
    /// Lower is preferred when two candidates score the same (posters: TMDB, then fanart, then TheTVDB).
    var tieRank: Int { switch self { case .playlist: 0; case .tmdb: 1; case .fanart: 2; case .tvdb: 3; case .tvmaze: 4 } }
}

enum HubTitleKind: String, Sendable, Codable { case movie, series }

enum ArtKind: String, CaseIterable, Sendable, Codable { case poster, backdrop, logo, banner, thumb, seasonPoster, episodeStill }

struct ArtCandidate: Sendable, Equatable {
    var kind: ArtKind
    var url: String
    var source: HubSource
    /// ISO 639-1 ("en"), or "", "00", nil for textless.
    var lang: String?
    var width: Int
    var height: Int
    /// Likes (fanart), vote count (TMDB) or score (TheTVDB): only the log-scaled size matters.
    var likes: Int = 0
    var season: Int? = nil
}

struct ArtContext: Sendable, Equatable {
    var preferredLang: String = "en"
    var originalLang: String? = nil
    /// Desktop and TV sizes may use 4K backdrops; phones do not need them.
    var largeScreen: Bool = true
}

enum QualityScorer {
    static func isTextless(_ l: String?) -> Bool { l == nil || l == "" || l == "00" || l == "xx" }

    static func languageScore(_ lang: String?, _ ctx: ArtContext) -> Double {
        if let l = lang?.lowercased(), !isTextless(l) {
            if l == ctx.preferredLang.lowercased() { return 1000 }
            if let o = ctx.originalLang?.lowercased(), l == o { return 500 }
            if l == "en" { return 400 }
            return 0
        }
        return 600
    }

    /// Log scale, capped at 100.
    static func likesBucket(_ n: Int) -> Double { min(100, 25 * log2(1 + Double(max(0, n)))) }

    static func aspect(_ c: ArtCandidate) -> Double { c.height > 0 ? Double(c.width) / Double(c.height) : 0 }
    static func near(_ a: Double, _ target: Double, tol: Double = 0.08) -> Bool { target > 0 && abs(a - target) / target <= tol }

    /// Poster: language + size + likes + aspect fit (2:3 within 8%, else -300) - 500 under 500 px wide.
    static func poster(_ c: ArtCandidate, _ ctx: ArtContext) -> Double {
        var s = languageScore(c.lang, ctx) + Double(min(c.width, 2000)) / 20 + likesBucket(c.likes)
        if !near(aspect(c), 2.0 / 3.0) { s -= 300 }
        if c.width < 500 { s -= 500 }
        return s
    }
    /// Clear logo: language matters most, PNG with alpha only, at least 400 px wide; fanart is the best curated source, then TMDB, then TheTVDB.
    static func logo(_ c: ArtCandidate, _ ctx: ArtContext) -> Double {
        guard c.url.lowercased().hasSuffix(".png") else { return -10_000 }
        var s = languageScore(c.lang, ctx) + Double(min(c.width, 1500)) / 30 + likesBucket(c.likes)
        if c.width < 400 { s -= 500 }
        switch c.source { case .fanart: s += 60; case .tmdb: s += 30; default: break }
        return s
    }
    /// Backdrop / hero: textless 16:9 at least 1920 wide, else unusable. 4K only on desktop and TV sizes.
    static func backdrop(_ c: ArtCandidate, _ ctx: ArtContext) -> Double {
        guard isTextless(c.lang), near(aspect(c), 16.0 / 9.0), c.width >= 1920 else { return -10_000 }
        var s = Double(min(c.width, 3840)) / 20 + likesBucket(c.likes)
        if !ctx.largeScreen && c.width > 2600 { s -= 150 }
        return s
    }
    /// Banners, thumbs, season posters, stills: size, likes and language.
    static func generic(_ c: ArtCandidate, _ ctx: ArtContext) -> Double {
        languageScore(c.lang, ctx) / 2 + Double(min(c.width, 2000)) / 20 + likesBucket(c.likes) - (c.width < 300 ? 300 : 0)
    }
    static func score(_ c: ArtCandidate, _ ctx: ArtContext) -> Double {
        switch c.kind {
        case .poster: poster(c, ctx)
        case .logo: logo(c, ctx)
        case .backdrop: backdrop(c, ctx)
        default: generic(c, ctx)
        }
    }
    static func usable(_ c: ArtCandidate, _ ctx: ArtContext) -> Bool { score(c, ctx) > -5_000 }
}

struct StoredFact: Sendable, Equatable {
    var value: String
    var source: HubSource
    var quality: Double
    var expiresAt: Date
    var failCount: Int = 0
    /// A person's own choice: never replaced.
    var pinned: Bool { quality.isInfinite }
}

enum Arbiter {
    /// A stored value is replaced only by a clearly better candidate (margin), or when it expired or its address failed twice.
    static let margin = 50.0
    static let maxFailures = 2

    struct Pick: Sendable, Equatable { var candidate: ArtCandidate; var score: Double }

    /// The best usable candidate of a kind; ties go to the source order TMDB > fanart > TheTVDB, then to the longer address-free order (stable).
    static func pick(_ kind: ArtKind, _ all: [ArtCandidate], _ ctx: ArtContext, season: Int? = nil) -> Pick? {
        let scored = all.enumerated().filter { $0.element.kind == kind && (season == nil || $0.element.season == season) && QualityScorer.usable($0.element, ctx) }
            .map { (i: $0.offset, c: $0.element, s: QualityScorer.score($0.element, ctx)) }
        let best = scored.min { a, b in
            if a.s != b.s { return a.s > b.s }
            if a.c.source.tieRank != b.c.source.tieRank { return a.c.source.tieRank < b.c.source.tieRank }
            return a.i < b.i
        }
        return best.map { Pick(candidate: $0.c, score: $0.s) }
    }

    static func shouldReplace(stored: StoredFact?, with pick: Pick, now: Date) -> Bool {
        guard let s = stored else { return true }
        if s.pinned { return false }
        if s.source == .playlist { return false }            // what the playlist itself provided is never replaced
        if s.expiresAt <= now || s.failCount >= maxFailures { return true }
        return pick.score > s.quality + margin
    }

    /// Target quality per kind: a title already at or above it never touches fanart.tv or TheTVDB.
    static func targetQuality(_ kind: ArtKind, _ ctx: ArtContext) -> Double {
        switch kind {
        case .poster: 1000 + 75            // preferred language, decent size
        case .logo: 1000 + 60
        case .backdrop: 96                 // any textless 1920 wide
        default: 150
        }
    }
    static func atTarget(_ kind: ArtKind, stored: StoredFact?, _ ctx: ArtContext, now: Date) -> Bool {
        guard let s = stored else { return false }
        if s.pinned || s.source == .playlist { return true }
        return s.expiresAt > now && s.failCount < maxFailures && s.quality >= targetQuality(kind, ctx)
    }
}

/// The rating a title shows. The hub never blends: it calls DisplayRating (artwork/fixtures/display-rating.json). A source that gives an average without a count
/// (TVmaze) can only stand in as a provider rating, behind the playlist's own.
enum RatingArbiter {
    static func value(tmdbAverage: Double?, tmdbVotes: Int?, playlist: String?, tvmaze: Double? = nil) -> Double? {
        let fallback = RatingRule.credible(playlist) != nil ? playlist : tvmaze.map { String($0) }
        return DisplayRating.value(tmdbAverage: tmdbAverage, tmdbVotes: tmdbVotes, provider: fallback)
    }
}

/// Episode and season text: fill only where empty or a known placeholder; never overwrite what the person already sees.
enum EpisodeTextArbiter {
    struct Candidate: Sendable, Equatable { var source: HubSource; var text: String }
    static let placeholders: Set<String> = ["", "no description", "no description available", "no overview", "no overview available", "n/a", "na", "tba", "tbd", "none", "-", "null", "description"]
    /// TMDB (in the preferred language) first, then TheTVDB, then TVmaze.
    static func rank(_ s: HubSource) -> Int { switch s { case .tmdb: 0; case .tvdb: 1; case .tvmaze: 2; default: 3 } }

    static func isJunk(_ t: String?) -> Bool { placeholders.contains((t ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }

    static func stripHTML(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (a, b) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">")] { out = out.replacingOccurrences(of: a, with: b) }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The text to store, or nil to leave the stored text alone. `storedSource` is nil for text from the playlist.
    static func choose(stored: String?, storedSource: HubSource?, candidates: [Candidate]) -> Candidate? {
        let clean = candidates.map { Candidate(source: $0.source, text: stripHTML($0.text)) }.filter { !isJunk($0.text) }
            .sorted { rank($0.source) < rank($1.source) }
        guard let best = clean.first else { return nil }
        let s = (stored ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if isJunk(s) { return best }
        if storedSource == nil || storedSource == .playlist { return nil }          // the person's own library text stays
        if s.count < 20, let better = clean.first(where: { $0.text.count > 80 && rank($0.source) < rank(storedSource!) }) { return better }
        return nil
    }
}

/// The ids of one title across the services.
struct HubIdentity: Sendable, Equatable, Codable {
    var tmdb: Int? = nil
    var tvdb: Int? = nil
    var imdb: String? = nil
    var tvmaze: Int? = nil
    var kind: HubTitleKind? = nil
    var isEmpty: Bool { tmdb == nil && tvdb == nil && imdb == nil && tvmaze == nil }

    static func imdbID(_ s: String?) -> String? { ProviderIDs.imdb(s) }

    /// Fills gaps only: an id already known is never replaced by one from a lower-ranked source (playlist > tmdb > tvdb > tvmaze). `rank` is the incoming source's rank, `existingRank` the stored one's.
    static func merge(_ existing: HubIdentity, _ incoming: HubIdentity, incomingRank: Int, existingRank: Int) -> HubIdentity {
        var r = existing
        func take<T: Equatable>(_ e: T?, _ i: T?) -> T? { guard let i else { return e }; guard let e else { return i }; return incomingRank < existingRank ? i : e }
        r.tmdb = take(existing.tmdb, incoming.tmdb.flatMap { $0 > 0 ? $0 : nil })
        r.tvdb = take(existing.tvdb, incoming.tvdb.flatMap { $0 > 0 ? $0 : nil })
        r.imdb = take(existing.imdb, imdbID(incoming.imdb))
        r.tvmaze = take(existing.tvmaze, incoming.tvmaze.flatMap { $0 > 0 ? $0 : nil })
        r.kind = existing.kind ?? incoming.kind
        return r
    }
    static func rank(of s: HubSource) -> Int { switch s { case .playlist: 0; case .tmdb: 1; case .tvdb: 2; case .tvmaze: 3; case .fanart: 4 } }

    /// The id a service is asked about, or nil when it cannot be asked yet (then resolve ids first). Only the number or imdb id ever leaves the device.
    func queryID(for source: HubSource, kind k: HubTitleKind) -> String? {
        switch (source, k) {
        case (.fanart, .movie): return tmdb.map(String.init) ?? imdb
        case (.fanart, .series): return tvdb.map(String.init)
        case (.tvdb, _): return tvdb.map(String.init)
        case (.tvmaze, _): return tvmaze.map(String.init) ?? tvdb.map { "tvdb:\($0)" } ?? imdb.map { "imdb:\($0)" }
        case (.tmdb, _): return tmdb.map(String.init)
        case (.playlist, _): return nil
        }
    }
}
