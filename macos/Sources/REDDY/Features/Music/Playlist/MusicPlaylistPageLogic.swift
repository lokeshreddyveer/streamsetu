import Foundation

// Pure rules of the playlist page: the stat line, the cover picker, filter and sort, the clock text of a length, seeds and picks for "More like this",
// and what the action row may offer. No views, no network, so every rule is tested with generated playlists.

/// The quiet line under a playlist's title: "128 songs · 8 hr 12 min · 1,204 saves · Updated 3 days ago". Only what is known is said.
enum MusicPlaylistStats {
    struct Input: Equatable, Sendable {
        var songCount: Int
        var totalMs: Int64 = 0
        /// False while more pages are still to come: the total length of the loaded songs would be too short, so it is left out.
        var lengthIsComplete = true
        var saves: Int?
        var updated: Date?
        /// The word before the date: "Updated" for a service's list, "Created" for one that only knows when it was made.
        var dateIsCreation = false
    }

    static func line(_ i: Input, now: Date = Date(), locale: Locale = .current) -> String {
        var parts: [String] = []
        parts.append(Localized.plural(max(0, i.songCount), one: "%@ song", other: "%@ songs"))
        if i.totalMs > 0, i.lengthIsComplete { parts.append(MusicDurationText.total(ms: i.totalMs)) }
        if let s = i.saves, s > 0 { parts.append(Localized.plural(s, one: "%@ save", other: "%@ saves")) }
        if let d = i.updated, d.timeIntervalSince1970 > 86_400 {
            let f = RelativeDateTimeFormatter()
            f.locale = locale
            f.unitsStyle = .full
            let rel = f.localizedString(for: min(d, now), relativeTo: now)
            parts.append(Localized.string(i.dateIsCreation ? "Created %@" : "Updated %@", rel))
        }
        return parts.joined(separator: " · ")
    }

    /// The loaded songs' total length in milliseconds.
    static func totalMs(_ tracks: [MusicTrack]) -> Int64 { tracks.reduce(Int64(0)) { $0 + max(0, $1.durationMs) } }
}

/// "3:45" and "1:02:03": the length of one song in a column.
enum MusicPlaylistClock {
    static func text(ms: Int64) -> String {
        let total = Int(max(0, ms) / 1000)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Which covers make a playlist's picture: one cover per distinct album (six songs of one album are one cover, not four), in playlist order.
enum MusicPlaylistCoverPicker {
    /// The cover sets of the first songs of each distinct album, front to back, at most `limit`. Songs with no album count as their own cover address.
    static func representatives(_ tracks: [MusicTrack], limit: Int = MusicPlaylistCoverPlan.scanLimit) -> [[MusicThumbnail]] {
        var seen = Set<String>(), out: [[MusicThumbnail]] = []
        for t in tracks.prefix(4_000) where !t.thumbnails.isEmpty {
            let key = albumKey(t)
            if seen.insert(key).inserted { out.append(t.thumbnails) }
            if out.count >= limit { break }
        }
        return out
    }

    static func albumKey(_ t: MusicTrack) -> String {
        if let a = t.album, !a.id.isEmpty { return "album:" + t.providerID + ":" + a.id }
        if let a = t.album, !a.title.isEmpty { return "title:" + a.title.lowercased() + "|" + t.artistLine.lowercased() }
        return "cover:" + (t.thumbnails.first.map { MusicArtworkURLSizing.identity($0.url) } ?? t.uid)
    }

    /// The plan the cover will follow: a 2x2 for four distinct covers, one cover for fewer, the designed tile for none.
    static func plan(_ tracks: [MusicTrack]) -> MusicPlaylistCoverPlan {
        MusicPlaylistCoverPlan.make(memberCovers: representatives(tracks).map { MusicArtworkService.pickThumbnail($0, neededPixels: 256) })
    }
}

/// What the page shows of the songs: filter first, then order. Wraps the shared list kit rules so the page and its tests agree with the list.
enum MusicPlaylistListLogic {
    static func visible(_ tracks: [MusicTrack], query: String, ordering: MusicTrackOrdering) -> [MusicTrack] {
        ordering.apply(MusicTrackFilter.apply(tracks, query: query))
    }

    /// "12 of 340" while a filter hides some songs.
    static func filterCount(shown: Int, total: Int) -> String? {
        shown < total ? Localized.string("%1$@ of %2$@", shown.formatted(), total.formatted()) : nil
    }

    /// Dragging to reorder: only the person's own playlist, only in its own order, with no filter and nothing half loaded.
    static func canReorder(editable: Bool, ordering: MusicTrackOrdering, filtering: Bool, selecting: Bool) -> Bool {
        editable && ordering.field == .original && ordering.ascending && !filtering && !selecting
    }

    /// Songs Play and Shuffle may use: every song of the list, whole (never just the first page), without the ones known not to play.
    static func playable(_ tracks: [MusicTrack], failed: Set<String>) -> [MusicTrack] {
        failed.isEmpty ? tracks : tracks.filter { !failed.contains($0.uid) }
    }
}

/// What the header's action row offers for a list of this size.
enum MusicPlaylistActionRules {
    /// Downloading a whole playlist is offered up to this many songs; a longer one is downloaded from a selection.
    static let downloadAllLimit = 500
    static func canDownloadAll(count: Int) -> Bool { count > 0 && count <= downloadAllLimit }
    /// The description is clamped to three lines; "More" appears when it could be longer than that.
    static func descriptionNeedsMore(_ text: String, compact: Bool) -> Bool {
        text.count > (compact ? 110 : 190) || text.filter(\.isNewline).count >= 3
    }
    /// A name for a copy of a playlist.
    static func copyName(_ name: String) -> String { Localized.string("%@ copy", name) }
}

/// "More like this": which songs of the playlist seed the recommendations and which recommended songs are kept.
enum MusicPlaylistSuggestions {
    static let seedCount = 5
    static let keepCount = 8

    /// Up to `seedCount` songs spread evenly over the whole list (front, middle, end), all from the provider of the first one
    /// (a provider's radio only knows its own ids).
    static func seeds(from tracks: [MusicTrack]) -> [MusicTrack] {
        guard let first = tracks.first else { return [] }
        let same = tracks.filter { $0.providerID == first.providerID }
        guard same.count > seedCount else { return same }
        var picked: [MusicTrack] = []
        let step = Double(same.count - 1) / Double(max(1, seedCount - 1))
        for k in 0..<seedCount {
            let t = same[min(same.count - 1, Int((Double(k) * step).rounded()))]
            if !picked.contains(where: { $0.uid == t.uid }) { picked.append(t) }
        }
        return picked
    }

    /// The recommended songs worth showing: not already in the playlist (nor another version of a song in it), no repeats, nothing the person blocked.
    static func select(_ candidates: [MusicTrack], existing: [MusicTrack], blocked: (MusicTrack) -> Bool, limit: Int = keepCount) -> [MusicTrack] {
        var taken = Set(existing.map(\.uid))
        var keys = Set(existing.prefix(5_000).map(MusicAutoplaySelector.versionKey))
        var out: [MusicTrack] = []
        for c in candidates where !blocked(c) {
            guard !taken.contains(c.uid) else { continue }
            let k = MusicAutoplaySelector.versionKey(c)
            guard keys.insert(k).inserted else { continue }
            taken.insert(c.uid)
            out.append(c)
            if out.count >= limit { break }
        }
        return out
    }
}
