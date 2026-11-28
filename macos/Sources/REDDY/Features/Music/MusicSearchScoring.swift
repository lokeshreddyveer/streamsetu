import Foundation

// Pure rules of the search page: which result is the top one, which artists are worth showing, which cells a song row may show, how the two
// columns balance, and how repeated covers are thinned. No views here, so every rule is tested without a screen.

// MARK: - similarity and top result

enum MusicSearchScoring {
    /// Words that make a long video title something other than the song or film itself. They count against a result unless the query has them too.
    static let noisePhrases: [String] = [
        "full episode", "full movie", "making", "reaction", "remake", "lyrical", "cover", "jukebox", "status", "karaoke",
        "shorts", "teaser", "trailer", "scenes", "scene", "mashup", "reels"
    ]
    /// Extra words a title may carry beyond the query before length counts against it ("From ...", a year).
    static let tokenAllowance = 1
    static let tokenPenalty = 0.05
    static let tokenPenaltyCap = 0.3
    static let noisePenalty = 0.2
    static let noisePenaltyCap = 0.5

    static func tokens(_ s: String) -> [String] {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    private static func bigrams(_ s: String) -> [String: Int] {
        let c = Array(s)
        guard c.count >= 2 else { return [:] }
        var out: [String: Int] = [:]
        for i in 0..<(c.count - 1) { out[String(c[i...i + 1]), default: 0] += 1 }
        return out
    }

    /// Character-pair overlap (Dice) of two strings, 0 to 1.
    static func dice(_ a: String, _ b: String) -> Double {
        if a == b { return a.isEmpty ? 0 : 1 }
        let x = bigrams(a), y = bigrams(b)
        let total = x.values.reduce(0, +) + y.values.reduce(0, +)
        guard total > 0 else { return 0 }
        var common = 0
        for (k, v) in x { common += min(v, y[k] ?? 0) }
        return Double(2 * common) / Double(total)
    }

    private static func squashedKey(_ s: String) -> String { MusicTransliterationKey.key(s).replacingOccurrences(of: " ", with: "") }

    /// How alike two texts are, 0 to 1: 1 for the same words, 0.95 for the same transliteration key, otherwise the better of the plain and the
    /// key character-pair overlap (so "vaikuntapuramlo" meets "Vaikunthapurramuloo"). Never above 0.94 unless the words are the same.
    static func similarity(_ query: String, _ text: String) -> Double {
        let nq = MusicSearchRanker.normalise(query), nt = MusicSearchRanker.normalise(text)
        guard !nq.isEmpty, !nt.isEmpty else { return 0 }
        if nq == nt { return 1 }
        let kq = squashedKey(query), kt = squashedKey(text)
        if !kq.isEmpty, kq == kt { return 0.95 }
        return min(0.94, max(dice(nq, nt) * 0.9, dice(kq, kt)))
    }

    /// How well a title fits the query: the whole title, or the best run of its words (a long video title that contains the name), minus a
    /// charge for every extra word and for every noise phrase the query did not ask for.
    static func titleFit(query: String, title: String) -> Double {
        let q = tokens(query), t = tokens(title)
        guard !q.isEmpty, !t.isEmpty else { return 0 }
        var base = similarity(query, title)
        if t.count > q.count {
            for size in max(1, q.count - 1)...(q.count + 1) where size <= t.count {
                for start in 0...(t.count - size) {
                    base = max(base, similarity(query, t[start..<start + size].joined(separator: " ")) * 0.97)
                }
            }
        }
        return max(0, base - lengthPenalty(query: query, title: title) - noiseCharge(query: query, title: title))
    }

    static func lengthPenalty(query: String, title: String) -> Double {
        let extra = max(0, tokens(title).count - tokens(query).count - tokenAllowance)
        return min(tokenPenaltyCap, Double(extra) * tokenPenalty)
    }

    /// The noise phrases found in `title` that `query` does not contain.
    static func noiseFound(query: String, title: String) -> [String] {
        let q = " " + tokens(query).joined(separator: " ") + " ", t = " " + tokens(title).joined(separator: " ") + " "
        return noisePhrases.filter { t.contains(" \($0) ") && !q.contains(" \($0) ") }
    }

    static func noiseCharge(query: String, title: String) -> Double { min(noisePenaltyCap, Double(noiseFound(query: query, title: title).count) * noisePenalty) }

    /// Looks like an official upload: a "Topic" channel, a label channel or an official artist.
    static func looksOfficial(_ artistLine: String) -> Bool {
        let a = " " + tokens(artistLine).joined(separator: " ") + " "
        return a.contains(" topic ") || a.contains(" vevo ") || a.contains(" official ")
    }

    // MARK: scores per kind (higher is better; about 0 to 1.1)

    static let albumBonus = 0.05, artistBonus = 0.04, officialBonus = 0.06, releaseBonus = 0.04, videoCharge = 0.04, playlistCharge = 0.1

    static func score(track t: MusicTrack, query: String) -> Double {
        let line = t.artistLine
        let title = titleFit(query: query, title: t.title)
        let album = t.album.map { titleFit(query: query, title: $0.title) * 0.55 } ?? 0
        let artist = similarity(query, line) * 0.5
        let combined = line.isEmpty ? 0 : similarity(query, t.title + " " + line) * 0.95
        let charge = noiseCharge(query: query, title: t.title)
        var s = max(title, album - charge, artist - charge, combined - charge)
        if looksOfficial(line) { s += officialBonus }
        if t.album != nil { s += releaseBonus }
        if t.isVideo == true { s -= videoCharge }
        return s
    }

    static func score(album a: MusicAlbum, query: String) -> Double {
        let line = a.artists.map(\.name).joined(separator: " ")
        let title = titleFit(query: query, title: a.title)
        let combined = line.isEmpty ? 0 : similarity(query, a.title + " " + line) * 0.95
        var s = max(title, combined) + albumBonus
        if (a.totalTracks ?? 0) > 1 || a.releaseDate != nil { s += 0.03 }
        return s
    }

    static func score(artist a: MusicArtist, query: String) -> Double {
        let s = similarity(query, a.name)
        return s + (s >= 0.8 ? artistBonus : 0)
    }

    static func score(playlist p: MusicPlaylist, query: String) -> Double { titleFit(query: query, title: p.name) - playlistCharge }

    /// The best match across every type. Each list is looked at to `depth`, because the merged order puts a long video first when it happens to
    /// contain the words. Equal scores keep the order of the type (song, artist, album, playlist) and then of the list.
    static func pick(query: String, tracks: [MusicTrack], artists: [MusicArtist], albums: [MusicAlbum], playlists: [MusicPlaylist], depth: Int = 12) -> MusicSearchResult? {
        var best: (Double, MusicSearchResult)?
        func offer(_ s: Double, _ r: MusicSearchResult) { if best == nil || s > best!.0 + 1e-9 { best = (s, r) } }
        for t in tracks.prefix(depth) { offer(score(track: t, query: query), .track(t)) }
        for a in artists.prefix(depth) { offer(score(artist: a, query: query), .artist(a)) }
        for a in albums.prefix(depth) { offer(score(album: a, query: query), .album(a)) }
        for p in playlists.prefix(depth) { offer(score(playlist: p, query: query), .playlist(p)) }
        return best?.1
    }

    /// Songs in the order of how well they fit; the merged order breaks ties.
    static func rankTracks(_ tracks: [MusicTrack], query: String) -> [MusicTrack] {
        tracks.enumerated().sorted { a, b in
            let x = score(track: a.element, query: query), y = score(track: b.element, query: query)
            return abs(x - y) > 1e-9 ? x > y : a.offset < b.offset
        }.map(\.element)
    }
}

// MARK: - artists

enum MusicArtistRelevance {
    /// A name this alike the query (or a longer name containing its words) is relevant by itself.
    static let nameThreshold = 0.6
    /// The songs and albums whose credits count.
    static let creditDepth = 5

