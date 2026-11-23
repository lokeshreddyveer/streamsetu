import Foundation

struct CachePolicy: Sendable {
    var memoryLimitBytes = 160 * 1024 * 1024
    var diskLimitBytes: Int64 = 600 * 1024 * 1024
    var maxConcurrentDownloads = 6
    var failureBackoff: TimeInterval = 600
    /// Waits before each new try of a picture that failed for a passing reason (no connection, a busy server). A missing picture (404) or a file that is not an image is not retried.
    var retryDelays: [TimeInterval] = [0.4, 1.5]
    /// At most this many pictures are fetched from one host at once, so a host that stalls cannot hold every slot; and one attempt waits no longer than this.
    var maxPerHost = 3
    var attemptTimeout: TimeInterval = 15
    var maxPixels = 40_000_000          // reject absurd images (decompression bombs)
    static let `default` = CachePolicy()
}

/// Every "how long is this kept or trusted" number in one place. Each value is a decision, documented here; change it here and every reader follows.
enum Retention {
    static let day: TimeInterval = 86400
    /// The owner cap: nothing fetched from TMDB or the hub services is kept longer than 6 months (details, lists, facts, rating checks, matches). User-facing text: `keepNote`.
    static let maxKeepDays = 180
    static let maxKeep: TimeInterval = Double(maxKeepDays) * day
    /// Saved title details (cast, trailers, similar) are used as they are for this long, then fetched again when the title is opened. Inside the 180-day cap.
    static let detailsRefresh: TimeInterval = 14 * day
    /// Person credits (Filmography) are kept this long, inside the cap.
    static let personKeepDays = 30
    /// A person page that is younger than this is not re-fetched when opened again.
    static let personRefresh: TimeInterval = 1 * day
    /// Weekly trending: shown as fresh for 30 days, then shown local-only until refreshed; purged past the cap.
    static let trendingFreshDays = 30
    /// TheTVDB's terms allow caching "a week or even longer": 7 days, refreshed quietly.
    static let tvdbKeep: TimeInterval = 7 * day
    /// Decoded hero pictures (title page backdrop and poster) kept in memory so going back to a page is instant.
    static let heroPictureCount = 24
    /// A built-in key that a service refused is set aside this long before it is tried again (and shown as such in Settings). See `BuiltInKeyPause`.
    static let builtInKeyPause: TimeInterval = 7 * day
    /// A series whose episode list TVmaze could not give is not asked again for this long.
    static let episodesMiss: TimeInterval = 7 * day
    /// Scheduled backups run this often.
    static let autoBackupInterval: TimeInterval = 7 * day
}

/// The one policy for a built-in key that a service refused (401/403): TMDB, fanart.tv and TheTVDB all use it. The built-in key is paused for `Retention.builtInKeyPause`;
/// the person's own key is never paused (a refusal of it is shown, not remembered). Only the storage key differs per service.
struct BuiltInKeyPause: @unchecked Sendable {
    let storageKey: String
    var defaults: UserDefaults = .standard
    var now: @Sendable () -> Date = { Date() }

    var isPaused: Bool {
        let at = defaults.double(forKey: storageKey)
        return at > 0 && now().timeIntervalSince1970 - at < Retention.builtInKeyPause
    }
    /// Starts the pause, unless the person has their own key in use.
    func reportRefused(ownKeyInUse: Bool) { if !ownKeyInUse { defaults.set(now().timeIntervalSince1970, forKey: storageKey) } }
    func clear() { defaults.removeObject(forKey: storageKey) }
    /// Whether a refusal status counts (401 or 403).
    static func isRefusal(_ status: Int) -> Bool { status == 401 || status == 403 }
}

enum ArtworkKind: String, CaseIterable, Sendable {
    case logo = "ChannelLogos", poster = "Posters", backdrop = "Backdrops", still = "Stills"

    /// Longest edge, in pixels, that is ever decoded or stored for this kind.
    var maxPixel: Int {
        switch self { case .logo: 240; case .poster: 400; case .backdrop: 1280; case .still: 640 }
    }
}
