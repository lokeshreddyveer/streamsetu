import Foundation

/// What a cover is used for. Each class asks for a point size, and the point size (times the display scale) picks one request bucket, so a 40 pt
/// row never decodes more than a 128 or 256 px image and a fullscreen backdrop never settles for a thumbnail.
enum MusicArtworkClass: String, CaseIterable, Sendable {
    case trackThumb, tile, artistPortrait, playlistCover, hero, mini, nowPlaying, fullscreen

    /// The longest side, in points, this class is drawn at (the top of the range for classes that span one).
    var requestPoints: Int {
        switch self {
        case .trackThumb: return 56
        case .mini: return 80
        case .tile, .artistPortrait, .playlistCover: return 190
        case .hero: return 640
        case .nowPlaying: return 500
        case .fullscreen: return 1024
        }
    }

    /// Pixels wanted at a display scale (never below 1x, never above 3x).
    func pixels(scale: CGFloat) -> Int {
        Int((CGFloat(requestPoints) * min(max(scale, 1), 3)).rounded(.up))
    }

    /// The bucket (stored size) this class requests at that scale.
    func bucket(scale: CGFloat) -> Int { MusicArtworkBuckets.bucket(forPixels: pixels(scale: scale)) }

    /// Small classes are cheap and numerous: they are the ones lists prefetch with the widest window.
    var isSmall: Bool { requestPoints <= 80 }
}

/// How urgent a prefetch is. Maps to task priority; visible-next rows use `.normal`, speculative shelves `.low`.
enum MusicArtworkPriority: Int, Comparable, Sendable {
    case low, normal, high
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    var taskPriority: TaskPriority {
        switch self { case .low: return .background; case .normal: return .utility; case .high: return .userInitiated }
    }
}
