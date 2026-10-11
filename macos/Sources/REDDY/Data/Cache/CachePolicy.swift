import Foundation

struct CachePolicy: Sendable {
    var memoryLimitBytes = 160 * 1024 * 1024
    var diskLimitBytes: Int64 = 600 * 1024 * 1024
    var maxConcurrentDownloads = 6
    var failureBackoff: TimeInterval = 600
    var maxPixels = 40_000_000          // reject absurd images (decompression bombs)
    static let `default` = CachePolicy()
}

enum ArtworkKind: String, CaseIterable, Sendable {
    case logo = "ChannelLogos", poster = "Posters", backdrop = "Backdrops", still = "Stills"

    /// Longest edge, in pixels, that is ever decoded or stored for this kind.
    var maxPixel: Int {
        switch self { case .logo: 240; case .poster: 400; case .backdrop: 1280; case .still: 640 }
    }
}
