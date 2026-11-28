import Foundation

/// What the person's plays, likes and follows say about their taste, as weights. Each counted play weighs half as much for every 30 days it is old;
/// a like is worth three plays and a follow five. Songs are merged by recording (the same song from two providers is one), so the weights do not split.
/// Nothing here asks a server and nothing leaves the device.
struct HomeTaste: Sendable {
    struct TrackStat: Sendable {
        var track: MusicTrack
        var key: String
        var weight: Double
        var plays: Int
        var recentPlays: Int
        var lastPlay: Date?
        var liked: Bool
        /// Counted plays in morning, afternoon, evening and night (index by `DayPart.rawValue`).
        var dayPlays: [Int]
    }

    struct ArtistStat: Sendable {
        var key: String
        var name: String
        var ref: MusicArtistRef
        var providerID: String
        var weight: Double
        var followed: Bool
        /// Counted plays of this artist's songs (an artist heard once is not loved).
        var plays = 0
    }

    enum DayPart: Int, Sendable, CaseIterable {
        case morning, afternoon, evening, night
        static func of(hour: Int) -> DayPart { switch hour { case 5..<12: .morning; case 12..<17: .afternoon; case 17..<22: .evening; default: .night } }
    }

    static let halfLifeDays = 30.0
    static let likeWorth = 3.0
    static let followWorth = 5.0
    static let recentWindowDays = 14.0

    /// Tracks, strongest first (ties by key, so the order never depends on a dictionary).
    var tracks: [TrackStat] = []
    var artists: [ArtistStat] = []
    /// The share of the person's own weight in each bucket (sums to 1; empty with no data). Used for spread, never shown.
    var bucketShare: [String: Double] = [:]
    var countedPlays = 0
    var daypart: DayPart = .morning

    /// A play counts when at least half the song was heard (30 seconds when the length is not known).
    static func counts(_ r: PlayRecord) -> Bool {
        let length = r.track.durationMs
        return length > 0 ? r.playedMs * 2 >= length : r.playedMs >= 30_000
    }

    /// One rule for "this play shapes the taste": not a podcast episode, not dated in the future (a clock that was wrong), and heard for long enough. The engine and
    /// the feed model's "has this person started" test both use it, so they cannot disagree about who is a new listener.
    static func shapesTaste(_ r: PlayRecord, now: Date) -> Bool {
        r.at <= now.addingTimeInterval(3600) && !(r.track.isPodcast ?? false) && counts(r)
    }

    static func build(history: [PlayRecord], liked: [MusicTrack], followed: [MusicArtist], now: Date, calendar: Calendar = .current) -> HomeTaste {
        var t = HomeTaste()
        t.daypart = DayPart.of(hour: calendar.component(.hour, from: now))
        var stats: [String: TrackStat] = [:]
        var artistW: [String: ArtistStat] = [:]

        func addArtists(of track: MusicTrack, weight: Double, counted: Bool = false) {
            // A video upload's channel (an id that starts with UC) is the uploader, not the artist.
            for ref in track.artists.prefix(2) where MusicCompilationArtist.isUsableArtist(ref) && !ref.name.isEmpty && !ref.isUploaderChannel(of: track) {
                let k = HomeKeys.fold(ref.name)
                guard !k.isEmpty else { continue }
                var e = artistW[k] ?? ArtistStat(key: k, name: ref.name, ref: ref, providerID: track.providerID, weight: 0, followed: false)
                e.weight += weight
                if counted { e.plays += 1 }
                if e.ref.id.isEmpty, !ref.id.isEmpty { e.ref = ref; e.providerID = track.providerID }
                artistW[k] = e
            }
        }

        for r in history where shapesTaste(r, now: now) {
            let age = max(0, now.timeIntervalSince(r.at)) / 86_400
            let w = pow(0.5, age / halfLifeDays)
            let key = HomeKeys.recording(r.track)
            var e = stats[key] ?? TrackStat(track: r.track, key: key, weight: 0, plays: 0, recentPlays: 0, lastPlay: nil, liked: false, dayPlays: [0, 0, 0, 0])
            e.weight += w; e.plays += 1
            if age <= recentWindowDays { e.recentPlays += 1 }
            if e.lastPlay == nil || r.at > e.lastPlay! { e.lastPlay = r.at; e.track = r.track }
            e.dayPlays[DayPart.of(hour: calendar.component(.hour, from: r.at)).rawValue] += 1
            stats[key] = e
            t.countedPlays += 1
            addArtists(of: r.track, weight: w, counted: true)
        }
        for l in liked where !(l.isPodcast ?? false) {
            let key = HomeKeys.recording(l)
            var e = stats[key] ?? TrackStat(track: l, key: key, weight: 0, plays: 0, recentPlays: 0, lastPlay: nil, liked: false, dayPlays: [0, 0, 0, 0])
            if !e.liked { e.weight += likeWorth; addArtists(of: l, weight: likeWorth) }
            e.liked = true
            stats[key] = e
        }
        for f in followed where !f.name.isEmpty {
            let k = HomeKeys.fold(f.name)
            var e = artistW[k] ?? ArtistStat(key: k, name: f.name, ref: MusicArtistRef(id: f.id, name: f.name, thumbnails: f.thumbnails), providerID: f.providerID, weight: 0, followed: true)
            e.weight += followWorth; e.followed = true
            if e.ref.id.isEmpty { e.ref = MusicArtistRef(id: f.id, name: f.name, thumbnails: f.thumbnails); e.providerID = f.providerID }
            if e.ref.thumbnails.isEmpty { e.ref.thumbnails = f.thumbnails }
            artistW[k] = e
        }

        t.tracks = stats.values.sorted { $0.weight != $1.weight ? $0.weight > $1.weight : $0.key < $1.key }
        t.artists = artistW.values.sorted { $0.weight != $1.weight ? $0.weight > $1.weight : $0.key < $1.key }
        var share: [String: Double] = [:]
        var total = 0.0
        for s in t.tracks {
            let b = HomeKeys.bucket(s.track)
            guard !b.isEmpty else { continue }
            share[b, default: 0] += s.weight; total += s.weight
        }
        if total > 0 { t.bucketShare = share.mapValues { $0 / total } }
        return t
    }

