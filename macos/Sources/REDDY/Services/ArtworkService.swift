import Foundation
import CoreGraphics

/// Lazy artwork loading for the UI. Nothing is downloaded during import; images are fetched when first shown.
final class ArtworkService: Sendable {
    let cache: ImageCache
    init(cache: ImageCache) { self.cache = cache }

    func image(_ urlString: String?, kind: ArtworkKind) async -> CGImage? {
        guard let s = urlString.nilIfEmpty, let url = URL(string: s) else { return nil }
        return await cache.image(for: url, kind: kind)
    }

    /// The picture if it is already in memory (synchronous, any thread), so a tile can show it in its first frame.
    func cachedImage(_ urlString: String?, kind: ArtworkKind) -> CGImage? {
        guard let s = urlString.nilIfEmpty, let url = URL(string: s) else { return nil }
        return cache.cachedImage(for: url, kind: kind)
    }

    /// Warms memory for pictures about to be shown (low priority; cancelled loads are not counted as failures).
    func prefetch(_ urlStrings: [String?], kind: ArtworkKind) {
        cache.prefetch(urlStrings.compactMap { $0.nilIfEmpty.flatMap(URL.init(string:)) }, kind: kind)
    }

    func clear() async { await cache.clear() }
    func relieveMemory() async { await cache.relieveMemory() }
    func trim() async { await cache.trimDisk() }
    @discardableResult
    func evict(urls: [String]) async -> Int { await cache.evict(urls: urls) }
}
