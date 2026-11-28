import Foundation

/// One still or poster of a film, from the film's own image list. It carries no caption: the gallery shows pictures only.
struct MusicFilmGalleryImage: Hashable, Sendable, Identifiable {
    enum Kind: String, Sendable { case backdrop = "b", poster = "p" }
    var kind: Kind
    /// The image's path on the image host (starts with "/").
    var path: String
    var id: String { kind.rawValue + path }
    var thumbURL: String { Self.base + (kind == .backdrop ? "w500" : "w342") + path }
    var fullURL: String { Self.base + (kind == .backdrop ? "w1280" : "w780") + path }
    var aspect: CGFloat { kind == .backdrop ? 16.0 / 9.0 : 2.0 / 3.0 }
    static let base = "https://image.tmdb.org/t/p/"
}

/// Reading and storing a film's gallery. The source's `images` block gives backdrops and posters; only picture-only backdrops (no language, so no printed
/// text) are kept, and posters up to a small cap. Stored as one attribute so the page reads it like every other film fact.
enum MusicFilmGallery {
    static let maxBackdrops = 16
    static let maxPosters = 8

    /// `images` is the object of a movie reply's `images` block.
    static func parse(images: Any?) -> [MusicFilmGalleryImage] {
        guard let j = images as? [String: Any] else { return [] }
        func paths(_ key: String, textless: Bool, cap: Int) -> [String] {
            let rows = (j[key] as? [[String: Any]]) ?? []
            var out: [String] = []
            for r in rows {
                guard let p = r["file_path"] as? String, p.hasPrefix("/"), !out.contains(p) else { continue }
                if textless, let l = r["iso_639_1"] as? String, !l.isEmpty { continue }
                out.append(p)
                if out.count >= cap { break }
            }
            return out
        }
        let backdrops = paths("backdrops", textless: true, cap: maxBackdrops).map { MusicFilmGalleryImage(kind: .backdrop, path: $0) }
        let posters = paths("posters", textless: false, cap: maxPosters).map { MusicFilmGalleryImage(kind: .poster, path: $0) }
        return backdrops + posters
    }

    static func encode(_ images: [MusicFilmGalleryImage]) -> String? {
        images.isEmpty ? nil : images.map { $0.kind.rawValue + $0.path }.joined(separator: "|")
    }

    static func decode(_ text: String?) -> [MusicFilmGalleryImage] {
        guard let text, !text.isEmpty else { return [] }
        var seen = Set<String>()
        var out: [MusicFilmGalleryImage] = []
        for part in text.split(separator: "|") {
            guard let first = part.first, let kind = MusicFilmGalleryImage.Kind(rawValue: String(first)) else { continue }
            let path = String(part.dropFirst())
            guard path.hasPrefix("/"), seen.insert(String(part)).inserted else { continue }
            out.append(MusicFilmGalleryImage(kind: kind, path: path))
        }
        return out
    }

    /// The image before or after `index`, wrapping round; nil for an empty list.
    static func step(_ index: Int, by delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return ((index + delta) % count + count) % count
    }
}
