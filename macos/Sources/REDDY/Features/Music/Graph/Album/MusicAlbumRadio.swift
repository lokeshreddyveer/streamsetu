import Foundation

extension MusicAlbumPageLogic {
    /// The songs a whole-album station is seeded from: up to `cap`, spread evenly over the album so the station reflects all of it and not only its opening track.
    nonisolated static func radioSeeds(_ tracks: [MusicTrack], cap: Int = 5) -> [MusicTrack] {
        guard cap > 0, !tracks.isEmpty else { return [] }
        if tracks.count <= cap { return tracks }
        let step = Double(tracks.count - 1) / Double(cap - 1 == 0 ? 1 : cap - 1)
        var picked: [MusicTrack] = []
        var seen = Set<String>()
        for i in 0..<cap {
            let t = tracks[min(tracks.count - 1, Int((Double(i) * step).rounded()))]
            if seen.insert(t.uid).inserted { picked.append(t) }
        }
        return picked
    }

    /// A release date that is a whole day ("2023-03-24"); a bare year or year and month stay out of the header (the year is already in the facts line).
    nonisolated static func fullDate(_ s: String) -> Date? {
        let day = String(s.prefix(10))
        guard day.count == 10 else { return nil }
        // Read from the digits, not through a formatter made for every header draw; a day that does not exist ("2023-02-30") is not a date.
        let parts = day.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 3, let y = parts[0], let m = parts[1], let d = parts[2] else { return nil }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let c = DateComponents(year: y, month: m, day: d)
        guard let date = cal.date(from: c), cal.dateComponents([.year, .month, .day], from: date) == c else { return nil }
        return date
    }

    /// The chosen songs that are not liked yet (liking is never a toggle here: a selection that includes liked songs does not unlike them).
    nonisolated static func toLike(_ tracks: [MusicTrack], isLiked: (MusicTrack) -> Bool) -> [MusicTrack] {
        var seen = Set<String>()
        return tracks.filter { !isLiked($0) && seen.insert($0.uid).inserted }
    }
}

extension MusicQueueActions {
    /// A station seeded from the whole album (a few songs spread over it), played through the normal radio service, queue and player.
    static func startAlbumRadio(_ tracks: [MusicTrack], title: String?, hub: MusicHub) async {
        let seeds = MusicAlbumPageLogic.radioSeeds(tracks).map { RadioSeed.song($0) }
        guard !seeds.isEmpty else { MusicToasts.shared.show(Localized.string("Nothing to play here yet.")); return }
        var station = RadioService.makeStation(seeds: seeds)
        if let title, !title.isEmpty { station.name = Localized.string("%@ Radio", title) }
        await hub.radio.start(station)
    }
}
