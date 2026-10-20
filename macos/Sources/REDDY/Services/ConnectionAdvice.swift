import Foundation

/// Many providers allow only a few streams at once for one subscription, and every tile in multi-view is a stream. This says so before a tile that would go over the limit is opened.
enum ConnectionAdvice {
    /// A warning for adding one more stream from a playlist that already has `tilesFromSource` open, or nil when it is within the limit or the limit is unknown.
    static func message(tilesFromSource: Int, limit: Int?) -> String? {
        guard let limit, limit > 0, tilesFromSource + 1 > limit else { return nil }
        let allowed = limit == 1 ? "1 stream at a time" : "\(limit) streams at a time"
        return "Your provider allows \(allowed) for this playlist. Opening another may stop one of the others, or fail to load."
    }
}
