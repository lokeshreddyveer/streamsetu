import Foundation

// Covers for the genre, mood and language tiles of Explore and Search. No key and no account: a cover comes from a real playlist the
// source (or Deezer's public playlist search) already offers for that category. Nothing is fabricated; with no answer the tile keeps its
// designed fallback. Answers are kept on disk for several days, and nothing is requested until a tile is on screen.

// MARK: - Categories

enum MusicCategoryKind: String, Codable, Sendable, CaseIterable { case genre, mood, language }

/// One tile of Browse: where it leads and what to ask for its cover.
struct MusicCategory: Identifiable, Hashable, Sendable {
    enum Target: Hashable, Sendable { case genre(MusicBrowseGenre), search(String) }
    var name: String
    var kind: MusicCategoryKind
    var target: Target
    /// For a language tile: the language it stands for (used for its cover and its words). The tile opens the source's songs, albums and playlists for that language's name; the per-language lists of sources that have them are the Language spotlight shelves.
    var language: MusicLanguage?
    /// Covers the source already gave (rare); used before any request.
    var thumbnails: [MusicThumbnail] = []
    /// A name that does not change with the app's language (a language tile: its English name). The tile's id and cover words come from it, so the cover cache does not depend on the wording shown.
    var stableName: String? = nil

    var id: String { kind.rawValue + "|" + Self.normalise(stableName ?? name) }
    /// Words handed to the cover search.
    var coverQuery: String {
        let words = (stableName ?? name).replacingOccurrences(of: "&", with: " ").replacingOccurrences(of: "/", with: " ")
        switch kind {
        case .genre: return words + " hits"
        case .mood: return words + " music"
        case .language: return words + " hits"
        }
    }
    static func normalise(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Orders and tidies a list: the same name once, the source's order kept.
    static func unique(_ list: [MusicCategory]) -> [MusicCategory] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.id).inserted }
    }
}

enum MusicCategoryCatalogue {
    /// The languages the app can offer without a library: the ones the device is set to, derived from `Locale.preferredLanguages` (nothing is listed here).
    /// `key` is the lower-case English name; names are the person's language through Locale.
    static var languages: [(key: String, name: String)] {
        MusicLanguageNames.deviceLanguages().map { (key: $0.key, name: $0.name) }
    }

    static func languageQuery(_ english: String) -> String { english + " songs" }

    /// Words that mark a source section as a mood or an activity rather than a genre.
    static func kind(forSection title: String) -> MusicCategoryKind {
        let t = title.lowercased()
        return t.contains("mood") || t.contains("moment") || t.contains("activit") || t.contains("feel") ? .mood : .genre
    }
}

/// Which languages the person's own songs are in, read from the scripts of titles and artist names (nothing is sent anywhere).
enum MusicLanguageDetect {
    static func language(of text: String) -> String? {
        for s in text.unicodeScalars {
            switch s.value {
            case 0x0C00...0x0C7F: return "telugu"
            case 0x0B80...0x0BFF: return "tamil"
            case 0x0C80...0x0CFF: return "kannada"
            case 0x0D00...0x0D7F: return "malayalam"
            case 0x0A00...0x0A7F: return "punjabi"
            case 0x0980...0x09FF: return "bengali"
            case 0x0A80...0x0AFF: return "gujarati"
            case 0x0900...0x097F: return "hindi"
            case 0xAC00...0xD7AF, 0x1100...0x11FF: return "korean"
            case 0x3040...0x30FF: return "japanese"
            case 0x0600...0x06FF: return "arabic"
            default: continue
            }
        }
        return nil
    }

    /// Language keys by how many of the texts are in them, most first; ties keep first-seen order.
    static func ranked(texts: [String]) -> [String] {
        var counts: [String: Int] = [:], first: [String: Int] = [:]
        for (i, t) in texts.enumerated() {
            guard let k = language(of: t) else { continue }
            counts[k, default: 0] += 1
            if first[k] == nil { first[k] = i }
        }
        return counts.keys.sorted { a, b in counts[a]! != counts[b]! ? counts[a]! > counts[b]! : first[a]! < first[b]! }
    }

    /// `keys` with the preferred ones moved to the front in that order; unknown preferences are ignored and nothing is dropped or repeated.
    static func ordered(keys: [String], preferring: [String]) -> [String] {
        var out: [String] = []
        for k in preferring where keys.contains(k) && !out.contains(k) { out.append(k) }
        for k in keys where !out.contains(k) { out.append(k) }
        return out
    }
}

// MARK: - Cover cache

/// A small file of category -> cover address with the time it was learned. Entries older than `ttl` (seven days) are STALE: still shown while a new cover is
/// fetched, and dropped on the next save once they are twice that old.
struct MusicGenreArtworkCache {
    struct Entry: Codable, Equatable, Sendable { var url: String; var at: Date }
    static let ttl: TimeInterval = MusicTileCoverPolicy.ttl
    static let fileName = "categories.json"

