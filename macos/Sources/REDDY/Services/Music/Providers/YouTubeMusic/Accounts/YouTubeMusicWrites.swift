import Foundation

// Everything the account can change on YouTube Music: likes, library, playlists, subscriptions. `YTMWriteBodies` builds the exact request
// bodies (pure, tested); `YouTubeMusicWriter` sends them through the client, which adds the context (cookie, signature, delegated id).

enum YTMIDs {
    /// Browsing keeps the `VL` prefix; edits, likes and radio use the bare id.
    static func stripVL(_ id: String) -> String { id.hasPrefix("VL") ? String(id.dropFirst(2)) : id }
    static func isAlbumAudioPlaylist(_ id: String) -> Bool { id.hasPrefix("OLAK5uy_") }
    /// Liked Music is changed only by rating songs; it is never a playlist edit target.
    static func isEditable(_ id: String) -> Bool {
        let bare = stripVL(id)
        return !bare.isEmpty && bare != "LM" && !bare.hasPrefix("FEmusic_") && !bare.hasPrefix("RD")
    }
}

enum YTMPlaylistPrivacy: String, Sendable, CaseIterable, Codable { case `public` = "PUBLIC", `private` = "PRIVATE", unlisted = "UNLISTED" }

/// Stored sort orders for an owned list. Only these values exist: there is no descending title, artist or album order, and values outside
/// 1...3 for the dynamic ones answer HTTP 500 and leave the list reporting a manual order.
enum YTMPlaylistVideoOrder: Int, Sendable, CaseIterable { case manual = 0, newest = 1, oldest = 2, topVoted = 6 }
enum YTMPlaylistDynamicSort: Int, Sendable, CaseIterable { case title = 1, artist = 2, album = 3 }

enum YTMPlaylistEditAction: Sendable, Equatable {
    case addVideo(videoID: String, allowDuplicate: Bool)
    case removeVideo(setVideoID: String, videoID: String)
    /// Moves the row before `successor`; no successor moves it to the end.
    case moveBefore(setVideoID: String, successor: String?)
    case rename(String)
    case describe(String)
    case privacy(YTMPlaylistPrivacy)
    case videoOrder(YTMPlaylistVideoOrder)
    case dynamicSort(YTMPlaylistDynamicSort)
    case setCover(blobID: String)
    case removeCover

    static var coverImageKey: [String: Any] { ["name": "studio_square_thumbnail", "type": "PLAYLIST_IMAGE_TYPE_CUSTOM_THUMBNAIL"] }

    var json: [String: Any] {
        switch self {
        case .addVideo(let v, let dup):
            var a: [String: Any] = ["action": "ACTION_ADD_VIDEO", "addedVideoId": v]
            if dup { a["dedupeOption"] = "DEDUPE_OPTION_SKIP" }
            return a
        case .removeVideo(let s, let v): return ["action": "ACTION_REMOVE_VIDEO", "setVideoId": s, "removedVideoId": v]
        case .moveBefore(let s, let succ):
            var a: [String: Any] = ["action": "ACTION_MOVE_VIDEO_BEFORE", "setVideoId": s]
            if let succ { a["movedSetVideoIdSuccessor"] = succ }
            return a
        case .rename(let n): return ["action": "ACTION_SET_PLAYLIST_NAME", "playlistName": n]
        case .describe(let d): return ["action": "ACTION_SET_PLAYLIST_DESCRIPTION", "playlistDescription": d]
        case .privacy(let p): return ["action": "ACTION_SET_PLAYLIST_PRIVACY", "playlistPrivacy": p.rawValue]
        case .videoOrder(let o): return ["action": "ACTION_SET_PLAYLIST_VIDEO_ORDER", "playlistVideoOrder": o.rawValue]
        case .dynamicSort(let s): return ["action": "ACTION_SET_PLAYLIST_DYNAMIC_SORT_PREFERENCE", "playlistDynamicSortPreference": s.rawValue]
        case .setCover(let blob):
            return ["action": "ACTION_SET_CUSTOM_THUMBNAIL",
                    "addedCustomThumbnail": ["imageKey": Self.coverImageKey, "playlistScottyEncryptedBlobId": blob] as [String: Any]]
        case .removeCover:
            return ["action": "ACTION_REMOVE_CUSTOM_THUMBNAIL", "deletedCustomThumbnail": ["imageKey": Self.coverImageKey] as [String: Any]]
        }
    }
}

