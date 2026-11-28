import Foundation

/// Turns the queue and the library into one autoplay request and its filters. Pure, so the rules (which song is the seed, what counts as
/// recent, what spacing starts from) are tested without a player.
enum MusicAutoplayBuilder {
    static let recentPlays = 100

    /// The song autoplay follows: the playing row, or when that row is itself an autoplay row, the last row the person chose before it,
    /// so a long autoplay run keeps the mood of the song that started it instead of drifting.
    static func anchor(entries: [MusicQueue.Entry], currentIndex: Int) -> MusicTrack? {
        guard entries.indices.contains(currentIndex) else { return nil }
        var i = currentIndex
        while i >= 0 {
            if !entries[i].auto, !entries[i].suggested { return entries[i].track }
            i -= 1
        }
        return entries[currentIndex].track
    }

    /// `history` and `recent` are newest first. Returns nil when nothing is playing.
    static func make(entries: [MusicQueue.Entry], currentIndex: Int?, recent: [MusicTrack], history: [MusicTrack], blocked: Set<String>,
                     offline: Bool, want: Int, randomSeed: UInt64? = nil,
                     allow: (@Sendable (MusicTrack) -> Bool)? = nil,
                     playableOffline: (@Sendable (MusicTrack) -> Bool)? = nil) -> (request: MusicAutoplayRequest, context: MusicAutoplayContext)? {
        guard let ci = currentIndex, entries.indices.contains(ci), let seed = anchor(entries: entries, currentIndex: ci) else { return nil }
        var request = MusicAutoplayRequest(seed: seed)
        let playing = entries[ci].track
        var recents: [MusicTrack] = []
        if playing.uid != seed.uid { recents.append(playing) }
        for t in recent where t.uid != seed.uid && !recents.contains(where: { $0.uid == t.uid }) && recents.count < 3 { recents.append(t) }
        request.recentSeeds = recents
        request.want = want
        request.offline = offline
        if let randomSeed { request.randomSeed = randomSeed }

        var ctx = MusicAutoplayContext()
        ctx.blocked = blocked
        ctx.recentUIDs = Set(history.prefix(recentPlays).map(\.uid))
        ctx.queuedUIDs = Set(entries.map(\.track.uid))
        ctx.queuedKeys = Set(entries.map { MusicAutoplaySelector.versionKey($0.track) })
        ctx.tailArtists = entries.suffix(MusicAutoplaySelector.artistWindow - 1).map { MusicAutoplaySelector.artistKeys($0.track) }
        ctx.familiarUIDs = Set(history.map(\.uid))
        ctx.familiarArtists = Set(history.flatMap { MusicAutoplaySelector.artistKeys($0) })
        ctx.profile = MusicLanguageProfile.build(from: Array(history.prefix(300)))
        ctx.allow = allow
        ctx.playableOffline = playableOffline
        ctx.seedArtistKeys = Set(MusicAutoplaySelector.artistKeys(seed))
        return (request, ctx)
    }
}

/// The remembered shuffle mode (one classified defaults key: add `music.shuffle.mode` to `MusicDefaultsKeys.deviceSettings`).
enum MusicShuffleModeStore {
    static let key = "music.shuffle.mode"
    static func load(_ d: UserDefaults = .standard) -> MusicShuffleMode { d.string(forKey: key).flatMap(MusicShuffleMode.init(rawValue:)) ?? .defaultMode }
    static func save(_ m: MusicShuffleMode, _ d: UserDefaults = .standard) { d.set(m.rawValue, forKey: key) }
}

extension MusicShuffleEngine {
    /// One 0...1 number for "how energetic" from what the Automix analysis holds (mean of its energy curve and the tempo). Read-only use.
    static func energy(bpm: Double, meanEnergy: Double?) -> Double? {
        let tempo = bpm >= 40 ? min(1, max(0, (bpm - 60) / 120)) : nil
        switch (meanEnergy, tempo) {
        case let (e?, t?): return min(1, max(0, 0.5 * e + 0.5 * t))
        case let (e?, nil): return min(1, max(0, e))
        case let (nil, t?): return t
        default: return nil
        }
    }
}
