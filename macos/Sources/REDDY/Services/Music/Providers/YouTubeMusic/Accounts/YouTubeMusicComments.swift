import Foundation
import CryptoKit

// Comments on a video: reading threads and replies, voting, posting, replying, editing and deleting. This file is the model and the
// client calls; the panel that shows them belongs to the player chrome.
//
// Rules kept here:
//  - the comment text is not inline in a thread: a thread names entities and the text is joined from `frameworkUpdates` by key;
//  - every write replays a command the server issued with the page, so a page read by one identity is never used by another;
//  - post and reply are never retried, and an unread answer after the request went out is "may have reached YouTube";
//  - a signed-in read that gets 401 or 403 is redone WHOLE as a guest and never wakes the session healer.

struct YTMCommentAuthor: Equatable, Sendable {
    var name: String
    var channelID: String?
    var avatar: String?
    var isVerified = false, isCurrentUser = false, isCreator = false, isArtist = false
}

enum YTMVote: String, Sendable { case liked, disliked, none }

struct YTMComment: Equatable, Sendable, Identifiable {
    var id: String
    var text: String
    var published: String
    var author: YTMCommentAuthor
    var replyLevel = 0
    var likeCountLiked: String?
    var likeCountNotLiked: String?
    var replyCount: String?
    var vote: YTMVote = .none
    var isHearted = false
    var isPinned = false
    /// Server-issued vote and edit tokens (opaque; present only when signed in and allowed).
    var likeAction: String?, unlikeAction: String?, dislikeAction: String?, undislikeAction: String?
    var deleteAction: String?
    var editParams: String?
    var replyParams: String?
}

struct YTMCommentThread: Equatable, Sendable, Identifiable {
    var comment: YTMComment
    var replies: [YTMComment] = []
    var moreRepliesToken: String?
    var id: String { comment.id }
}

struct YTMCommentsHeader: Equatable, Sendable {
    var countText: String?
    /// First is "Top", second "Newest" by position, because the labels are localised.
    var sortTokens: [(token: String, selected: Bool)] = []
    var composerPlaceholder: String?
    var createParams: String?

    static func == (a: Self, b: Self) -> Bool {
        a.countText == b.countText && a.composerPlaceholder == b.composerPlaceholder && a.createParams == b.createParams
            && a.sortTokens.map(\.token) == b.sortTokens.map(\.token)
    }
}

struct YTMCommentsPage: Equatable, Sendable {
    var header: YTMCommentsHeader?
    var threads: [YTMCommentThread] = []
    var next: String?
    var disabled = false
    /// Who read this page. Writes refuse to run under a different identity.
    var identityKey: String = "guest"
}

enum YTMCommentsParser {
    /// The tab token that opens the comments. Not matched by the (localised) title.
    static func tabToken(_ root: Any?) -> String? {
        for tab in YTMJSON.find("tabRenderer", in: root) {
            if let t = YTMJSON.find("reloadContinuationData", in: tab.dict("content")).compactMap({ $0.str("continuation") }).first { return t }
        }
        return nil
    }

    /// The next-page token. A thread's own "more replies" token is skipped when reading the page level.
    static func nextToken(_ root: Any?, skipping: Set<String> = []) -> String? {
        for c in YTMJSON.find("continuationItemRenderer", in: root, skipping: skipping) {
            if let t = c.dict("continuationEndpoint")?.dict("continuationCommand")?.str("token") { return t }
            if let t = YTMJSON.find("continuationCommand", in: c["button"]).compactMap({ $0.str("token") }).first { return t }
        }
        return nil
    }

