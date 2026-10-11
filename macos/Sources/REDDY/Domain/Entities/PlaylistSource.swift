import Foundation

enum SourceType: String, Codable, Sendable, CaseIterable {
    case m3uRemote = "m3u_remote"
    case m3uLocal = "m3u_local"
    case xtream
    case jellyfin, emby
    case stalker
    case plex
    case enigma2

    /// Types that sign in with a saved login (as opposed to a link or a file).
    var hasLogin: Bool { self == .xtream || self == .jellyfin || self == .emby || self == .plex || self == .stalker || self == .enigma2 }

    var title: String {
        switch self {
        case .m3uRemote: "M3U URL"
        case .m3uLocal: "M3U File"
        case .xtream: "Xtream"
        case .jellyfin: "Jellyfin"
        case .emby: "Emby"
        case .stalker: "Stalker / MAG portal"
        case .plex: "Plex"
        case .enigma2: "Enigma2 receiver"
        }
    }
}

struct SourceCapabilities: Codable, Hashable, Sendable {
    var live = false
    var movies = false
    var series = false
    var epg = false
    var outputFormats: [String] = []
}

struct PlaylistSource: Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var type: SourceType
    /// Redacted, display-safe address. Secrets live in the Keychain under `credentialRef`.
    var baseURL: String
    var credentialRef: String?
    var epgURL: String?
    var enabled: Bool
    var lastSync: Date?
    var syncStatus: String
    var createdAt: Date
    var capabilities: SourceCapabilities

    init(id: UUID = UUID(), name: String, type: SourceType, baseURL: String, credentialRef: String? = nil,
         epgURL: String? = nil, enabled: Bool = true, lastSync: Date? = nil, syncStatus: String = "idle",
         createdAt: Date = Date(), capabilities: SourceCapabilities = .init()) {
        self.id = id; self.name = name; self.type = type; self.baseURL = baseURL
        self.credentialRef = credentialRef; self.epgURL = epgURL; self.enabled = enabled
        self.lastSync = lastSync; self.syncStatus = syncStatus; self.createdAt = createdAt
        self.capabilities = capabilities
    }
}

enum HTTPAuthKind: String, CaseIterable, Sendable {
    case none = "None", basic = "Username and password", bearer = "Token"
}