/// The user's edits to a playlist's details. Only the fields that changed are sent.
struct YTMPlaylistDetailsEdit: Sendable, Equatable {
    var name: String?
    var description: String?
    var privacy: YTMPlaylistPrivacy?
    var actions: [YTMPlaylistEditAction] {
        var a: [YTMPlaylistEditAction] = []
        if let name { a.append(.rename(name)) }
        if let description { a.append(.describe(description)) }
        if let privacy { a.append(.privacy(privacy)) }
        return a
    }
}

enum YTMWriteBodies {
    enum Path {
        static let like = "like/like", dislike = "like/dislike", removeLike = "like/removelike", feedback = "feedback"
        static let createPlaylist = "playlist/create", deletePlaylist = "playlist/delete", edit = "browse/edit_playlist"
        static let subscribe = "subscription/subscribe", unsubscribe = "subscription/unsubscribe"
        static let coverUpload = "playlist_image_upload/playlist_custom_thumbnail"
    }

    static func rate(_ r: MusicRating, videoID: String) -> (path: String, body: [String: Any]) {
        let path = r == .like ? Path.like : r == .dislike ? Path.dislike : Path.removeLike
        return (path, ["target": ["videoId": videoID]])
    }

    /// Saving an album is a like on its `OLAK5uy_` audio playlist; any other playlist is saved the same way with its bare id.
    static func savePlaylist(_ save: Bool, playlistID: String) -> (path: String, body: [String: Any]) {
        (save ? Path.like : Path.removeLike, ["target": ["playlistId": YTMIDs.stripVL(playlistID)]])
    }

    static func feedback(token: String) -> [String: Any] { ["feedbackTokens": [token]] }

    static func create(title: String) -> [String: Any] { ["title": title, "privacyStatus": "PRIVATE"] }
    static func delete(playlistID: String) -> [String: Any] { ["playlistId": YTMIDs.stripVL(playlistID)] }

    static func edit(playlistID: String, actions: [YTMPlaylistEditAction]) -> [String: Any] {
        ["playlistId": YTMIDs.stripVL(playlistID), "actions": actions.map(\.json)]
    }

    static func subscribe(_ on: Bool, channelIDs: [String]) -> (path: String, body: [String: Any]) {
        (on ? Path.subscribe : Path.unsubscribe, ["channelIds": channelIDs])
    }
}

/// How the answers of the write endpoints are read.
enum YTMWriteResults {
    /// `feedbackResponses[0].isProcessed` must be true; a stale token answers 200 with false.
    static func feedbackProcessed(_ root: Any?) -> Bool {
        guard let d = root as? [String: Any], let first = d.array("feedbackResponses").first else { return false }
        return first["isProcessed"] as? Bool == true
    }

    /// The first `playlistId` string anywhere in a create answer.
    static func createdPlaylistID(_ root: Any?) -> String? { YTMJSON.firstString("playlistId", in: root) }

    enum Edit: Equatable { case applied, duplicate, refused }

    /// HTTP 200 does not mean applied: `STATUS_FAILED` is the refusal, and a `dedupeOption` in it means "already in the playlist".
    static func edit(_ root: Any?) -> Edit {
        guard let d = root as? [String: Any] else { return .refused }
        if d["status"] as? String == "STATUS_FAILED" { return YTMJSON.firstString("dedupeOption", in: root) != nil ? .duplicate : .refused }
        return .applied
    }

    /// videoId to the new row handle for each add in an edit answer.
    static func addedSetVideoIDs(_ root: Any?) -> [String: String] {
        var out: [String: String] = [:]
        for r in YTMJSON.find("playlistEditVideoAddedResultData", in: root) {
            if let v = r.str("videoId"), let s = r.str("setVideoId") { out[v] = s }
        }
        return out
    }

    static func uploadedBlobID(_ data: Data) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return o.str("encryptedBlobId") ?? YTMJSON.firstString("encryptedBlobId", in: o)
    }
}

enum YTMAddResult: Equatable, Sendable { case added(setVideoID: String?), duplicate }

struct YouTubeMusicWriter: Sendable {
    let client: YouTubeMusicClient
    /// Runs a request that may meet a dead session: the manager waits for a heal and retries once. Defaults to a plain call.
    let sessionGuard: any YTMSessionGuard

    init(client: YouTubeMusicClient, sessionGuard: any YTMSessionGuard = YTMNoGuard()) {
        self.client = client; self.sessionGuard = sessionGuard
    }