    private static func entities(_ root: Any?) -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        for m in YTMJSON.find("entityBatchUpdate", in: root).flatMap({ $0.array("mutations") }) {
            if let k = m.str("entityKey"), let p = m.dict("payload") { out[k] = p }
        }
        return out
    }

    private static func actionToken(_ cmd: Any?) -> String? {
        YTMJSON.find("performCommentActionEndpoint", in: cmd).compactMap { $0.str("action") }.first
    }

    static func comment(from vm: [String: Any], _ ents: [String: [String: Any]], replyLevelOverride: Int? = nil) -> YTMComment? {
        guard let key = vm.str("commentKey"), let payload = ents[key]?.dict("commentEntityPayload") else { return nil }
        let props = payload.dict("properties") ?? [:]
        let author = payload.dict("author") ?? [:]
        let toolbar = payload.dict("toolbar") ?? [:]
        guard let cid = props.str("commentId") ?? vm.str("commentId") else { return nil }
        let isMe = author["isCurrentUser"] as? Bool ?? false
        var c = YTMComment(
            id: cid, text: props.dict("content")?.str("content") ?? "", published: props.str("publishedTime") ?? "",
            author: YTMCommentAuthor(name: author.str("displayName") ?? "", channelID: author.str("channelId"), avatar: author.str("avatarThumbnailUrl"),
                                     isVerified: author["isVerified"] as? Bool ?? false, isCurrentUser: isMe,
                                     isCreator: author["isCreator"] as? Bool ?? false, isArtist: author["isArtist"] as? Bool ?? false))
        c.replyLevel = replyLevelOverride ?? (props["replyLevel"] as? Int ?? 0)
        c.likeCountLiked = toolbar.str("likeCountLiked"); c.likeCountNotLiked = toolbar.str("likeCountNotliked"); c.replyCount = toolbar.str("replyCount")
        if let tk = vm.str("toolbarStateKey"), let st = ents[tk]?.dict("engagementToolbarStateEntityPayload") {
            switch st.str("likeState") {
            case "TOOLBAR_LIKE_STATE_LIKED": c.vote = .liked
            case "TOOLBAR_LIKE_STATE_DISLIKED": c.vote = .disliked
            default: c.vote = YTMVote.none
            }
            c.isHearted = st.str("heartState") == "TOOLBAR_HEART_STATE_HEARTED"
        }
        if let sk = vm.str("toolbarSurfaceKey"), let surface = ents[sk]?.dict("engagementToolbarSurfaceEntityPayload"),
           YTMJSON.first("prepareAccountCommand", in: surface) == nil {
            c.likeAction = actionToken(surface["likeCommand"]); c.unlikeAction = actionToken(surface["unlikeCommand"])
            c.dislikeAction = actionToken(surface["dislikeCommand"]); c.undislikeAction = actionToken(surface["undislikeCommand"])
            c.replyParams = YTMJSON.firstString("createReplyParams", in: surface["replyCommand"])
            // Edit and delete are trusted only on the person's own comment.
            if isMe {
                for item in YTMJSON.find("menuRenderer", in: surface["menuCommand"]).flatMap({ $0.array("items") }) {
                    if let p = YTMJSON.firstString("updateCommentParams", in: item) ?? YTMJSON.firstString("updateReplyParams", in: item) { c.editParams = p }
                    if let t = actionToken(item) { c.deleteAction = t }
                }
            }
        }
        c.isPinned = vm["pinnedText"] != nil || vm.str("renderingPriority") == "RENDERING_PRIORITY_PINNED_COMMENT"
        return c
    }

    static func parse(_ root: Any?, identityKey: String) -> YTMCommentsPage {
        var page = YTMCommentsPage(identityKey: identityKey)
        if YTMJSON.first("messageRenderer", in: root) != nil, YTMJSON.find("commentThreadRenderer", in: root).isEmpty,
           YTMJSON.find("commentsHeaderRenderer", in: root).isEmpty { page.disabled = true; return page }
        let ents = entities(root)
        if let h = YTMJSON.first("commentsHeaderRenderer", in: root) {
            var header = YTMCommentsHeader()
            header.countText = h.dict("commentsCount")?.array("runs").first?.str("text")
            if let items = (YTMJSON.first("sortFilterSubMenuRenderer", in: h)?["subMenuItems"] as? [[String: Any]]) {
                header.sortTokens = items.compactMap { i in
                    guard let t = YTMJSON.find("reloadContinuationData", in: i).compactMap({ $0.str("continuation") }).first else { return nil }
                    return (t, i["selected"] as? Bool ?? false)
                }
            }
            if let box = YTMJSON.first("commentSimpleboxRenderer", in: h) {
                let hint = YTMJSON.text(box["placeholderText"])
                header.composerPlaceholder = hint.isEmpty ? nil : hint
                header.createParams = YTMJSON.firstString("createCommentParams", in: box)
            }
            page.header = header
        }
        for t in YTMJSON.find("commentThreadRenderer", in: root) {
            guard let vm = t.dict("commentViewModel")?.dict("commentViewModel") ?? t.dict("commentViewModel"),
                  let c = comment(from: vm, ents) else { continue }   // a thread whose entity is missing is skipped
            var thread = YTMCommentThread(comment: c)
            if let replies = t.dict("replies")?.dict("commentRepliesRenderer") {
                for sub in replies["subThreads"] as? [[String: Any]] ?? [] {
                    if let vm2 = YTMJSON.first("commentViewModel", in: sub)?.dict("commentViewModel") ?? YTMJSON.first("commentViewModel", in: sub),
                       let r = comment(from: vm2, ents, replyLevelOverride: 1) { thread.replies.append(r) }
                }
                thread.moreRepliesToken = nextToken(replies)
            }
            page.threads.append(thread)
        }
        page.next = nextToken(root, skipping: ["commentThreadRenderer"])
        return page
    }

    /// A server command path is trusted only when it is `comment/` plus lowercase letters, digits, `_` and single `/`.
    static func isSafeCommentPath(_ p: String) -> Bool {
        guard p.hasPrefix("comment/"), p.count > 8, !p.contains("//"), !p.hasSuffix("/") else { return false }
        return p.dropFirst(8).allSatisfy { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "_" || $0 == "/" }
    }

    /// Success needs `STATUS_SUCCEEDED`. Deletes and edits may answer 200 with no status.
    static func actionSucceeded(_ root: Any?, statusOptional: Bool = false) -> Bool {
        guard let d = root as? [String: Any] else { return false }
        if d["error"] != nil { return false }
        let s = d.array("actionResults").first?.str("status") ?? d.dict("actionResult")?.str("status")
        if let s { return s == "STATUS_SUCCEEDED" }
        return statusOptional
    }
}

