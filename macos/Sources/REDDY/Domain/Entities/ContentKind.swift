import Foundation

enum ContentKind: String, Codable, Sendable, CaseIterable {
    case channel, movie, series, episode
}

/// Stable identity: `source_id | kind | provider_item_id`. Never derived from a (rotating) stream URL.
enum ItemID {
    static func make(source: UUID, kind: ContentKind, provider: String) -> String {
        "\(source.uuidString.lowercased())|\(kind.rawValue)|\(provider)"
    }
}