    private func requireSignedIn() async throws {
        guard await client.isSignedIn else { throw YTMAccountError.signedOut }
    }

    private func post(_ path: String, _ body: [String: Any]) async throws -> YTMResponse {
        let c = client
        let b = YTMBodyBox(body)
        return try await sessionGuard.run { try await c.post(path, body: b.value) }
    }

    // MARK: rating and library

    func rate(_ r: MusicRating, videoID: String) async throws {
        try await requireSignedIn()
        let w = YTMWriteBodies.rate(r, videoID: videoID)
        _ = try await post(w.path, w.body)
    }

    /// Adds or removes a song in Library > Songs with the row's own token. It does not touch Liked Music.
    func setLibrary(_ toggle: MusicLibraryToggle, add: Bool) async throws {
        try await requireSignedIn()
        guard let token = add ? toggle.addToken : toggle.removeToken else { throw YTMAccountError.libraryChangeRefused }
        let r = try await post(YTMWriteBodies.Path.feedback, YTMWriteBodies.feedback(token: token))
        guard YTMWriteResults.feedbackProcessed(r.root) else { throw YTMAccountError.libraryChangeRefused }
    }

    func setAlbumSaved(_ saved: Bool, audioPlaylistID: String) async throws {
        try await requireSignedIn()
        let w = YTMWriteBodies.savePlaylist(saved, playlistID: audioPlaylistID)
        _ = try await post(w.path, w.body)
    }

    func setPlaylistSaved(_ saved: Bool, playlistID: String) async throws { try await setAlbumSaved(saved, audioPlaylistID: playlistID) }

    func subscribe(_ on: Bool, channelID: String) async throws {
        try await requireSignedIn()
        let w = YTMWriteBodies.subscribe(on, channelIDs: [channelID])
        _ = try await post(w.path, w.body)
    }

    // MARK: playlists

    /// New playlists are always private; change that with `edit`.
    func createPlaylist(title: String) async throws -> String {
        try await requireSignedIn()
        let r = try await post(YTMWriteBodies.Path.createPlaylist, YTMWriteBodies.create(title: title))
        guard let id = YTMWriteResults.createdPlaylistID(r.root) else { throw YTMAccountError.noPlaylistID }
        return id
    }

    func deletePlaylist(_ id: String) async throws {
        try await requireSignedIn()
        guard YTMIDs.isEditable(id) else { throw YTMAccountError.notAllowedTarget }
        _ = try await post(YTMWriteBodies.Path.deletePlaylist, YTMWriteBodies.delete(playlistID: id))
    }

    /// Applies the actions in order, all or nothing. A 401 or 403 on a playlist edit means "not your playlist", so it never wakes the healer.
    @discardableResult
    func edit(_ id: String, _ actions: [YTMPlaylistEditAction]) async throws -> YTMResponse {
        try await requireSignedIn()
        guard YTMIDs.isEditable(id) else { throw YTMAccountError.notAllowedTarget }
        guard !actions.isEmpty else { throw YTMAccountError.playlistEditRefused }
        let body = YTMWriteBodies.edit(playlistID: id, actions: actions)
        let r: YTMResponse
        do { r = try await client.post(YTMWriteBodies.Path.edit, body: body) } catch MusicError.notSignedIn { throw YTMAccountError.notEditable }
        switch YTMWriteResults.edit(r.root) {
        case .applied: return r
        case .duplicate: throw YTMAccountError.alreadyInPlaylist
        case .refused: throw YTMAccountError.playlistEditRefused
        }
    }

    /// Adding a track that is already there is `.duplicate`, not an error. `allowDuplicate` repeats the add on purpose.
    func add(videoID: String, to playlistID: String, allowDuplicate: Bool = false) async throws -> YTMAddResult {
        do {
            let r = try await edit(playlistID, [.addVideo(videoID: videoID, allowDuplicate: allowDuplicate)])
            return .added(setVideoID: YTMWriteResults.addedSetVideoIDs(r.root)[videoID])
        } catch YTMAccountError.alreadyInPlaylist { return .duplicate }
    }

    /// Several adds in one request. One track already present fails the whole batch, so pass only new ones.
    func add(videoIDs: [String], to playlistID: String) async throws -> [String: String] {
        let r = try await edit(playlistID, videoIDs.map { .addVideo(videoID: $0, allowDuplicate: false) })
        return YTMWriteResults.addedSetVideoIDs(r.root)
    }

