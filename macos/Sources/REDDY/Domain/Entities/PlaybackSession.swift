import Foundation

struct PlaybackRequest: Hashable, Sendable {
    let itemID: String
    let kind: ContentKind
    let sourceID: UUID
    let title: String
    var subtitle: String?
    var artworkURL: String?
    var url: URL
    let isLive: Bool
    var startPosition: TimeInterval = 0
    /// Series context for "next episode" / progress roll-up.
    var seriesID: String?
    /// A past programme played from the provider's archive: seekable, and not recorded as watching a movie or episode.
    var isCatchup = false
    /// Headers this playlist needs (a User-Agent, a Referer…). Empty unless the person set some.
    var headers: [String: String] = [:]
}

struct PlaybackSession: Sendable {
    let id: Int64
    let itemID: String
    let startedAt: Date
    var engine: String
}
