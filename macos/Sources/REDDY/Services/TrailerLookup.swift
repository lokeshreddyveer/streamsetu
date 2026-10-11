import Foundation

/// Finds an official trailer clip with no account or key: Apple's public iTunes catalogue lists a preview video for most films
/// and TV seasons it sells. Regional titles are often missing, which is why a TMDB key or a provider trailer is tried first.
enum TrailerLookup {
    /// "Maremma (2026) (Hindi)" -> "maremma"
    static func cleanTitle(_ t: String) -> String {
        var s = t
        while let r = s.range(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, options: .regularExpression) { s.removeSubrange(r) }
        return s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func previewURL(from data: Data, title: String, year: Int?) -> URL? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = obj["results"] as? [[String: Any]] else { return nil }
        let want = cleanTitle(title)
        for row in rows {
            let name = (row["trackName"] as? String) ?? (row["collectionName"] as? String) ?? ""
            let base = cleanTitle(name.components(separatedBy: ", Season").first ?? name)
            guard base == want, let p = row["previewUrl"] as? String, let url = URL(string: p), url.scheme == "https" else { continue }
            if let year, let d = row["releaseDate"] as? String, let y = Int(d.prefix(4)), abs(y - year) > 1 { continue }
            return url
        }
        return nil
    }

    static func find(title: String, year: Int?, isSeries: Bool, session: URLSession = .shared) async -> URL? {
        var c = URLComponents(string: "https://itunes.apple.com/search")
        c?.queryItems = [URLQueryItem(name: "term", value: cleanTitle(title)), URLQueryItem(name: "media", value: isSeries ? "tvShow" : "movie"),
                         URLQueryItem(name: "entity", value: isSeries ? "tvSeason" : "movie"), URLQueryItem(name: "limit", value: "8")]
        guard let url = c?.url, let (data, resp) = try? await session.data(from: url), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return previewURL(from: data, title: title, year: year)
    }
}
