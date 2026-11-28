import Foundation

// Saved Google accounts. One row per Google account, keyed by a hash of its long-lived login value, so signing in again refreshes the row
// instead of adding another. The full cookie header and the login-bound visitor id are in the Keychain; the row (names, picture address,
// chosen channel) is a small JSON file. Rows list oldest first and a re-login never reorders them.

enum YTMAccountError: Error, LocalizedError, Sendable, Equatable {
    case signInIncomplete
    case notAuthenticated
    case sessionExpired
    case accountSessionExpired
    case switchFailed(String)
    case signInFailed(String)
    case signedOut
    case channelUnavailable
    case alreadyInPlaylist
    case notEditable
    case playlistEditRefused
    case libraryChangeRefused
    case coverRefused
    case noPlaylistID
    case writeUncertain
    case accountChanged
    case actionRejected
    case cannotClearWebSession
    case notAllowedTarget

    var errorDescription: String? {
        switch self {
        case .signInIncomplete: "Sign-in didn't complete."
        case .notAuthenticated: "That session didn't authenticate. Sign in again."
        case .sessionExpired: "Your YouTube Music session expired. Open the account menu and sign in again."
        case .accountSessionExpired: "That account's session has expired. Sign in with it again."
        case .switchFailed(let s): "Couldn't switch accounts: \(s)"
        case .signInFailed(let s): "Sign-in failed: \(s)"
        case .signedOut: "Sign in first to use this."
        case .channelUnavailable: "That YouTube channel is no longer available. Refresh the list."
        case .alreadyInPlaylist: "This track is already in the playlist."
        case .notEditable: "Only the playlist's owner can add songs to it."
        case .playlistEditRefused: "YouTube refused the playlist edit."
        case .libraryChangeRefused: "YouTube turned down the library change. Reopen the list and try again."
        case .coverRefused: "Custom playlist art needs a verified phone number on the account."
        case .noPlaylistID: "YouTube did not return a playlist id."
        case .writeUncertain: "That may have reached YouTube. Check before sending it again."
        case .accountChanged: "The signed-in account changed since this was loaded."
        case .actionRejected: "YouTube did not accept that action."
        case .cannotClearWebSession: "Could not clear the previous Google session. Nothing was changed."
        case .notAllowedTarget: "That list cannot be edited this way."
        }
    }
}

/// What the UI shows for a saved account. Display fields and an `isActive` flag only; never a credential.
struct YTMAccountSummary: Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var subtitle: String?
    var thumbnail: String?
    var isActive: Bool
    /// A multi-channel sign-in whose channel has not been chosen yet.
    var selectionPending: Bool
    var hasMultipleChannels: Bool
}

struct YTMAccountRecord: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var addedAt: Date
    /// nil while a multi-channel sign-in waits for its channel pick.
    var identity: YTMIdentity?
    var selectionPending: Bool { identity == nil }

    func summary(active: Bool) -> YTMAccountSummary {
        YTMAccountSummary(id: id, name: identity?.name ?? "Choose a channel", subtitle: identity?.subtitle, thumbnail: identity?.thumbnail,
                          isActive: active, selectionPending: selectionPending, hasMultipleChannels: identity?.hasMultiple ?? true)
    }
}

private struct YTMAccountsFile: Codable {
    var version: Int = 1
    var activeID: String?
    var accounts: [YTMAccountRecord] = []

    init() {}
    /// Tolerant: a missing field takes its default and unknown fields are ignored, so a newer or older file never blocks sign-in.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        activeID = try c.decodeIfPresent(String.self, forKey: .activeID)
        accounts = try c.decodeIfPresent([YTMAccountRecord].self, forKey: .accounts) ?? []
    }
    private enum Keys: String, CodingKey { case version, activeID, accounts }
}

final class YouTubeMusicAccountStore: @unchecked Sendable {
    static let fileName = "YouTubeMusicAccounts.json"
    static let currentVersion = 1

    private let lock = NSLock()
    private let url: URL
    private let secrets: YTMSecretStore
    private let now: @Sendable () -> Date
    private var file = YTMAccountsFile()