    /// Artists worth showing for `query`: credited on the best songs and albums (those first, in credit order), or named like the query. Others
    /// are dropped; an empty answer hides the group.
    static func relevant(_ artists: [MusicArtist], query: String, tracks: [MusicTrack], albums: [MusicAlbum]) -> [MusicArtist] {
        let topTracks = Array(MusicSearchScoring.rankTracks(tracks, query: query).prefix(creditDepth))
        let topAlbums = Array(albums.sorted { MusicSearchScoring.score(album: $0, query: query) > MusicSearchScoring.score(album: $1, query: query) }.prefix(3))
        var credited: [String] = []
        for r in topTracks.flatMap(\.artists) + topAlbums.flatMap(\.artists) {
            let n = MusicSearchRanker.normalise(r.name)
            if !n.isEmpty, !credited.contains(n) { credited.append(n) }
        }
        let qKeys = Set(MusicSearchScoring.tokens(query).filter { $0.count >= 4 }.map { MusicTransliterationKey.key(word: $0) })
        func creditRank(_ a: MusicArtist) -> Int? {
            let n = MusicSearchRanker.normalise(a.name)
            return credited.firstIndex { $0 == n || (n.count >= 4 && MusicSearchScoring.dice($0, n) >= 0.9) }
        }
        func named(_ a: MusicArtist) -> Bool {
            if MusicSearchScoring.similarity(query, a.name) >= nameThreshold { return true }
            return MusicSearchScoring.tokens(a.name).contains { $0.count >= 4 && qKeys.contains(MusicTransliterationKey.key(word: $0)) }
        }
        let scored: [(offset: Int, rank: Int?, sim: Double)] = artists.enumerated().compactMap { i, a in
            let r = creditRank(a)
            guard r != nil || named(a) else { return nil }
            return (i, r, MusicSearchScoring.similarity(query, a.name))
        }
        return scored.sorted { x, y in
            switch (x.rank, y.rank) {
            case let (a?, b?): return a != b ? a < b : x.offset < y.offset
            case (_?, nil): return true
            case (nil, _?): return false
            default: return abs(x.sim - y.sim) > 1e-9 ? x.sim > y.sim : x.offset < y.offset
            }
        }.map { artists[$0.offset] }
    }
}

/// Which artist pictures are fit to show as a portrait. A video thumbnail or a wide poster is not one; the card then shows the designed circle with initials.
enum MusicArtistPortrait {
    /// A picture wider than 1.4 times its height (or taller than 1.4 times its width) is a poster or a video frame, not a face.
    static let maxAspect = 1.4

