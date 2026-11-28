import Foundation

// The live session the YouTube Music client reads before every request. It holds the cookie jar of the ACTIVE account only.
// Rules it enforces by itself, so no caller can get them wrong:
//  - no cookie means no identity: a delegated id (and its page id) is never handed out without a login cookie;
//  - a page id is only handed out while the delegated id it was recorded for is still the current one;
//  - rotated cookies are merged into the jar, never replacing it, and empty values are ignored.

struct YTMSessionState: Sendable, Equatable {
    var jar: YTMCookieJar?
    var visitorData: String?
    var dataSyncID: String?
    var pageID: String?
    /// The delegated id `pageID` belongs to.
    var pageIDFor: String?
    /// While true the jar stays stored but requests go out as a guest (a multi-channel sign-in waiting for its channel pick).
    var held = false
}

final class YouTubeMusicSessionImpl: YouTubeMusicSession, @unchecked Sendable {
    private let lock = NSLock()
    private var state = YTMSessionState()
    private var rotationObserver: (@Sendable (_ accountKey: String, _ header: String) -> Void)?
    private var visitorObserver: (@Sendable (_ accountKey: String?, _ visitor: String) -> Void)?

    init(visitorData: String? = nil) { state.visitorData = visitorData }

    // MARK: protocol

    func snapshot() async -> YouTubeMusicSessionSnapshot { currentSnapshot() }

    func currentSnapshot() -> YouTubeMusicSessionSnapshot {
        lock.withLock {
            guard let jar = state.jar, jar.isSignedIn, !state.held else { return YouTubeMusicSessionSnapshot(visitorData: state.visitorData) }
            let page = (state.pageID != nil && state.pageIDFor == state.dataSyncID) ? state.pageID : nil
            return YouTubeMusicSessionSnapshot(cookieHeader: jar.header, visitorData: state.visitorData, dataSyncID: state.dataSyncID, pageID: page)
        }
    }

    func updateVisitorData(_ value: String) async {
        guard !value.isEmpty else { return }
        let key: String? = lock.withLock {
            state.visitorData = value
            return state.jar?.accountKey
        }
        let obs = lock.withLock { visitorObserver }
        obs?(key, value)
    }

    func merge(rotatedCookies: [(name: String, value: String)]) async {
        let result: (String, String)? = lock.withLock {
            guard var jar = state.jar, jar.isSignedIn, let key = jar.accountKey else { return nil }
            guard jar.merge(rotatedCookies) else { return nil }
            state.jar = jar
            return (key, jar.header)
        }
        guard let (key, header) = result else { return }
        let obs = lock.withLock { rotationObserver }
        obs?(key, header)
    }

    // MARK: state control (the account manager is the only caller)

    /// `key` is the account the jar belongs to, taken from the jar itself, so a racing account switch cannot file cookies under the wrong row.
    func setRotationObserver(_ f: (@Sendable (_ accountKey: String, _ header: String) -> Void)?) { lock.withLock { rotationObserver = f } }
    func setVisitorObserver(_ f: (@Sendable (_ accountKey: String?, _ visitor: String) -> Void)?) { lock.withLock { visitorObserver = f } }

    var current: YTMSessionState { lock.withLock { state } }
    var isSignedIn: Bool { lock.withLock { !state.held && (state.jar?.isSignedIn ?? false) } }
    var activeAccountKey: String? { lock.withLock { state.jar?.accountKey } }
    var jar: YTMCookieJar? { lock.withLock { state.jar } }

    func restore(_ s: YTMSessionState) { lock.withLock { state = s } }

    func activate(cookieHeader: String, visitorData: String?, dataSyncID: String?, pageID: String?, held: Bool = false) {
        let jar = YTMCookieJar(header: cookieHeader)
        lock.withLock {
            state.jar = jar.isSignedIn ? jar : nil
            state.visitorData = visitorData
            state.dataSyncID = dataSyncID
            state.pageID = pageID
            state.pageIDFor = pageID == nil ? nil : dataSyncID
            state.held = held
        }
    }

    func setIdentity(dataSyncID: String?, pageID: String?) {
        lock.withLock {
            state.dataSyncID = dataSyncID
            state.pageID = pageID
            state.pageIDFor = pageID == nil ? nil : dataSyncID
        }
    }

    func setVisitorData(_ v: String?) { lock.withLock { state.visitorData = v } }
    func setHeld(_ held: Bool) { lock.withLock { state.held = held } }

    /// Back to guest. The visitor id goes too: it was bound to the login.
    func deactivate() {
        lock.withLock { state = YTMSessionState() }
    }
}

/// Headers a private (uploaded) track's audio needs: it is served only to the owner, on the probe and on the stream itself.
enum YTMUploadStreamHeaders {
    static func apply(to headers: [String: String], snapshot: YouTubeMusicSessionSnapshot, isUpload: Bool) -> [String: String] {
        guard isUpload, snapshot.isSignedIn, let cookie = snapshot.cookieHeader else { return headers }
        var h = headers
        h["Cookie"] = cookie
        return h
    }
}