    init(directory: URL, secrets: YTMSecretStore = YTMKeychainSecretStore(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = directory.appendingPathComponent(Self.fileName)
        self.secrets = secrets
        self.now = now
        load()
    }

    // MARK: keys

    static func cookieKey(_ id: String) -> String { "ytm.cookie." + id }
    static func visitorKey(_ id: String) -> String { "ytm.visitor." + id }

    /// The row key for a cookie header, nil when it holds no login cookie.
    static func accountID(forCookieHeader h: String) -> String? { YTMCookieJar(header: h).accountKey }

    // MARK: reads

    /// Oldest first; ties broken by id so the order never flickers.
    func list() -> [YTMAccountRecord] {
        lock.withLock { file.accounts.sorted { ($0.addedAt, $0.id) < ($1.addedAt, $1.id) } }
    }
    var activeID: String? { lock.withLock { file.activeID } }
    func record(_ id: String) -> YTMAccountRecord? { lock.withLock { file.accounts.first { $0.id == id } } }
    var active: YTMAccountRecord? { lock.withLock { file.activeID.flatMap { id in file.accounts.first { $0.id == id } } } }
    func cookie(for id: String) -> String? { secrets.get(Self.cookieKey(id)) }
    func visitorData(for id: String) -> String? { secrets.get(Self.visitorKey(id)) }

    // MARK: writes

    /// Adds the account or refreshes its row. A known account keeps its position in the list.
    @discardableResult
    func upsert(cookieHeader: String, visitorData: String?, identity: YTMIdentity?) -> YTMAccountRecord? {
        guard let id = Self.accountID(forCookieHeader: cookieHeader) else { return nil }
        secrets.set(cookieHeader, for: Self.cookieKey(id))
        if let v = visitorData, !v.isEmpty { secrets.set(v, for: Self.visitorKey(id)) }
        let rec: YTMAccountRecord = lock.withLock {
            if let i = file.accounts.firstIndex(where: { $0.id == id }) {
                file.accounts[i].identity = identity
                persistLocked()
                return file.accounts[i]
            }
            let r = YTMAccountRecord(id: id, addedAt: now(), identity: identity)
            file.accounts.append(r)
            persistLocked()
            return r
        }
        return rec
    }

    /// Stores rotated cookies for a known account only (a late write for a removed row must not bring it back).
    func updateCookie(id: String, header: String) {
        guard record(id) != nil else { return }
        secrets.set(header, for: Self.cookieKey(id))
    }

    func updateVisitor(id: String, value: String) {
        guard record(id) != nil, !value.isEmpty else { return }
        secrets.set(value, for: Self.visitorKey(id))
    }

    func updateIdentity(id: String, _ identity: YTMIdentity?) {
        lock.withLock {
            guard let i = file.accounts.firstIndex(where: { $0.id == id }) else { return }
            file.accounts[i].identity = identity
            persistLocked()
        }
    }

    func setActive(_ id: String?) {
        lock.withLock {
            if let id, !file.accounts.contains(where: { $0.id == id }) { return }
            file.activeID = id
            persistLocked()
        }
    }

    /// Deletes the row and its Keychain items. Clears the active marker when it pointed here.
    func remove(_ id: String) {
        lock.withLock {
            file.accounts.removeAll { $0.id == id }
            if file.activeID == id { file.activeID = nil }
            persistLocked()
        }
        secrets.remove(Self.cookieKey(id))
        secrets.remove(Self.visitorKey(id))
    }

    func removeAll() { for r in list() { remove(r.id) } }

    // MARK: persistence

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        guard let f = try? JSONDecoder.accounts.decode(YTMAccountsFile.self, from: data) else {
            // An unreadable file is set aside, not deleted, and the Keychain rows stay untouched.
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("bad"))
            return
        }
        file = f
        // A row whose credential is gone cannot sign in; drop it so the menu never offers a dead entry.
        let before = file.accounts.count
        file.accounts.removeAll { secrets.get(Self.cookieKey($0.id)) == nil }
        if let a = file.activeID, !file.accounts.contains(where: { $0.id == a }) { file.activeID = nil }
        if file.version < Self.currentVersion { file.version = Self.currentVersion }
        if file.accounts.count != before || f.version < Self.currentVersion { persistLocked() }
    }

    private func persistLocked() {
        file.version = Self.currentVersion
        guard let data = try? JSONEncoder.accounts.encode(file) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
    }
}

private extension JSONEncoder {
    static var accounts: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; e.outputFormatting = [.sortedKeys]; return e }
}
private extension JSONDecoder {
    static var accounts: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }
}
