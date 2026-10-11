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

    func clear() async { await cache.clear() }
    func relieveMemory() async { await cache.relieveMemory() }
    func trim() async { await cache.trimDisk() }
}