    func remove(_ rows: [(setVideoID: String, videoID: String)], from playlistID: String) async throws {
        try await edit(playlistID, rows.map { .removeVideo(setVideoID: $0.setVideoID, videoID: $0.videoID) })
    }

    func move(setVideoID: String, before successor: String?, in playlistID: String) async throws {
        try await edit(playlistID, [.moveBefore(setVideoID: setVideoID, successor: successor)])
    }

    func update(_ playlistID: String, details: YTMPlaylistDetailsEdit) async throws {
        let actions = details.actions
        guard !actions.isEmpty else { return }
        try await edit(playlistID, actions)
    }

    // MARK: custom cover (three steps)

    /// 1. start a resumable upload, 2. send the image, 3. attach it. A refusal on any step is reported as the phone-verification requirement,
    /// never as an expired session; connection failures stay ordinary retryable errors.
    func setCover(playlistID: String, image: Data) async throws {
        try await requireSignedIn()
        guard YTMIDs.isEditable(playlistID), !image.isEmpty else { throw YTMAccountError.notAllowedTarget }
        let snap = await client.session.snapshot()
        var base = YTMContext.headers(client: client.identity(.webRemix), locale: client.locale, session: snap, now: client.now())
        base["content-type"] = "application/json"
        let root = "https://music.youtube.com/" + YTMWriteBodies.Path.coverUpload
        guard let startURL = URL(string: root) else { throw MusicError.network("bad address") }
        var start = base
        start["x-goog-upload-command"] = "start"
        start["x-goog-upload-protocol"] = "resumable"
        start["x-goog-upload-header-content-length"] = String(image.count)
        start["content-length"] = "0"
        let uploadID: String
        do { uploadID = try await uploadStart(url: startURL, headers: start) } catch let e as MusicError {
            if case .network(let t) = e, !t.hasPrefix("HTTP 4") { throw e }
            if e == .cancelled { throw e }
            throw YTMAccountError.coverRefused
        }
        guard var comps = URLComponents(string: root) else { throw MusicError.network("bad address") }
        comps.queryItems = [URLQueryItem(name: "upload_id", value: uploadID), URLQueryItem(name: "upload_protocol", value: "resumable")]
        guard let sendURL = comps.url else { throw MusicError.network("bad address") }
        var send = base
        send["x-goog-upload-command"] = "upload, finalize"
        send["x-goog-upload-offset"] = "0"
        let data: Data
        do { data = try await client.http.postJSON(sendURL, body: image, headers: send) } catch let e as MusicError {
            if case .network(let t) = e, !t.hasPrefix("HTTP 4") { throw e }
            if e == .cancelled { throw e }
            throw YTMAccountError.coverRefused
        }
        guard let blob = YTMWriteResults.uploadedBlobID(data) else { throw YTMAccountError.coverRefused }
        do { try await edit(playlistID, [.setCover(blobID: blob)]) } catch YTMAccountError.playlistEditRefused { throw YTMAccountError.coverRefused }
        catch YTMAccountError.notEditable { throw YTMAccountError.coverRefused }
    }

    func removeCover(playlistID: String) async throws { try await edit(playlistID, [.removeCover]) }

    /// The start step answers with the upload id in a header, which `MusicHTTP` does not expose; this one call goes to the transport directly.
    private func uploadStart(url: URL, headers: [String: String]) async throws -> String {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue(client.http.userAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = Data()
        let (_, resp) = try await client.http.transport.data(for: r)
        guard (200..<300).contains(resp.statusCode) else { throw MusicError.network("HTTP \(resp.statusCode)") }
        guard let id = resp.value(forHTTPHeaderField: "x-guploader-uploadid"), !id.isEmpty else { throw MusicError.network("HTTP 400") }
        return id
    }
}

/// Wraps a request that may be rejected because the session died. The account manager's version waits for one heal and retries once.
protocol YTMSessionGuard: Sendable {
    func run<T: Sendable>(_ op: @Sendable () async throws -> T) async throws -> T
}

struct YTMNoGuard: YTMSessionGuard {
    init() {}
    func run<T: Sendable>(_ op: @Sendable () async throws -> T) async throws -> T { try await op() }
}

/// A dictionary that is safe to hand across a concurrency boundary because it is only read after creation.
struct YTMBodyBox: @unchecked Sendable {
    let value: [String: Any]
    init(_ v: [String: Any]) { value = v }
}
