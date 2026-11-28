import Foundation

// Past concerts of an artist from setlist.fm (community-written setlists). Read-only: one GET per artist page, by MusicBrainz id. The key is the app's own,
// built in as scrambled bytes (Scripts/gen-builtin-key.py setlistfm); it travels in a header, never in a URL, a log or the source.

enum BuiltInSetlistFM {
    private static let underTest = Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
        || ProcessInfo.processInfo.arguments.contains { $0.contains(".xctest") }
    static func apiKey() -> String? {
        if underTest { return nil }
        #if STREAMSETU_BUILTIN_SETLISTFM
        return BuiltInTMDB.assemble(chunks: GeneratedSetlistFM.chunks, order: GeneratedSetlistFM.order, mask: GeneratedSetlistFM.mask)
        #else
        return nil
        #endif
    }
}

struct MusicConcert: Hashable, Identifiable, Sendable {
    struct Song: Hashable, Sendable {
        var name: String
        /// The original artist when the band played someone else's song.
        var coverOf: String?
        var encore: Bool
    }
    var id: String
    var date: Date?
    var venue: String
    var city: String
    var country: String
    var tour: String?
    var songs: [Song]
    /// setlist.fm's own page for this show, for the "Open on setlist.fm" link.
    var url: URL?

    var place: String { [venue, city, country].filter { !$0.isEmpty }.joined(separator: ", ") }
}

enum SetlistFMParser {
    /// "dd-MM-yyyy", the one date format setlist.fm sends.
    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, (1...31).contains(p[0]), (1...12).contains(p[1]), p[2] > 1900 else { return nil }
        var c = DateComponents(); c.day = p[0]; c.month = p[1]; c.year = p[2]; c.hour = 12
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal.date(from: c)
    }

    /// The setlists in one reply, newest first as the service sends them. A show without any song is kept (the venue and date still say something) but has an empty list.
    static func concerts(_ j: [String: Any]) -> [MusicConcert] {
        guard let list = j["setlist"] as? [[String: Any]] else { return [] }
        return list.compactMap { s in
            guard let id = s["id"] as? String else { return nil }
            let venue = s["venue"] as? [String: Any]
            let city = venue?["city"] as? [String: Any]
            let country = city?["country"] as? [String: Any]
            var songs: [MusicConcert.Song] = []
            let sets = ((s["sets"] as? [String: Any])?["set"] as? [[String: Any]]) ?? []
            for set in sets {
                let encore = (set["encore"] as? Int).map { $0 > 0 } ?? false
                for item in (set["song"] as? [[String: Any]]) ?? [] {
                    guard let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
                    songs.append(.init(name: name, coverOf: (item["cover"] as? [String: Any])?["name"] as? String, encore: encore))
                }
            }
            return MusicConcert(id: id, date: date(s["eventDate"] as? String), venue: (venue?["name"] as? String) ?? "", city: (city?["name"] as? String) ?? "",
                                country: (country?["name"] as? String) ?? "", tour: (s["tour"] as? [String: Any])?["name"] as? String, songs: songs,
                                url: (s["url"] as? String).flatMap { URL(string: $0) }.flatMap { $0.scheme == "https" ? $0 : nil })
        }
    }
}

struct SetlistFMClient: Sendable {
    var http = MusicHTTP()
    var key: @Sendable () -> String? = { BuiltInSetlistFM.apiKey() }
    var isAvailable: Bool { key() != nil }

    /// The most recent setlists of an artist (one page, up to 20). Empty when setlist.fm has none (it answers 404 then).
    func recentConcerts(mbid: String) async throws -> [MusicConcert] {
        guard let k = key() else { throw ScrobbleSendError.signedOut }
        guard mbid.count == 36, mbid.allSatisfy({ $0.isHexDigit || $0 == "-" }), let url = URL(string: "https://api.setlist.fm/rest/1.0/artist/\(mbid)/setlists?p=1") else {
            throw ScrobbleSendError.network("bad address")
        }
        let reply = try await ScrobbleHTTP.send(http, url: url, method: "GET", headers: ["x-api-key": k, "Accept": "application/json"])
        if reply.status == 404 { return [] }
        guard (200..<300).contains(reply.status), let obj = (try? JSONSerialization.jsonObject(with: reply.data)) as? [String: Any] else {
            throw ScrobbleSendError.network("HTTP \(reply.status)")
        }
        return SetlistFMParser.concerts(obj)
    }
}

/// Matches the songs of a setlist to songs the person already has, by title (and the artist when the track names one). Nothing is searched online here.
enum SetlistMatcher {
    static func key(_ s: String) -> String {
        var t = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        for cut in [" (", " - ", " ["] { if let r = t.range(of: cut) { t = String(t[..<r.lowerBound]) } }
        return String(t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// One track per setlist song at most, in setlist order; songs the person does not have are skipped. `pool` is searched in order, so earlier tracks win.
    static func match(_ concert: MusicConcert, artist: String, pool: [MusicTrack]) -> [MusicTrack] {
        let wanted = key(artist)
        var byTitle: [String: MusicTrack] = [:]
        for t in pool {
            let k = key(t.title)
            if k.isEmpty { continue }
            let byArtist = wanted.isEmpty || key(t.artistLine).contains(wanted)
            if byArtist, byTitle[k] == nil { byTitle[k] = t }
        }
        var seen = Set<String>(), out: [MusicTrack] = []
        for s in concert.songs {
            let k = key(s.name)
            if let t = byTitle[k], seen.insert(t.uid).inserted { out.append(t) }
        }
        return out
    }
}
