import Foundation
import Observation

// The account layer's brain. It signs in (validating the cookie and finding the channel), switches saved accounts, signs out, picks channels,
// keeps the session alive and heals it. Every state change goes through one lock so two auth operations never overlap, and every failure
// puts the previous session back.

/// First in, first out lock for async work. (An actor alone would not do: it lets other calls in at every await.)
actor YTMAuthLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if !locked { locked = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
    }
}

struct YTMAccountAPI: Sendable {
    let client: YouTubeMusicClient

    /// `identity` asks as that delegated id for one request (validating a channel before committing to it).
    func menu(identity: String? = nil) async throws -> YTMAccountHeader? {
        let r = try await client.post("account/account_menu", identityOverride: identity)
        return YTMIdentityParser.parseAccountMenu(r.root)
    }

    func channels() async throws -> [YTMIdentityRow] {
        let r = try await client.post("account/accounts_list")
        return YTMIdentityParser.parseAccountsList(r.root)
    }
}

private final class YTMWeakManager: @unchecked Sendable {
    weak var manager: YouTubeMusicAccountManager?
}

@MainActor @Observable
final class YouTubeMusicAccountManager: YTMSessionGuard {
    enum SignInOutcome: Equatable { case signedIn(YTMAccountSummary), selectionRequired }
    struct SignInRequest: Identifiable, Equatable { let id = UUID(); var addAccount: Bool }
    enum PickerMode: Equatable { case required, optional }

    // What the UI reads.
    private(set) var accounts: [YTMAccountSummary] = []
    private(set) var active: YTMAccountSummary?
    /// A multi-channel sign-in is waiting for its channel pick; the account is not usable until then.
    private(set) var selectionRequired = false
    /// Bumps on every sign-in, sign-out, account or channel switch, so pages and caches know to reload.
    private(set) var epoch = 0
    private(set) var busy = false
    var errorMessage: String?
    var notice: String?
    var signInRequest: SignInRequest?
    var pickerMode: PickerMode?

    @ObservationIgnored let provider: YouTubeMusicFullProvider
    @ObservationIgnored let session: YouTubeMusicSessionImpl
    @ObservationIgnored let store: YouTubeMusicAccountStore
    @ObservationIgnored private let api: YTMAccountAPI
    @ObservationIgnored private let auth = YTMAuthLock()
    @ObservationIgnored private var healer: YTMHealCoordinator
    @ObservationIgnored private var keepAliveTask: Task<Void, Never>?
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async -> Void
    @ObservationIgnored var keepAliveInterval: TimeInterval = 30 * 60
    /// Off in tests, so no background request competes with the one being checked.
    @ObservationIgnored private let keepAliveEnabled: Bool
    @ObservationIgnored var onAuthChanged: (() -> Void)?
    /// Replaceable so tests never open a web view. Returns a new cookie header or nil.
    @ObservationIgnored var refreshProvider: (@MainActor (_ expectedKey: String, _ current: YTMCookieJar?) async -> String?)?

    init(provider: YouTubeMusicFullProvider, session: YouTubeMusicSessionImpl, store: YouTubeMusicAccountStore, keepAlive: Bool = true,
         now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.provider = provider; self.session = session; self.store = store
        self.api = YTMAccountAPI(client: provider.client)
        self.sleep = sleep
        self.keepAliveEnabled = keepAlive
        let box = YTMWeakManager()
        self.healer = YTMHealCoordinator(now: now, sleep: sleep, heal: { key in await box.manager?.runHeal(accountKey: key) })
        box.manager = self
        session.setRotationObserver { [store] key, header in store.updateCookie(id: key, header: header) }
        session.setVisitorObserver { [store] key, v in if let key { store.updateVisitor(id: key, value: v) } }
        restoreActive()
        installDefaultRefresher()
    }

    private func installDefaultRefresher() {
        refreshProvider = { key, current in
            await YouTubeSessionRefresher().refresh(expectedAccountKey: key, current: current)
        }
    }

    var isSignedIn: Bool { active != nil && !selectionRequired }

    // MARK: restore

    /// Puts the remembered account back in the session at launch. No network: the keep-alive validates it later.
    func restoreActive() {
        guard let rec = store.active, let cookie = store.cookie(for: rec.id) else {
            // A guest launch keeps the anonymous visitor id; only a leftover login is cleared.
            if session.jar != nil { session.deactivate() }
            publish()
            return
        }
        session.activate(cookieHeader: cookie, visitorData: store.visitorData(for: rec.id), dataSyncID: rec.identity?.dataSyncID,
                         pageID: rec.identity?.pageID, held: rec.selectionPending)
        selectionRequired = rec.selectionPending
        if rec.selectionPending { pickerMode = .required }
        publish()
    }

    private func publish() {
        let activeID = store.activeID
        accounts = store.list().map { $0.summary(active: $0.id == activeID) }
        active = accounts.first { $0.isActive }
        if active != nil { startKeepAlive() } else { keepAliveTask?.cancel(); keepAliveTask = nil }
    }