    static func isVideoThumbnailAddress(_ url: String) -> Bool {
        let u = url.lowercased()
        if u.contains("ytimg.com/vi/") || u.contains("ytimg.com/vi_webp/") { return true }
        return ["/hqdefault", "/maxresdefault", "/sddefault", "/mqdefault", "/default.jpg", "/hq720"].contains { u.contains($0) }
    }

    static func isPlausible(_ t: MusicThumbnail) -> Bool {
        if isVideoThumbnailAddress(t.url) { return false }
        guard t.width > 0, t.height > 0 else { return true }
        let r = Double(t.width) / Double(t.height)
        return r <= maxAspect && r >= 1 / maxAspect
    }

    /// The thumbnails of an artist that are plausible portraits (maybe none).
    static func portraits(_ thumbs: [MusicThumbnail]) -> [MusicThumbnail] { thumbs.filter(isPlausible) }

    /// Up to two letters for the circle that stands in for a missing portrait.
    static func initials(_ name: String) -> String {
        let letters = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2).compactMap { $0.first.map { String($0).uppercased() } }
        return letters.joined()
    }
}

// MARK: - song row cells

enum MusicTrackCells {
    private static let months = "jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec|january|february|march|april|june|july|august|september|october|november|december"
    private static let patterns: [String] = [
        "^(\(months))\\.?\\s+\\d{1,2},?\\s+\\d{4}$",
        "^\\d{1,2}\\s+(\(months))\\.?,?\\s+\\d{4}$",
        "^\\d{4}[-/.]\\d{1,2}[-/.]\\d{1,2}$",
        "^\\d{1,2}[-/.]\\d{1,2}[-/.]\\d{2,4}$",
        "^\\d+\\s+(second|minute|hour|day|week|month|year)s?\\s+ago$",
        "^(streamed|premiered|published|uploaded)\\b.*$",
        "^[\\d.,]+\\s?[kmb]?\\s*(views?|plays?|likes?|subscribers?|listeners?|streams?)$",
        "^[\\d.,]+\\s?[kmb]$"
    ]

