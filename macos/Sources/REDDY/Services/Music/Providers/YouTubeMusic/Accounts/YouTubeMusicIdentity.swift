import Foundation
import CryptoKit

// Who is signed in, and which channels the Google account offers. Read from `account/account_menu` and `account/accounts_list`.
// The delegated id (`dataSyncID`) comes only from a datasync token, else a page id token, else (for the selected row alone) the response's own
// datasync id. A channel id (`UC...`) is never turned into one: a wrong delegated id would act as the wrong channel.

struct YTMAccountHeader: Equatable, Sendable {
    var name: String
    var handle: String?
    var email: String?
    var thumbnail: String?
    var channelID: String?
    /// Normalised datasync id from the response context.
    var dataSyncID: String?
    /// Login-bound visitor id from the response context.
    var visitorData: String?
}

struct YTMIdentityRow: Codable, Equatable, Sendable, Identifiable {
    /// The delegated id requests carry.
    var id: String
    var pageID: String?
    var name: String
    var handle: String?
    var email: String?
    var thumbnail: String?
    var channelID: String?
    var isSelected: Bool
    /// An opaque handle for the UI, so the real delegated id never reaches a view. Process-local.
    var selectionKey: String { YTMIdentityRow.selectionKey(for: id) }

    private static let salt = UUID().uuidString
    static func selectionKey(for id: String) -> String {
        MusicHash.sha256(salt + id, prefix: 8)
    }
}

/// The persisted channel choice and the display fields of a signed-in account.
struct YTMIdentity: Codable, Equatable, Sendable {
    /// Nil for a historical single-channel account that exposes no delegated id: its requests use the default channel.
    var dataSyncID: String?
    var name: String
    var handle: String?
    var email: String?
    var thumbnail: String?
    var channelID: String?
    var pageID: String?
    var hasMultiple: Bool

    /// What the UI shows under the name: the handle, else the email.
    var subtitle: String? { handle ?? email }
}

