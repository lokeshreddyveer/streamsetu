import Foundation

// The account's library: saved playlists, liked songs, saved albums and artists, subscriptions, uploads and history. It reads through the
// existing page parsers; the extra work here is the per-row library toggle and rating, which the row parser does not keep.

enum YTMLibraryToggleParser {
    private static let addIcons: Set<String> = ["BOOKMARK_BORDER", "LIBRARY_ADD"]
    private static let removeIcons: Set<String> = ["BOOKMARK", "LIBRARY_REMOVE", "LIBRARY_SAVED"]

    private static func token(_ endpoint: Any?) -> String? {
        ((endpoint as? [String: Any])?.dict("feedbackEndpoint"))?.str("feedbackToken")
    }

    /// The library action of one row's menu. Matched by icon, never by label (labels are localised). Favourite and "pin to listen again"
    /// feedback items use other icons and are not matched.
    static func parse(menu: Any?) -> MusicLibraryToggle? {
        for item in YTMJSON.find("toggleMenuServiceItemRenderer", in: menu) {
            let d = item.dict("defaultIcon")?.str("iconType") ?? "", t = item.dict("toggledIcon")?.str("iconType") ?? ""
            let defToken = token(item["defaultServiceEndpoint"]), togToken = token(item["toggledServiceEndpoint"])
            if addIcons.contains(d) { return MusicLibraryToggle(inLibrary: false, addToken: defToken, removeToken: togToken) }
            if removeIcons.contains(d) { return MusicLibraryToggle(inLibrary: true, addToken: togToken, removeToken: defToken) }
            if addIcons.contains(t) { return MusicLibraryToggle(inLibrary: true, addToken: togToken, removeToken: defToken) }
        }
        for item in YTMJSON.find("menuServiceItemRenderer", in: menu) {
            let icon = item.dict("icon")?.str("iconType") ?? ""
            guard let tk = token(item["serviceEndpoint"]) else { continue }
            if addIcons.contains(icon) { return MusicLibraryToggle(inLibrary: false, addToken: tk) }
            if removeIcons.contains(icon) { return MusicLibraryToggle(inLibrary: true, removeToken: tk) }
        }
        return nil
    }

    /// Toggles of every row in a reply, keyed by video id.
    static func toggles(in root: Any?) -> [String: MusicLibraryToggle] {
        var out: [String: MusicLibraryToggle] = [:]
        for (_, row) in YTMJSON.findShallow(["musicResponsiveListItemRenderer", "musicTwoRowItemRenderer"], in: root) {
            guard let vid = YTMJSON.firstString("videoId", in: row), let t = parse(menu: row["menu"]) else { continue }
            if out[vid] == nil { out[vid] = t }
        }
        return out
    }
}

enum YTMRowEnrichment {
    static func rating(_ s: String?) -> MusicRating? {
        switch s {
        case "LIKE": .like
        case "DISLIKE": .dislike
        case "INDIFFERENT": MusicRating.none
        default: nil
        }
    }

    /// The track with the account fields the row carried: its handle in the playlist and the person's rating.
    static func track(_ row: YTMRow, toggles: [String: MusicLibraryToggle] = [:]) -> MusicTrack {
        var t = row.track
        t.setVideoID = row.setVideoID
        t.rating = rating(row.rating)
        t.libraryToggle = toggles[t.videoID ?? t.id]
        return t
    }

    static func tracks(_ rows: [YTMRow], toggles: [String: MusicLibraryToggle] = [:]) -> [MusicTrack] { rows.map { track($0, toggles: toggles) } }
}

/// What the Library page can show for a signed-in account.
struct YouTubeMusicLibrary: Sendable {
    let provider: YouTubeMusicFullProvider
    /// Runs a read that may meet a dead session (heal and retry once).
    let sessionGuard: any YTMSessionGuard

    init(provider: YouTubeMusicFullProvider, sessionGuard: any YTMSessionGuard = YTMNoGuard()) {
        self.provider = provider; self.sessionGuard = sessionGuard
    }

    private func signedIn() async throws {
        guard await provider.client.isSignedIn else { throw YTMAccountError.signedOut }
    }

    private func browseRoot(_ id: String) async throws -> YTMResponse {
        let c = provider.client
        return try await sessionGuard.run { try await c.browse(id) }
    }

    /// Playlists you made or saved, including the Liked Music card.
    func playlists() async throws -> [MusicPlaylist] { try await signedIn(); let p = provider; return try await sessionGuard.run { try await p.savedPlaylists(page: nil).items } }
    func albums() async throws -> [MusicAlbum] { try await signedIn(); let p = provider; return try await sessionGuard.run { try await p.savedAlbums(page: nil).items } }
    func artists() async throws -> [MusicArtist] { try await signedIn(); let p = provider; return try await sessionGuard.run { try await p.savedArtists(page: nil).items } }

    /// Artists you subscribe to (their own channels, unlike the artists behind your songs).
    func subscriptions() async throws -> [MusicArtist] {
        try await signedIn()
        let c = provider.client
        let grid = try await sessionGuard.run { try await c.libraryGrid("FEmusic_library_corpus_artists") }
        return grid.compactMap { if case .artist(let a) = $0 { a } else { nil } }
    }

    func uploadedAlbums() async throws -> [MusicBrowseItem] {
        try await signedIn()
        let c = provider.client
        return try await sessionGuard.run { try await c.libraryGrid("FEmusic_library_privately_owned_releases") }
    }

    /// Library > Songs. Each row carries the toggle that removes it from the library.
    func songs() async throws -> [MusicTrack] { try await rows("FEmusic_liked_videos") }
    /// Liked Music.
    func likedMusic() async throws -> [MusicTrack] { try await rows("VLLM") }
    /// Your uploaded songs. They are private to the account; their audio needs the cookie (see `YTMUploadStreamHeaders`).
    func uploadedSongs() async throws -> [MusicTrack] { try await rows("FEmusic_library_privately_owned_tracks") }

    private func rows(_ browseID: String) async throws -> [MusicTrack] {
        try await signedIn()
        let first = try await browseRoot(browseID)
        let toggles = YTMLibraryToggleParser.toggles(in: first.root)
        let page = YTMPageParser.parsePlaylist(first.root, playlistID: browseID)
        var rows = page.rows
        if let token = page.continuation {
            rows = try await provider.client.remainingPlaylistRows(firstRows: rows, token: token, total: page.playlist.trackCount, state: YTMPagingState())
        }
        return YTMRowEnrichment.tracks(rows, toggles: toggles)
    }

    func history() async throws -> [YTMHistoryBucket] {
        try await signedIn()
        let r = try await browseRoot("FEmusic_history")
        return YTMPageParser.parseHistory(r.root)
    }

    /// Rows of one playlist with their handles, for editing.
    func playlistRows(_ id: String) async throws -> [MusicTrack] {
        try await signedIn()
        let p = try await provider.playlistPage(id: id)
        let rows = try await provider.client.remainingPlaylistRows(firstRows: p.rows, token: p.continuation, total: p.playlist.trackCount, state: YTMPagingState())
        return YTMRowEnrichment.tracks(rows)
    }
}