    /// The weight for drawing a song for a mix: its own weight, nudged up a quarter when the person plays it at this time of day.
    func drawWeight(_ s: TrackStat) -> Double {
        let nudge = s.dayPlays[daypart.rawValue] > 0 ? 1.25 : 1.0
        return max(0.001, s.weight) * nudge * (s.liked ? 1.3 : 1.0)
    }

    func artistWeight(named name: String) -> Double { artists.first { $0.key == HomeKeys.fold(name) }?.weight ?? 0 }
    var topArtistWeight: Double { artists.first?.weight ?? 0 }
    func isFamiliar(artistKey: String) -> Bool { !artistKey.isEmpty && artists.contains { $0.key == artistKey } }
}

/// Everything the person has ever played, whatever a reset hides from the taste weights: a shelf stops learning from old plays, but it never says
/// "not played" or "not heard for a while" about something that was. A play of any length counts: half a song heard is a song heard.
struct HomeHeard: Sendable {
    /// Recording ("isrc:", "rec:"), provider uid, album ("alb:") and artist ("art:") keys, each with the last time it was played.
    private var last: [String: Date] = [:]

    init(_ histories: [[PlayRecord]]) {
        // One pass keeps the newest play of each song, so the keys (which fold text) are worked out once per song, not once per play.
        var newest: [String: (track: MusicTrack, at: Date)] = [:]
        for history in histories {
            for r in history where r.at > (newest[r.track.uid]?.at ?? .distantPast) { newest[r.track.uid] = (r.track, r.at) }
        }
        for (track, at) in newest.values {
            var keys = Self.keys(of: track)
            if let a = track.album { keys.append("alb:" + HomeKeys.fold(a.title) + "|" + HomeKeys.fold((a.artists.first ?? track.artists.first)?.name ?? "")) }
            for ref in track.artists.prefix(2) where !ref.name.isEmpty { keys.append("art:" + HomeKeys.fold(ref.name)) }
            for k in keys { last[k] = max(last[k] ?? .distantPast, at) }
        }
    }

    /// Every spelling a song may have been played under: the same recording from another source has another uid, and may carry no ISRC.
    private static func keys(of t: MusicTrack) -> [String] {
        [HomeKeys.recording(t), "rec:" + HomeKeys.fold(t.title) + "|" + HomeKeys.fold(t.artists.first?.name ?? ""), HomeKeys.provider(t.uid)]
    }

    func has(_ key: String) -> Bool { last[key] != nil }
    func has(_ t: MusicTrack) -> Bool { Self.keys(of: t).contains { last[$0] != nil } }
    func lastPlay(_ t: MusicTrack) -> Date? { Self.keys(of: t).compactMap { last[$0] }.max() }
}

extension HomeTaste {
    /// Every artist id the person's songs and follows give one artist name (the same artist has one id per source), for cards found by that name.
    func refs(for artist: ArtistStat, followed: [MusicArtist] = []) -> [MusicArtistRef] {
        var out = [MusicArtistRef(id: artist.ref.id, name: artist.name)]
        var seen: Set<String> = [artist.ref.id]
        let others = tracks.flatMap(\.track.artists) + followed.map { MusicArtistRef(id: $0.id, name: $0.name) }
        for r in others where !r.id.isEmpty && HomeKeys.fold(r.name) == artist.key && seen.insert(r.id).inserted { out.append(MusicArtistRef(id: r.id, name: artist.name)) }
        return out
    }
}