enum YTMIdentityParser {
    /// Splits `a||b`: the part before when it is non-empty, else the part after, else the whole value. A value made only of bars is empty.
    static func normalizeDataSync(_ raw: String?) -> String? {
        guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        if t.allSatisfy({ $0 == "|" }) { return nil }
        if let r = t.range(of: "||") {
            let before = t[t.startIndex..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            let after = t[r.upperBound...].trimmingCharacters(in: .whitespaces)
            if !before.isEmpty { return before }
            if !after.isEmpty { return after }
            return nil
        }
        return t
    }

    private static func runsText(_ node: Any?) -> String? {
        let t = YTMJSON.text(node).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func lastThumbnail(_ node: Any?) -> String? {
        YTMJSON.thumbnails(in: node).last?.url
    }

    static func responseDataSyncID(_ root: Any?) -> String? {
        guard let d = root as? [String: Any] else { return nil }
        let ctx = d.dict("responseContext")?.dict("mainAppWebResponseContext")
        return normalizeDataSync(ctx?.str("datasyncId"))
    }

    static func responseVisitorData(_ root: Any?) -> String? {
        ((root as? [String: Any])?.dict("responseContext"))?.str("visitorData")
    }

    /// The signed-in header of the account menu. An empty name means the cookie did not authenticate, which is `nil`.
    static func parseAccountMenu(_ root: Any?) -> YTMAccountHeader? {
        guard let h = YTMJSON.first("activeAccountHeaderRenderer", in: root), let name = runsText(h["accountName"]) else { return nil }
        let channel = YTMJSON.browseID(h.dict("navigationEndpoint")).flatMap { $0.hasPrefix("UC") ? $0 : nil }
        return YTMAccountHeader(name: name, handle: runsText(h["channelHandle"]), email: runsText(h["email"]), thumbnail: lastThumbnail(h["accountPhoto"]),
                                channelID: channel, dataSyncID: responseDataSyncID(root), visitorData: responseVisitorData(root))
    }

    private static let datasyncKeys = ["datasyncIdToken", "dataSyncIdToken", "datasyncId", "dataSyncId"]

    private static func tokenString(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let d = v as? [String: Any] { for k in datasyncKeys { if let s = d[k] as? String { return s } } }
        return nil
    }

    /// The selectable channels. Rows that are disabled, have no channel, no name or no identity endpoint are skipped, and so is a row for which no
    /// delegated id can be found.
    static func parseAccountsList(_ root: Any?) -> [YTMIdentityRow] {
        let sections = YTMJSON.find("accountSectionListRenderer", in: root)
        var sources: [(email: String?, items: [[String: Any]])] = []
        if sections.isEmpty {
            sources = [(nil, YTMJSON.find("accountItem", in: root))]
        } else {
            for s in sections {
                let email = runsText(YTMJSON.first("googleAccountHeaderRenderer", in: s["header"])?["email"])
                sources.append((email, YTMJSON.find("accountItem", in: s)))
            }
        }
        let responseSync = responseDataSyncID(root)
        var out: [YTMIdentityRow] = []
        var seen = Set<String>()
        for (email, items) in sources {
            for item in items {
                if item["isDisabled"] as? Bool == true || item["hasChannel"] as? Bool == false { continue }
                guard let name = runsText(item["accountName"]),
                      let endpoint = item.dict("serviceEndpoint")?.dict("selectActiveIdentityEndpoint") else { continue }
                var sync: String?
                var page: String?
                for token in (endpoint["supportedTokens"] as? [[String: Any]]) ?? [] {
                    for k in datasyncKeys where sync == nil {
                        if let s = normalizeDataSync(tokenString(token[k])) { sync = s }
                    }
                    if page == nil, let p = token.dict("pageIdToken")?.str("pageId"), !p.isEmpty { page = p }
                }
                let selected = item["isSelected"] as? Bool ?? false
                let id = sync ?? page ?? (selected ? responseSync : nil)
                guard let id, seen.insert(id).inserted else { continue }
                let channel = YTMJSON.browseID(item.dict("navigationEndpoint")).flatMap { $0.hasPrefix("UC") ? $0 : nil }
                out.append(YTMIdentityRow(id: id, pageID: page, name: name, handle: runsText(item["channelHandle"]), email: email,
                                          thumbnail: lastThumbnail(item["accountPhoto"]), channelID: channel, isSelected: selected))
            }
        }
        return out
    }
}

/// How a fresh sign-in picks its channel (pure, so every branch is testable).
enum YTMChannelDecision: Equatable, Sendable {
    case use(YTMIdentity)
    /// Check this delegated id with a one-off account menu before trusting it. `row` is the matching list row, if any.
    case validate(id: String, pageID: String?, hasMultiple: Bool)
    /// More than one channel and no remembered choice: the person must pick.
    case selectionRequired

    static func identity(header h: YTMAccountHeader, dataSyncID: String?, pageID: String?, hasMultiple: Bool) -> YTMIdentity {
        YTMIdentity(dataSyncID: dataSyncID, name: h.name, handle: h.handle, email: h.email, thumbnail: h.thumbnail, channelID: h.channelID,
                    pageID: pageID, hasMultiple: hasMultiple)
    }

    /// `persistedID` is the channel remembered for this account. A remembered id that the fresh list lacks belongs to another Google account
    /// and is dropped; with an empty list it is revalidated and the sign-in fails closed rather than using YouTube's default channel.
    static func decide(header h: YTMAccountHeader, rows: [YTMIdentityRow], persistedID: String?) -> YTMChannelDecision {
        var persisted = persistedID
        if let p = persisted, !rows.isEmpty, !rows.contains(where: { $0.id == p }) { persisted = nil }
        if let p = persisted {
            if rows.isEmpty { return .validate(id: p, pageID: nil, hasMultiple: false) }
            let row = rows.first { $0.id == p }
            if rows.count == 1 { return .use(identity(header: h, dataSyncID: p, pageID: row?.pageID, hasMultiple: false)) }
            return .validate(id: p, pageID: row?.pageID, hasMultiple: true)
        }
        if rows.count == 1, let row = rows.first {
            let sync = h.dataSyncID ?? row.id
            return .use(identity(header: h, dataSyncID: sync, pageID: sync == row.id ? row.pageID : nil, hasMultiple: false))
        }
        if rows.count > 1 { return .selectionRequired }
        return .use(identity(header: h, dataSyncID: h.dataSyncID, pageID: nil, hasMultiple: false))
    }
}
