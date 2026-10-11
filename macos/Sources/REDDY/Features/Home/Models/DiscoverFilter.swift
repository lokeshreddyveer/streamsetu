import Foundation

enum DiscoverMode: String, CaseIterable, Identifiable {
    case trending = "Trending", topRated = "Top Rated", recent = "Recently Released"
    var id: String { rawValue }
}

/// Language / region as the library itself describes it: the "(Telugu)" tags providers put in titles, and the words in
/// folder or genre names. Nothing is guessed from the title text itself.
enum LanguageTags {
    static let known = ["English", "Hindi", "Telugu", "Tamil", "Malayalam", "Kannada", "Bengali", "Marathi", "Punjabi", "Gujarati", "Urdu",
                        "Korean", "Japanese", "Chinese", "Turkish", "Arabic", "Spanish", "French", "German", "Italian", "Portuguese", "Russian", "Thai", "Indonesian"]

    static func languages(of item: LibraryItem) -> Set<String> {
        var found = Set<String>()
        let sources = [item.title, item.genre ?? ""]
        for text in sources {
            for lang in known where text.range(of: "\\b\(lang)\\b", options: [.regularExpression, .caseInsensitive]) != nil { found.insert(lang) }
        }
        return found
    }

    /// Languages present in the given shelves, most common first.
    static func available(in shelves: [DiscoverShelf]) -> [(language: String, count: Int)] {
        var counts: [String: Int] = [:]
        var seen = Set<String>()
        for shelf in shelves { for item in shelf.items where seen.insert(item.id).inserted { for l in languages(of: item) { counts[l, default: 0] += 1 } } }
        return counts.map { (language: $0.key, count: $0.value) }.sorted { ($0.count, $1.language) > ($1.count, $0.language) }
    }
}

/// What the Discover toolbar chooses. It only reorders and narrows the rails; it never touches the slideshow.
struct DiscoverFilter: Equatable {
    var mode: DiscoverMode = .trending
    var language: String?
    var query = ""

    var isDefault: Bool { mode == .trending && language == nil && query.trimmingCharacters(in: .whitespaces).isEmpty }

    func apply(to shelves: [DiscoverShelf]) -> [DiscoverShelf] {
        let q = MetadataNormalizer.normalize(query)
        return shelves.compactMap { shelf in
            var items = shelf.items
            if let language { items = items.filter { LanguageTags.languages(of: $0).contains(language) } }
            if !q.isEmpty { items = items.filter { MetadataNormalizer.normalize($0.title).contains(q) } }
            switch mode {
            case .trending: break                                                   // the shelf's own order
            case .topRated: items = items.enumerated().sorted { (Self.rating($0.element), $1.offset) > (Self.rating($1.element), $0.offset) }.map(\.element)
            case .recent: items = items.enumerated().sorted { ($0.element.year ?? 0, $1.offset) > ($1.element.year ?? 0, $0.offset) }.map(\.element)
            }
            guard !items.isEmpty else { return nil }
            let caption: String
            switch mode {
            case .trending: caption = shelf.caption
            case .topRated: caption = "\(shelf.title) re-sorted by your provider's rating · not a chart"
            case .recent: caption = "\(shelf.title) re-sorted by release year · not a chart"
            }
            return DiscoverShelf(id: shelf.id, title: shelf.title, caption: caption, items: items, ranked: shelf.ranked && mode == .trending && language == nil && q.isEmpty)
        }
    }

    static func rating(_ item: LibraryItem) -> Double {
        switch item { case .movie(let m): Double(m.rating ?? "") ?? 0; case .series(let s): Double(s.rating ?? "") ?? 0 }
    }

    /// The order the slideshow draws from: the library's own top-rated shelves, interleaved, then the rest of Trending.
    static func slideshowOrder(_ shelves: [DiscoverShelf]) -> [LibraryItem] {
        func items(_ id: String) -> [LibraryItem] { shelves.first { $0.id == id }?.items ?? [] }
        let movies = items("top-movies"), shows = items("top-shows"), trending = items("trending")
        var out: [LibraryItem] = []
        for i in 0..<max(movies.count, shows.count) { if i < movies.count { out.append(movies[i]) }; if i < shows.count { out.append(shows[i]) } }
        out += trending
        for shelf in shelves where !["top-movies", "top-shows", "trending"].contains(shelf.id) { out += shelf.items }
        return out
    }
}