enum YTMCommentIdentity {
    /// Changes when the login or the channel changes, but not when the short-lived cookies rotate.
    static func key(_ snap: YouTubeMusicSessionSnapshot) -> String {
        guard let s = snap.sapisid else { return "guest" }
        return MusicHash.sha256("streamsetu.ytm.comments.v1|" + s + "|" + (snap.dataSyncID ?? ""), prefix: 8)
    }
}

struct YouTubeMusicComments: Sendable {
    let client: YouTubeMusicClient

    private func identityKey() async -> String { YTMCommentIdentity.key(await client.session.snapshot()) }

    /// Reads the first page for a video. Signed in uses the account; a 401 or 403 redoes the whole chain as a guest.
    func firstPage(videoID: String) async throws -> YTMCommentsPage {
        let signed = await client.isSignedIn
        do { return try await readFirst(videoID: videoID, mode: signed ? .normal : .anonymous, key: signed ? await identityKey() : "guest") }
        catch MusicError.notSignedIn where signed { return try await readFirst(videoID: videoID, mode: .anonymous, key: "guest") }
    }

    private func readFirst(videoID: String, mode: YTMRequestMode, key: String) async throws -> YTMCommentsPage {
        let tab = try await client.post("next", body: ["videoId": videoID, "isAudioOnly": true], mode: mode)
        guard let token = YTMCommentsParser.tabToken(tab.root) else { return YTMCommentsPage(disabled: true, identityKey: key) }
        return try await page(token: token, mode: mode, key: key)
    }

    /// A later page, a sort, or a replies list. The mode follows the page that issued the token.
    func page(token: String, identityKey key: String) async throws -> YTMCommentsPage {
        let mode: YTMRequestMode = key == "guest" ? .anonymous : .normal
        if mode == .normal, await identityKey() != key { throw YTMAccountError.accountChanged }
        return try await page(token: token, mode: mode, key: key)
    }

    private func page(token: String, mode: YTMRequestMode, key: String) async throws -> YTMCommentsPage {
        let r = try await client.post("next", body: ["continuation": token], mode: mode)
        return YTMCommentsParser.parse(r.root, identityKey: key)
    }

    // MARK: votes and writes

    private func guardIdentity(_ key: String) async throws {
        guard key != "guest" else { throw YTMAccountError.signedOut }
        guard await client.isSignedIn else { throw YTMAccountError.signedOut }
        guard await identityKey() == key else { throw YTMAccountError.accountChanged }
    }