    private func authChanged() {
        provider.clearCaches()
        epoch += 1
        publish()
        onAuthChanged?()
    }

    // MARK: serialisation

    private func serialized<T>(_ op: () async throws -> T) async throws -> T {
        await auth.acquire()
        busy = true
        do { let r = try await op(); busy = false; await auth.release(); return r }
        catch { busy = false; await auth.release(); throw error }
    }

    private func mapped(_ e: Error, as wrap: (String) -> YTMAccountError) -> Error {
        if e is YTMAccountError || e is CancellationError { return e }
        if let m = e as? MusicError {
            if case .notSignedIn = m { return YTMAccountError.notAuthenticated }
            return wrap(m.errorDescription ?? "network problem")
        }
        return wrap("network problem")
    }

    // MARK: sign in

    /// Validates a captured cookie, finds the channel and makes the account active. `expectAccount` (used by the healer) refuses to run when the
    /// active account is no longer that one.
    @discardableResult
    func signIn(cookieHeader raw: String, expectAccount: String? = nil) async throws -> SignInOutcome {
        try await serialized {
            let jar = YTMCookieJar(header: raw.trimmingCharacters(in: .whitespacesAndNewlines))
            guard jar.isSignedIn, let key = jar.accountKey else { throw YTMAccountError.signInIncomplete }
            if let expect = expectAccount, expect != key || store.activeID != expect { throw YTMAccountError.accountChanged }
            let previous = session.current
            let known = store.record(key)
            session.activate(cookieHeader: jar.header, visitorData: store.visitorData(for: key), dataSyncID: nil, pageID: nil)
            do {
                let outcome = try await finishSignIn(jar: jar, key: key, persistedID: known?.identity?.dataSyncID)
                return outcome
            } catch {
                session.restore(previous)
                throw mapped(error) { YTMAccountError.signInFailed($0) }
            }
        }
    }

    /// Steps 3 to 7 of a sign-in, with the candidate cookie already installed. Throws without touching stored state.
    private func finishSignIn(jar: YTMCookieJar, key: String, persistedID: String?) async throws -> SignInOutcome {
        guard let header = try await api.menu() else { throw YTMAccountError.notAuthenticated }
        if let v = header.visitorData { session.setVisitorData(v) }
        let rows = (try? await api.channels()) ?? []   // not fatal: an ordinary single-channel account
        let decision = YTMChannelDecision.decide(header: header, rows: rows, persistedID: persistedID)
        switch decision {
        case .selectionRequired:
            store.upsert(cookieHeader: jar.header, visitorData: session.current.visitorData, identity: nil)
            store.setActive(key)
            session.setIdentity(dataSyncID: nil, pageID: nil)
            session.setHeld(true)
            selectionRequired = true
            pickerMode = .required
            authChanged()
            return .selectionRequired
        case .validate(let id, let page, let multiple):
            guard let checked = try await api.menu(identity: id) else { throw YTMAccountError.notAuthenticated }
            let ident = YTMChannelDecision.identity(header: checked, dataSyncID: id, pageID: page, hasMultiple: multiple)
            return commit(jar: jar, key: key, identity: ident)
        case .use(let ident):
            return commit(jar: jar, key: key, identity: ident)
        }
    }

    private func commit(jar: YTMCookieJar, key: String, identity: YTMIdentity) -> SignInOutcome {
        let visitor = session.current.visitorData
        // The jar may have been rotated while validating; store what the session holds now.
        let header = session.jar?.header ?? jar.header
        store.upsert(cookieHeader: header, visitorData: visitor, identity: identity)
        store.setActive(key)
        session.activate(cookieHeader: header, visitorData: visitor, dataSyncID: identity.dataSyncID, pageID: identity.pageID)
        selectionRequired = false
        pickerMode = nil
        authChanged()
        return .signedIn(store.record(key)?.summary(active: true) ?? YTMAccountSummary(id: key, name: identity.name, subtitle: identity.subtitle, thumbnail: identity.thumbnail, isActive: true, selectionPending: false, hasMultipleChannels: identity.hasMultiple))
    }

    // MARK: switch, sign out, remove

    func switchAccount(to id: String) async throws {
        try await serialized {
            guard let rec = store.record(id), let cookie = store.cookie(for: id) else { throw YTMAccountError.accountSessionExpired }
            let previous = session.current
            let previousActive = store.activeID
            session.activate(cookieHeader: cookie, visitorData: store.visitorData(for: id), dataSyncID: rec.identity?.dataSyncID,
                             pageID: rec.identity?.pageID)
            do {
                guard let header = try await api.menu() else { throw YTMAccountError.accountSessionExpired }
                if let v = header.visitorData { session.setVisitorData(v); store.updateVisitor(id: id, value: v) }
                store.setActive(id)
                if rec.selectionPending {
                    session.setHeld(true)
                    selectionRequired = true
                    pickerMode = .required
                } else {
                    selectionRequired = false
                    pickerMode = nil
                }
                authChanged()
            } catch {
                session.restore(previous)
                store.setActive(previousActive)
                let m = mapped(error) { YTMAccountError.switchFailed($0) }
                if (m as? YTMAccountError) == .notAuthenticated { throw YTMAccountError.accountSessionExpired }
                throw m
            }
        }
    }

