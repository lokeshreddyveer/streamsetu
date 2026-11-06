import Foundation
import LocalAuthentication
import Observation
#if canImport(AppKit)
import AppKit
#endif

/// How the app asks the person to prove it is them. The real one uses Face ID, Touch ID or the device passcode.
protocol LockAuthenticator: Sendable {
    /// nil when the device cannot authenticate at all (no passcode set), otherwise what it uses ("Face ID", "Touch ID", "passcode").
    func availableMethod() -> String?
    func authenticate(reason: String) async -> Bool
}

struct SystemAuthenticator: LockAuthenticator {
    func availableMethod() -> String? {
        let c = LAContext()
        var err: NSError?
        guard c.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return nil }
        switch c.biometryType { case .faceID: return "Face ID"; case .touchID: return "Touch ID"; case .opticID: return "Optic ID"; default: return "passcode" }
    }
    func authenticate(reason: String) async -> Bool {
        (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

enum LockPolicy {
    /// The app locks again when it was away for at least this long (a quick look at another app does not ask again).
    static let grace: TimeInterval = 30
    static func shouldLock(leftAt: Date?, now: Date, grace: TimeInterval = LockPolicy.grace) -> Bool {
        guard let leftAt else { return false }
        return now.timeIntervalSince(leftAt) >= grace
    }
}

/// An optional lock for the whole app. Playback is never touched: a stream that is playing keeps playing behind the lock.
@MainActor @Observable
final class AppLock {
    private let settings: AppSettings
    private let auth: LockAuthenticator
    private let now: () -> Date
    private var leftAt: Date?
    private var observers: [NSObjectProtocol] = []

    private(set) var isLocked: Bool
    private(set) var isAuthenticating = false
    var enabled: Bool { settings.appLock }
    var method: String { auth.availableMethod() ?? "passcode" }
    var canEnable: Bool { auth.availableMethod() != nil }

    init(settings: AppSettings, auth: LockAuthenticator = SystemAuthenticator(), now: @escaping () -> Date = Date.init) {
        self.settings = settings; self.auth = auth; self.now = now
        isLocked = settings.appLock && auth.availableMethod() != nil
        #if canImport(AppKit)
        let nc = NotificationCenter.default, ws = NSWorkspace.shared.notificationCenter
        observers = [
            nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.appLeft() } },
            nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.appReturned() } },
            ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.lockNow() } },
        ]
        #endif
    }

    /// Turning it on proves once that it works, so a person is never locked out by a switch that cannot be answered.
    func setEnabled(_ on: Bool) async {
        if on {
            guard canEnable, await auth.authenticate(reason: "Turn on App Lock") else { return }
            settings.appLock = true
        } else {
            guard await auth.authenticate(reason: "Turn off App Lock") else { return }
            settings.appLock = false; isLocked = false
        }
    }

    func appLeft() { if enabled, !isLocked { leftAt = now() } }
    func appReturned() {
        if enabled, LockPolicy.shouldLock(leftAt: leftAt, now: now()) { isLocked = true }
        leftAt = nil
    }
    func lockNow() { if enabled { isLocked = true } }

    // MARK: what the system hands to a locked app

    /// What to do with a link or a file the system opens in the app.
    enum LinkDisposition: Equatable { case runNow, holdUntilUnlocked, drop }

    /// The newest link opened while locked; handed back once, after unlocking.
    private(set) var heldLink: URL?

    /// While locked nothing a link asks for may happen behind the lock. A link that opens something waits for the person to unlock; a command for what is playing
    /// (pause, stop, next, a sleep timer) is dropped, because it would be stale, and surprising, by then.
    func disposition(for url: URL) -> LinkDisposition {
        guard isLocked else { return .runNow }
        if let link = DeepLink.parse(url), link.isCommand { return .drop }
        return .holdUntilUnlocked
    }

    func hold(_ url: URL) { heldLink = url }

    /// The held link, once and only when unlocked.
    func takeHeldLink() -> URL? {
        guard !isLocked, let url = heldLink else { return nil }
        heldLink = nil
        return url
    }

    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        if await auth.authenticate(reason: "Unlock StreamSetu") { isLocked = false; leftAt = nil }
    }
}