    /// Replays one server-issued action token (a vote, or a delete).
    func perform(action token: String, identityKey key: String, statusOptional: Bool = false) async throws {
        try await guardIdentity(key)
        do {
            let r = try await client.post("comment/perform_comment_action", body: ["actions": [token]])
            guard YTMCommentsParser.actionSucceeded(r.root, statusOptional: statusOptional) else { throw YTMAccountError.actionRejected }
        } catch MusicError.notFound where statusOptional { return }   // deleting what is already gone counts as done
    }

    /// New top-level comment, reply or edit. Never retried: a failure after the request left is reported as uncertain.
    func write(path: String, bodyKey: String, text: String, params: String, identityKey key: String) async throws {
        try await guardIdentity(key)
        guard YTMCommentsParser.isSafeCommentPath(path) else { throw YTMAccountError.actionRejected }
        let paramsKey = path.hasSuffix("create_comment") ? "createCommentParams" : path.hasSuffix("create_comment_reply") ? "createReplyParams"
            : path.hasSuffix("update_comment_reply") ? "updateReplyParams" : "updateCommentParams"
        do {
            _ = try await client.postOnce(path, body: [paramsKey: params, bodyKey: text])
        } catch let e as MusicError {
            switch e {
            case .network(let t) where !t.hasPrefix("HTTP 4"): throw YTMAccountError.writeUncertain
            case .cancelled: throw e
            default: throw YTMAccountError.actionRejected
            }
        }
    }

    func postComment(_ text: String, createParams: String, identityKey: String) async throws {
        try await write(path: "comment/create_comment", bodyKey: "commentText", text: text, params: createParams, identityKey: identityKey)
    }
    func reply(_ text: String, replyParams: String, identityKey: String) async throws {
        try await write(path: "comment/create_comment_reply", bodyKey: "commentText", text: text, params: replyParams, identityKey: identityKey)
    }
    func edit(_ text: String, updateParams: String, isReply: Bool, identityKey: String) async throws {
        try await write(path: isReply ? "comment/update_comment_reply" : "comment/update_comment", bodyKey: isReply ? "replyText" : "commentText",
                        text: text, params: updateParams, identityKey: identityKey)
    }
    func delete(action token: String, identityKey: String) async throws { try await perform(action: token, identityKey: identityKey, statusOptional: true) }
}

/// Timecodes inside a comment's text ("1:23", "1:02:03") that fall inside the track, for the panel to turn into seek links.
enum YTMCommentTimecodes {
    struct Match: Equatable, Sendable { var range: Range<String.Index>; var seconds: Int }

    static func matches(in text: String, trackSeconds: Int) -> [Match] {
        guard let re = try? NSRegularExpression(pattern: #"(?<![\d:])(\d{1,2}):([0-5]\d)(?::([0-5]\d))?(?![\d:])"#) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard let r = Range(m.range, in: text) else { return nil }
            let a = Int(ns.substring(with: m.range(at: 1))) ?? 0, b = Int(ns.substring(with: m.range(at: 2))) ?? 0
            let c = m.range(at: 3).location == NSNotFound ? nil : Int(ns.substring(with: m.range(at: 3)))
            let secs = c.map { a * 3600 + b * 60 + $0 } ?? (a * 60 + b)
            return secs <= trackSeconds ? Match(range: r, seconds: secs) : nil
        }
    }
}

extension YouTubeMusicClient {
    /// One attempt, no retry. Posting and replying are not idempotent, so a second attempt could post twice.
    func postOnce(_ path: String, body: [String: Any]) async throws -> YTMResponse {
        guard let url = Self.url(for: path) else { throw MusicError.network("bad address") }
        let id = identity(.webRemix)
        let snap = await session.snapshot()
        var payload = body
        payload["context"] = YTMContext.build(client: id, locale: locale, session: snap)
        let headers = YTMContext.headers(client: id, locale: locale, session: snap, now: now())
        let raw = try await http.postJSON(url, body: try JSONSerialization.data(withJSONObject: payload), headers: headers)
        guard let obj = try? JSONSerialization.jsonObject(with: raw) else { throw MusicError.network("unexpected reply") }
        return YTMResponse(root: obj)
    }
}
