import Foundation

// Playlist tools as pure functions over lists of songs: finding the same recording twice, merging lists, and the numbers a playlist page shows. Nothing here
// reads the library or the disk, so each rule is tested on its own.

/// The same recording appearing more than once in a list (the same song id, the same ISRC, or the same title and artists at about the same length). A remix,
/// a live version or "from the film" copy is a different recording: it carries its own wording in the title, so it never counts as a repeat of the original.
enum MusicPlaylistDuplicates {
    /// Two copies of one recording differ in length by no more than this.
    static let lengthToleranceMs: Int64 = 4_000

    struct Group: Equatable, Sendable {
        /// Indices into the list, in list order. The first is the one a clean-up keeps.
        var indices: [Int]
        var tracks: [MusicTrack]
        var count: Int { indices.count }
    }

    static func titleKey(_ t: MusicTrack) -> String {
        let artists = t.artists.map { MusicText.normalize($0.name) }.filter { !$0.isEmpty }.sorted().joined(separator: ",")
        return MusicText.normalize(t.title) + "|" + artists
    }

    /// True when `a` and `b` are the same recording.
    static func same(_ a: MusicTrack, _ b: MusicTrack) -> Bool {
        if a.uid == b.uid { return true }
        if let x = a.isrc?.uppercased(), !x.isEmpty, x == b.isrc?.uppercased() { return true }
        guard titleKey(a) == titleKey(b), !MusicText.normalize(a.title).isEmpty else { return false }
        // A missing length (0) cannot tell two songs apart.
        if a.durationMs <= 0 || b.durationMs <= 0 { return true }
        return abs(a.durationMs - b.durationMs) <= lengthToleranceMs
    }

    /// Every set of songs that are the same recording, in the order the first of each appears.
    static func groups(_ tracks: [MusicTrack]) -> [Group] {
        var groups: [[Int]] = []
        // Bucketed by title key so a long list is not compared pair by pair.
        var byKey: [String: [Int]] = [:]
        var byISRC: [String: Int] = [:]
        var byUID: [String: Int] = [:]
        var owner: [Int: Int] = [:]   // track index -> group index
        for (i, t) in tracks.enumerated() {
            var g: Int?
            if let k = byUID[t.uid] { g = k }
            if g == nil, let x = t.isrc?.uppercased(), !x.isEmpty, let k = byISRC[x] { g = k }
            if g == nil {
                for j in byKey[titleKey(t)] ?? [] where same(tracks[j], t) { g = owner[j]; break }
            }
            if let g {
                groups[g].append(i); owner[i] = g
            } else {
                groups.append([i]); owner[i] = groups.count - 1
            }
            let gi = owner[i]!
            byUID[t.uid] = byUID[t.uid] ?? gi
            if let x = t.isrc?.uppercased(), !x.isEmpty { byISRC[x] = byISRC[x] ?? gi }
            byKey[titleKey(t), default: []].append(i)
        }
        return groups.filter { $0.count > 1 }.map { Group(indices: $0, tracks: $0.map { tracks[$0] }) }
    }

    /// The list with every repeat taken out (the first copy stays), and the copies that were taken out.
    static func removing(_ tracks: [MusicTrack]) -> (kept: [MusicTrack], removed: [MusicTrack]) {
        let drop = Set(groups(tracks).flatMap { $0.indices.dropFirst() })
        guard !drop.isEmpty else { return (tracks, []) }
        var kept: [MusicTrack] = [], removed: [MusicTrack] = []
        for (i, t) in tracks.enumerated() { if drop.contains(i) { removed.append(t) } else { kept.append(t) } }
        return (kept, removed)
    }

    /// How many songs a clean-up would take out.
    static func extraCopies(_ tracks: [MusicTrack]) -> Int { groups(tracks).reduce(0) { $0 + $1.count - 1 } }
}

/// Combining playlists into one list of songs.
enum MusicPlaylistMerge {
    /// The lists one after the other, in the order given. With `dropRepeats` a recording that appears again later is left out.
    static func merge(_ lists: [[MusicTrack]], dropRepeats: Bool = true) -> [MusicTrack] {
        let all = lists.flatMap { $0 }
        return dropRepeats ? MusicPlaylistDuplicates.removing(all).kept : all
    }