    /// Back to guest. Saved accounts stay, so one click brings one back.
    func signOut() {
        session.deactivate()
        store.setActive(nil)
        selectionRequired = false
        pickerMode = nil
        authChanged()
    }

    func remove(_ id: String) {
        let wasActive = store.activeID == id
        store.remove(id)
        if wasActive { signOut() } else { publish() }
    }

    /// Cancels a multi-channel sign-in that never got its channel: the half-finished account is removed.
    func cancelPendingSignIn() {
        if let a = active, a.selectionPending { store.remove(a.id) }
        signOut()
    }

    // MARK: channels

    /// The channels of the signed-in Google account, fresh each time. While a pick is pending nothing is marked selected.
    func channels() async throws -> [YTMIdentityRow] {
        try await serialized {
            guard let a = active else { throw YTMAccountError.signedOut }
            let wasHeld = session.current.held
            if wasHeld { session.setHeld(false) }
            defer { if wasHeld { session.setHeld(true) } }
            do {
                let persisted = store.record(a.id)?.identity?.dataSyncID
                return try await api.channels().map { var r = $0; r.isSelected = persisted != nil && persisted == r.id; return r }
            } catch { throw mapped(error) { YTMAccountError.signInFailed($0) } }
        }
    }

    /// Chooses a channel by the opaque key the UI was given. The raw delegated id never reaches a view.
    func selectChannel(key: String) async throws {
        try await serialized {
            guard let a = active, let jar = session.jar else { throw YTMAccountError.signedOut }
            let previous = session.current
            let wasPending = a.selectionPending
            session.setHeld(false)
            do {
                let rows = try await api.channels()
                guard let row = rows.first(where: { $0.selectionKey == key }) else { throw YTMAccountError.channelUnavailable }
                guard let checked = try await api.menu(identity: row.id) else { throw YTMAccountError.notAuthenticated }
                let ident = YTMChannelDecision.identity(header: checked, dataSyncID: row.id, pageID: row.pageID, hasMultiple: rows.count > 1)
                _ = commit(jar: jar, key: a.id, identity: ident)
                notice = wasPending ? "Signed in as \(ident.name)" : "Switched to \(ident.name)"
            } catch {
                session.restore(previous)
                throw mapped(error) { YTMAccountError.switchFailed($0) }
            }
        }
    }

    // MARK: sign-in sheet requests

    func requestSignIn(addAccount: Bool) { signInRequest = SignInRequest(addAccount: addAccount) }

    // MARK: keep-alive and healing

    func startKeepAlive() {
        guard keepAliveEnabled, keepAliveTask == nil else { return }
        keepAliveTask = Task { [weak self] in
            var first = true
            while !Task.isCancelled {
                guard let self else { return }
                await self.keepAliveOnce(heal: !first)
                first = false
                let s = self.sleep, i = self.keepAliveInterval
                await s(i)
            }
        }
    }

    /// One account-menu request. Rotation only happens on requests the app makes, so without this the short-lived cookies would lapse.
    /// The first one after launch runs with healing off: nothing listens for a rejection yet.
    func keepAliveOnce(heal: Bool = true) async {
        guard let id = active?.id, !selectionRequired, session.activeAccountKey == id else { return }
        let header: YTMAccountHeader?
        let api = self.api
        do {
            header = heal ? try await run { try await api.menu() } : try await api.menu()
        } catch { return }
        guard let header, session.activeAccountKey == id else { return }   // re-checked after the await: the account may have changed
        if let v = header.visitorData { session.setVisitorData(v); store.updateVisitor(id: id, value: v) }
        if let h = session.jar?.header { store.updateCookie(id: id, header: h) }
    }

    func run<T: Sendable>(_ op: @Sendable () async throws -> T) async throws -> T {
        do { return try await op() } catch MusicError.notSignedIn {
            guard let key = session.activeAccountKey else { throw YTMAccountError.sessionExpired }
            _ = await healer.requestHeal(accountKey: key)
            do { return try await op() } catch MusicError.notSignedIn { throw YTMAccountError.sessionExpired }
        }
    }

    fileprivate func runHeal(accountKey: String) async {
        guard store.activeID == accountKey, !selectionRequired, let refresh = refreshProvider else { return }
        guard let header = await refresh(accountKey, session.jar) else { return }
        // Nothing is shown on failure; a rejected sign-in leaves the session as it was.
        _ = try? await signIn(cookieHeader: header, expectAccount: accountKey)
    }

    // MARK: building blocks for the rest of the app

    var writer: YouTubeMusicWriter { YouTubeMusicWriter(client: provider.client, sessionGuard: self) }
    var library: YouTubeMusicLibrary { YouTubeMusicLibrary(provider: provider, sessionGuard: self) }
    var comments: YouTubeMusicComments { YouTubeMusicComments(client: provider.client) }
    var historyProvider: YouTubeMusicHistoryProvider { YouTubeMusicHistoryProvider(client: provider.client) }
}