    let directory: URL
    var now: @Sendable () -> Date
    private(set) var entries: [String: Entry]

    init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory; self.now = now
        entries = (try? Data(contentsOf: directory.appendingPathComponent(Self.fileName))).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    /// The cache key for a category: kind, name and the words asked, so a change in how covers are searched never serves an old answer.
    static func key(_ c: MusicCategory) -> String { c.id + "|" + MusicCategory.normalise(c.coverQuery) }

    func url(for key: String) -> String? {
        guard let e = entries[key], now().timeIntervalSince(e.at) < Self.ttl else { return nil }
        return e.url
    }

    /// The cover even when it is past its lifetime (shown while the replacement loads).
    func staleURL(for key: String) -> String? { entries[key]?.url }

    mutating func set(_ url: String, for key: String) { entries[key] = Entry(url: url, at: now()) }

    func save() {
        let live = entries.filter { now().timeIntervalSince($0.value.at) < Self.ttl * 2 }
        guard let data = try? JSONEncoder().encode(live) else { return }
        MusicStorage.ensureUnbacked(directory)
        try? data.write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// Privacy wipe.
    mutating func clear() {
        entries = [:]
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - Resolving

/// Picks the best playlist for a category from a public playlist search. Pure, so it is tested without the network.
enum MusicGenreCoverPick {
    struct Candidate: Equatable, Sendable { var title: String; var tracks: Int; var cover: String }

    static func words(_ s: String) -> [String] {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 }
    }

    /// Prefers playlists whose title carries the category's own words, with a real number of songs and a plain title; an empty or off-topic list is never used.
    static func pick(_ list: [Candidate], category: MusicCategory) -> String? {
        // The words the search was made with (the stable English name), not the tile's name in the app's language: playlist titles are English, so a Hindi or Telugu tile
        // would never find its own words in them and would be left a gradient.
        let wanted = words(category.stableName ?? category.name)
        func score(_ c: Candidate) -> Int? {
            guard c.tracks >= 10, c.cover.hasPrefix("https://") else { return nil }
            let t = Set(words(c.title))
            let hit = wanted.filter { t.contains($0) }.count
            guard hit > 0 || wanted.isEmpty else { return nil }
            let plain = c.title.unicodeScalars.allSatisfy { $0.value < 0x2000 || (0x0900...0x0DFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
            let size = min(c.tracks, 500) / 10
            return hit * 1000 + (plain ? 200 : 0) + (c.tracks <= 2000 ? 100 : 0) + size
        }
        return list.compactMap { c in score(c).map { (c, $0) } }.max { $0.1 < $1.1 }?.0.cover
    }
}

protocol MusicGenreCoverSource: Sendable {
    func cover(for category: MusicCategory) async -> String?
}

/// Deezer's public playlist search: no key, no account. Only the category's own words are sent.
struct DeezerPlaylistCoverSource: MusicGenreCoverSource {
    static let base = URL(string: "https://api.deezer.com/search/playlist")!
    var http = MusicHTTP()

    func cover(for category: MusicCategory) async -> String? {
        guard let obj = try? await http.getObject(Self.base, query: ["q": category.coverQuery, "limit": "8"]),
              let rows = (obj as? [String: Any])?["data"] as? [[String: Any]] else { return nil }
        let list = rows.compactMap { r -> MusicGenreCoverPick.Candidate? in
            guard let title = r["title"] as? String, let cover = (r["picture_big"] as? String) ?? (r["picture_medium"] as? String) else { return nil }
            return .init(title: title, tracks: (r["nb_tracks"] as? Int) ?? 0, cover: cover)
        }
        return MusicGenreCoverPick.pick(list, category: category)
    }
}

/// Runs resolutions a couple at a time with a short gap, so a page of fifty tiles never floods a host.
actor MusicGenreResolveGate {
    private let limit: Int
    private let gap: Duration
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int = MusicTileCoverPolicy.parallel, gap: Duration = .milliseconds(120)) { self.limit = limit; self.gap = gap }

    func acquire() async {
        if running < limit { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() async {
        try? await Task.sleep(for: gap)
        if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() }
    }
}

/// What the tiles ask for covers. Main actor: it owns the cache and the list of requests in flight.
@MainActor
final class MusicGenreArtwork {
    static let shared = MusicGenreArtwork(directory: MusicStorage.subfolder("GenreArtwork"), sources: [DeezerPlaylistCoverSource()])

    private var cache: MusicGenreArtworkCache
    private let sources: [any MusicGenreCoverSource]
    private let gate = MusicGenreResolveGate()
    private var inFlight: [String: Task<String?, Never>] = [:]
    private var waiting: [String: Int] = [:]
    private var misses: [String: Date] = [:]
    /// Categories whose stale cover is being replaced right now.
    private var refreshing: Set<String> = []
    /// How long a category with no answer is left alone (this session only).
    static let missPause: TimeInterval = 15 * 60
    /// Tried before the general sources: the browsing source's own first playlist for the category. Set by the page that knows the source.
    var primary: (@Sendable (MusicCategory) async -> String?)?

    init(directory: URL, sources: [any MusicGenreCoverSource], now: @escaping @Sendable () -> Date = { Date() }) {
        cache = MusicGenreArtworkCache(directory: directory, now: now); self.sources = sources
    }

    /// The cover already known, with no waiting and no network.
    func cachedURL(for c: MusicCategory) -> String? {
        if let t = c.thumbnails.first?.url, !t.isEmpty { return t }
        let key = MusicGenreArtworkCache.key(c)
        return cache.url(for: key) ?? cache.staleURL(for: key)
    }

    /// The cover for a category: from memory or disk, else asked for once (shared by every tile that wants it). Cancelling the caller
    /// drops its interest; a request nobody wants any more is not started.
    func cover(for c: MusicCategory) async -> String? {
        if c.isToggle { return nil }
        let key = MusicGenreArtworkCache.key(c)
        if let known = cachedURL(for: c) {
            // Stale while revalidating: an older cover is returned at once and replaced in the background (a failed refresh keeps it).
            if c.thumbnails.first?.url.isEmpty != false, cache.url(for: key) == nil, !refreshing.contains(key), !(misses[key].map { $0 > Date() } ?? false) {
                refreshing.insert(key)
                Task { _ = await self.fetchCover(c, key: key); self.refreshing.remove(key) }
            }
            return known
        }
        return await fetchCover(c, key: key)
    }

    private func fetchCover(_ c: MusicCategory, key: String) async -> String? {
        if let until = misses[key], until > Date() { return nil }
        waiting[key, default: 0] += 1
        let task: Task<String?, Never>
        if let t = inFlight[key] { task = t } else {
            let sources = self.sources, primary = self.primary, gate = self.gate
            task = Task { [weak self] in
                await gate.acquire()
                let wanted = await self?.isWanted(key) ?? false
                var found: String?
                if wanted {
                    if let p = primary { found = await p(c) }
                    if found == nil { for s in sources where found == nil { found = await s.cover(for: c) } }
                }
                await gate.release()
                await self?.finish(key, url: found, wanted: wanted)
                return found
            }
            inFlight[key] = task
        }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { Task { @MainActor [weak self] in self?.lose(key) } }
        return result
    }

    private var saving = false
    /// Many covers arrive together: one write a moment later holds all of them, instead of a full file write for each cover.
    private func scheduleSave() {
        guard !saving else { return }
        saving = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            self?.cache.save(); self?.saving = false
        }
    }

    private func isWanted(_ key: String) -> Bool { (waiting[key] ?? 0) > 0 }
    private func lose(_ key: String) { if let n = waiting[key], n > 0 { waiting[key] = n - 1 } }
    private func finish(_ key: String, url: String?, wanted: Bool) {
        inFlight[key] = nil
        waiting[key] = nil
        guard wanted else { return }
        if let url { cache.set(url, for: key); scheduleSave() } else { misses[key] = Date().addingTimeInterval(Self.missPause) }
    }

    /// Starts resolving a few categories that are about to scroll into view; they are fetched ahead of time (only a few at a time), and the covers are kept.
    func warm(_ list: [MusicCategory]) {
        for c in list.prefix(MusicTileCoverPolicy.parallel + 2) where cache.url(for: MusicGenreArtworkCache.key(c)) == nil && c.thumbnails.first?.url.isEmpty != false {
            Task { _ = await self.cover(for: c) }
        }
    }

    /// Covers for source categories come first from the source's own first playlist for that category; other categories use the public search.
    func useSource(_ source: (any MusicMetadataProvider)?) {
        guard let source else { primary = nil; return }
        primary = { c in
            guard case .genre(let g) = c.target, !g.id.hasPrefix("search:"), let page = try? await source.browse(genreID: g.id, page: nil) else { return nil }   // a search tile has no source genre to browse
            for s in page.items {
                for item in s.items {
                    let thumbs: [MusicThumbnail]
                    switch item { case .album(let a): thumbs = a.thumbnails; case .artist(let a): thumbs = a.thumbnails; case .playlist(let p): thumbs = p.thumbnails; case .track(let t): thumbs = t.thumbnails }
                    if let a = MusicArtworkService.pickThumbnail(thumbs, neededPixels: 512) { return a }
                }
            }
            return nil
        }
    }

    /// Privacy wipe (called from the Music wipe).
    func wipe() {
        for t in inFlight.values { t.cancel() }
        inFlight = [:]; waiting = [:]; misses = [:]; refreshing = []
        cache.clear()
    }
}