    /// True for a date, a "3 years ago", a view or play count: text a source puts where an artist belongs on video results.
    static func looksLikeDateOrCount(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        return patterns.contains { t.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// The credits worth showing: never a date or a count.
    static func artists(of track: MusicTrack) -> [MusicArtistRef] { track.artists.filter { !looksLikeDateOrCount($0.name) && !MusicCompilationArtist.isCompilation($0.name) && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty } }
    static func artistLine(of track: MusicTrack) -> String { artists(of: track).map(\.name).joined(separator: ", ") }

    /// Which optional columns have anything to show somewhere in the list. A column nobody has data for is not drawn, so rows stay aligned.
    struct Data: Equatable, Sendable {
        var artist = true, album = true, duration = true
        static let all = Data()
    }

    static func data(for tracks: [MusicTrack]) -> Data {
        guard !tracks.isEmpty else { return .all }
        return Data(artist: tracks.contains { !artists(of: $0).isEmpty },
                    album: tracks.contains { !($0.album?.title ?? "").isEmpty },
                    duration: tracks.contains { $0.durationMs > 0 })
    }

    static let missingDuration = "--:--"

    /// The duration cell: the clock when known; the dash text only when the column is drawn and this row lacks one.
    static func durationText(ms: Int64, columnShown: Bool) -> String? {
        if ms > 0 { return MusicTime.clock(ms: ms) }
        return columnShown ? missingDuration : nil
    }
}

// MARK: - the two columns

enum MusicSearchBalance {
    static let songRowHeight: CGFloat = 56
    static let topCardHeight: CGFloat = 160
    static let artistRowHeight: CGFloat = 56
    static let headerHeight: CGFloat = 36
    static let maxArtists = 4

    /// How many artists the left column shows under the Top result so it matches the length of the songs list beside it. 0 when the layout is a
    /// single column, there are no artists, or the songs are too few to leave room (the full-width Artists row then shows them).
    static func leftArtists(sideBySide: Bool, songRows: Int, artists: Int) -> Int {
        guard sideBySide, artists > 0, songRows > 0 else { return 0 }
        let room = CGFloat(songRows) * songRowHeight - topCardHeight - headerHeight
        let fit = Int((room / artistRowHeight).rounded(.down))
        return min(maxArtists, artists, max(0, fit))
    }
}

// MARK: - repeated covers

enum MusicResultDedupe {
    /// The address of a cover without its size or cache parts, so two sizes of one picture compare equal.
    static func coverKey(_ thumbs: [MusicThumbnail]) -> String? {
        guard var u = thumbs.first?.url.lowercased(), !u.isEmpty else { return nil }
        if let q = u.firstIndex(of: "?") { u = String(u[..<q]) }
        if let e = u.firstIndex(of: "=") { u = String(u[..<e]) }
        return u
    }

    /// Titles this alike are the same item listed twice.
    static let sameTitle = 0.85

    /// Thins a row of items: one with the same title as an earlier one is dropped; one that only shares a cover keeps its place but shows its own
    /// designed cover instead of repeating the picture.
    static func thin<T>(_ items: [T], title: (T) -> String, thumbs: (T) -> [MusicThumbnail], clearing: (T) -> T) -> [T] {
        var kept: [T] = [], covers = Set<String>()
        for item in items {
            let name = title(item)
            if kept.contains(where: { MusicSearchScoring.similarity(title($0), name) >= sameTitle }) { continue }
            if let key = coverKey(thumbs(item)), !covers.insert(key).inserted { kept.append(clearing(item)) } else { kept.append(item) }
        }
        return kept
    }

    static func playlists(_ list: [MusicPlaylist]) -> [MusicPlaylist] {
        thin(list, title: \.name, thumbs: \.thumbnails) { var p = $0; p.thumbnails = []; return p }
    }

    static func albums(_ list: [MusicAlbum]) -> [MusicAlbum] {
        thin(list, title: { $0.title + " " + ($0.artists.first?.name ?? "") }, thumbs: \.thumbnails) { var a = $0; a.thumbnails = []; return a }
    }
}
