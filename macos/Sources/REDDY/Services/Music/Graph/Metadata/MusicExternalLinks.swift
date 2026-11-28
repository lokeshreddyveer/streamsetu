import Foundation

/// Reads the ids out of the addresses that MusicBrainz, ListenBrainz and Wikidata list as links. Pure.
enum MusicExternalLinks {
    static func externalID(fromURL raw: String) -> ExternalID? {
        guard let u = URL(string: raw), let host = u.host?.lowercased() else { return nil }
        let parts = u.path.split(separator: "/").map(String.init)
        func last(after key: String) -> String? { parts.firstIndex(of: key).flatMap { $0 + 1 < parts.count ? parts[$0 + 1] : nil } }
        if host.hasSuffix("wikidata.org") {
            let q = parts.last ?? ""
            return q.hasPrefix("Q") && q.dropFirst().allSatisfy(\.isNumber) ? ExternalID(.wikidata, q) : nil
        }
        if host.hasSuffix("imdb.com") {
            if let t = last(after: "title"), t.hasPrefix("tt") { return ExternalID(.imdbTitle, t) }
            if let n = last(after: "name"), n.hasPrefix("nm") { return ExternalID(.imdbName, n) }
            return nil
        }
        if host.hasSuffix("themoviedb.org") {
            func id(_ s: String?) -> String? { s.flatMap { $0.split(separator: "-").first.map(String.init) }.flatMap { Int($0) != nil ? $0 : nil } }
            if let v = id(last(after: "movie")) { return ExternalID(.tmdbMovie, v) }
            if let v = id(last(after: "tv")) { return ExternalID(.tmdbTV, v) }
            if let v = id(last(after: "person")) { return ExternalID(.tmdbPerson, v) }
            return nil
        }
        if host.hasSuffix("discogs.com") {
            for kind in ["artist", "master", "release"] { if let v = last(after: kind) { return ExternalID(.discogs, kind + "/" + (v.split(separator: "-").first.map(String.init) ?? v)) } }
            return nil
        }
        if host == "open.spotify.com", let v = last(after: "track") ?? last(after: "artist") ?? last(after: "album") { return ExternalID(.spotifyID, v) }
        if host == "music.apple.com", let v = parts.last, Int(v) != nil { return ExternalID(.appleID, v) }
        return nil
    }
}
