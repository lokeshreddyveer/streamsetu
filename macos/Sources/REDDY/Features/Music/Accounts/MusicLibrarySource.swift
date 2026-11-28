import Foundation

// Where the Library page reads from, and where likes and new playlists are kept. Pure logic: the page and the settings section only draw it.
// Signed out, "Your library" (saved on this Mac) is the only choice and "Your playlists" the only kind of playlist.

enum MusicLibrarySource: Hashable, Sendable, Identifiable, Codable {
    case local
    case youTubeMusic(accountID: String)
    case spotify

    var id: String {
        switch self {
        case .local: "local"
        case .youTubeMusic(let a): "ytmusic:" + a
        case .spotify: "spotify"
        }
    }

    var title: String {
        switch self {
        case .local: "Your library"
        case .youTubeMusic: "YouTube Music"
        case .spotify: "Spotify"
        }
    }

    var symbol: String {
        switch self {
        case .local: "internaldrive"
        case .youTubeMusic: "play.rectangle"
        case .spotify: "dot.radiowaves.left.and.right"
        }
    }

    /// The word used for its playlists in the UI.
    var playlistsTitle: String { self == .local ? "Your playlists" : "\(title) playlists" }

    var isAccountBacked: Bool { self != .local }

    init?(storedID: String) {
        if storedID == "local" { self = .local }
        else if storedID == "spotify" { self = .spotify }
        else if storedID.hasPrefix("ytmusic:"), storedID.count > 8 { self = .youTubeMusic(accountID: String(storedID.dropFirst(8))) }
        else { return nil }
    }
}

enum MusicLibrarySources {
    /// The sources worth offering right now. Local always; YouTube Music only for the active, usable account; Spotify only when signed in.
    static func available(youTubeAccount: YTMAccountSummary?, youTubeSelectionPending: Bool = false, spotifySignedIn: Bool) -> [MusicLibrarySource] {
        var out: [MusicLibrarySource] = [.local]
        if let a = youTubeAccount, !a.selectionPending, !youTubeSelectionPending { out.append(.youTubeMusic(accountID: a.id)) }
        if spotifySignedIn { out.append(.spotify) }
        return out
    }

    /// A remembered choice that is no longer offered (signed out, another account) falls back to Local, never to someone else's library.
    static func resolve(saved: MusicLibrarySource?, available: [MusicLibrarySource]) -> MusicLibrarySource {
        if let saved, available.contains(saved) { return saved }
        return .local
    }
}

enum MusicPlacement: String, Codable, Sendable, CaseIterable { case device, account
    var title: String { self == .device ? "Your library" : "On my account" }
}

/// Where new likes and new playlists go. Signed out (or with no account source) everything stays on the device.
struct MusicPlacementPolicy: Equatable, Sendable {
    var likes: MusicPlacement = .device
    var playlists: MusicPlacement = .device

    func resolved(accountAvailable: Bool) -> MusicPlacementPolicy {
        accountAvailable ? self : MusicPlacementPolicy()
    }
}

/// Remembers the person's choices in UserDefaults (plain preferences, no secrets).
struct MusicLibrarySourceStore: @unchecked Sendable {
    static let sourceKey = "music.library.source"
    static let likesKey = "music.library.likesPlacement"
    static let playlistsKey = "music.library.playlistsPlacement"
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var source: MusicLibrarySource? {
        get { defaults.string(forKey: Self.sourceKey).flatMap(MusicLibrarySource.init(storedID:)) }
        nonmutating set { defaults.set(newValue?.id, forKey: Self.sourceKey) }
    }

    var policy: MusicPlacementPolicy {
        get {
            MusicPlacementPolicy(likes: defaults.string(forKey: Self.likesKey).flatMap(MusicPlacement.init(rawValue:)) ?? .device,
                                 playlists: defaults.string(forKey: Self.playlistsKey).flatMap(MusicPlacement.init(rawValue:)) ?? .device)
        }
        nonmutating set {
            defaults.set(newValue.likes.rawValue, forKey: Self.likesKey)
            defaults.set(newValue.playlists.rawValue, forKey: Self.playlistsKey)
        }
    }
}