    /// The name for a merged playlist: the first names joined, kept short.
    static func name(for names: [String], limit: Int = 60) -> String {
        let clean = names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !clean.isEmpty else { return "" }
        let joined = clean.prefix(3).joined(separator: " + ") + (clean.count > 3 ? " +\(clean.count - 3)" : "")
        return joined.count <= limit ? joined : String(joined.prefix(limit - 1)) + "…"
    }
}

/// The numbers a playlist page can show: how big it is and how it has been listened to.
enum MusicPlaylistListening {
    struct Summary: Equatable, Sendable {
        var songs = 0
        var totalSeconds = 0
        var artists = 0
        var albums = 0
        /// Plays in the history of songs that are in this playlist (from anywhere).
        var plays = 0
        /// How many of the playlist's songs were played at least once.
        var songsPlayed = 0
        var neverPlayed = 0
        var lastPlayed: Date?
        var topArtists: [(name: String, songs: Int)] = []
        var longestSeconds = 0
        var shortestSeconds = 0
        var repeats = 0

        static func == (a: Summary, b: Summary) -> Bool {
            a.songs == b.songs && a.totalSeconds == b.totalSeconds && a.artists == b.artists && a.albums == b.albums && a.plays == b.plays && a.songsPlayed == b.songsPlayed
                && a.neverPlayed == b.neverPlayed && a.lastPlayed == b.lastPlayed && a.longestSeconds == b.longestSeconds && a.shortestSeconds == b.shortestSeconds
                && a.repeats == b.repeats && a.topArtists.map(\.name) == b.topArtists.map(\.name) && a.topArtists.map(\.songs) == b.topArtists.map(\.songs)
        }
    }

    static func summary(tracks: [MusicTrack], history: [PlayRecord], topArtistLimit: Int = 3) -> Summary {
        var s = Summary()
        s.songs = tracks.count
        s.totalSeconds = tracks.reduce(0) { $0 + Int(max(0, $1.durationMs) / 1000) }
        let lengths = tracks.map { Int(max(0, $0.durationMs) / 1000) }.filter { $0 > 0 }
        s.longestSeconds = lengths.max() ?? 0
        s.shortestSeconds = lengths.min() ?? 0
        s.repeats = MusicPlaylistDuplicates.extraCopies(tracks)
        var artistCounts: [String: (name: String, n: Int)] = [:]
        var albumKeys = Set<String>()
        for t in tracks {
            for a in t.artists where !MusicArtistFiller.isFiller(a.name) {
                let k = a.id.isEmpty ? MusicText.normalize(a.name) : a.id
                artistCounts[k, default: (a.name, 0)].n += 1
            }
            if let al = t.album { albumKeys.insert(al.id.isEmpty ? MusicText.normalize(al.title) : al.id) }
        }
        s.artists = artistCounts.count
        s.albums = albumKeys.count
        s.topArtists = artistCounts.values.sorted { $0.n != $1.n ? $0.n > $1.n : $0.name < $1.name }.prefix(topArtistLimit).map { ($0.name, $0.n) }
        let uids = Set(tracks.map(\.uid))
        var played = Set<String>()
        for r in history where uids.contains(r.track.uid) {
            s.plays += 1
            played.insert(r.track.uid)
            if s.lastPlayed.map({ r.at > $0 }) ?? true { s.lastPlayed = r.at }
        }
        s.songsPlayed = played.count
        s.neverPlayed = uids.count - played.count
        return s
    }

    /// "2 h 5 min" or "47 min" or "3 min 20 s" in the person's own units; empty for nothing.
    static func lengthWords(seconds: Int) -> String {
        guard seconds > 0 else { return "" }
        let h = seconds / 3600, m = (seconds % 3600) / 60, sec = seconds % 60
        if h > 0 { return m > 0 ? "\(h) h \(m) min" : "\(h) h" }
        if m >= 10 || sec == 0 { return "\(max(1, m)) min" }
        return m > 0 ? "\(m) min \(sec) s" : "\(sec) s"
    }
}
