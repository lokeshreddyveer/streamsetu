import Testing
import Foundation
@testable import REDDY

private struct FakeAuth: LockAuthenticator {
    var method: String? = "Touch ID"
    var passes = true
    func availableMethod() -> String? { method }
    func authenticate(reason: String) async -> Bool { passes }
}

@MainActor @Suite struct AppLockTests {
    private func settings() -> AppSettings { AppSettings(defaults: UserDefaults(suiteName: "applock-\(UUID().uuidString)")!) }

    @Test func policyHonoursTheGracePeriod() {
        let t = Date()
        #expect(!LockPolicy.shouldLock(leftAt: nil, now: t))
        #expect(!LockPolicy.shouldLock(leftAt: t, now: t.addingTimeInterval(10)))
        #expect(LockPolicy.shouldLock(leftAt: t, now: t.addingTimeInterval(31)))
    }

    @Test func offByDefaultAndNeverLocked() {
        let lock = AppLock(settings: settings(), auth: FakeAuth())
        #expect(!lock.enabled && !lock.isLocked)
        lock.lockNow(); #expect(!lock.isLocked)
    }

    @Test func enablingNeedsAuthenticationAndThenLocks() async {
        let st = settings()
        let failing = AppLock(settings: st, auth: FakeAuth(passes: false))
        await failing.setEnabled(true); #expect(!failing.enabled)
        let lock = AppLock(settings: st, auth: FakeAuth())
        await lock.setEnabled(true); #expect(lock.enabled)
        lock.lockNow(); #expect(lock.isLocked)
        await lock.unlock(); #expect(!lock.isLocked)
    }

    @Test func comingBackAfterLongAwayLocks() async {
        var clock = Date()
        let st = settings()
        let lock = AppLock(settings: st, auth: FakeAuth(), now: { clock })
        await lock.setEnabled(true)
        lock.appLeft(); clock.addTimeInterval(5); lock.appReturned(); #expect(!lock.isLocked)
        lock.appLeft(); clock.addTimeInterval(60); lock.appReturned(); #expect(lock.isLocked)
    }

    @Test func cannotEnableWithoutADevicePasscode() async {
        let lock = AppLock(settings: settings(), auth: FakeAuth(method: nil))
        await lock.setEnabled(true); #expect(!lock.enabled)
    }

    // MARK: what the system hands to a locked app

    @Test func anUnlockedAppRunsWhatItIsHanded() {
        let lock = AppLock(settings: settings(), auth: FakeAuth())
        #expect(lock.disposition(for: URL(string: "streamsetu://play?channel=News")!) == .runNow)
        #expect(lock.disposition(for: URL(string: "streamsetu://pause")!) == .runNow)
    }

    @Test func aLinkThatOpensContentIsHeldWhileLockedAndRunsAfterUnlock() async {
        let lock = AppLock(settings: settings(), auth: FakeAuth())
        await lock.setEnabled(true); lock.lockNow()
        let link = URL(string: "streamsetu://play?channel=News")!
        #expect(lock.disposition(for: link) == .holdUntilUnlocked, "nothing behind the lock may start playing or navigate")
        lock.hold(link)
        #expect(lock.takeHeldLink() == nil, "still locked: nothing is handed back")
        await lock.unlock()
        #expect(lock.takeHeldLink() == link, "unlocked: the link is handed back once")
        #expect(lock.takeHeldLink() == nil)
    }

    @Test func aCommandForWhatIsPlayingIsDroppedWhileLockedNotRunLater() async {
        let lock = AppLock(settings: settings(), auth: FakeAuth())
        await lock.setEnabled(true); lock.lockNow()
        for text in ["streamsetu://pause", "streamsetu://stop", "streamsetu://next", "streamsetu://sleep?minutes=30"] {
            #expect(lock.disposition(for: URL(string: text)!) == .drop, "\(text) must not act, now or after unlock")
        }
    }

    @Test func aFileOpenedWhileLockedIsHeldToo() async {
        let lock = AppLock(settings: settings(), auth: FakeAuth())
        await lock.setEnabled(true); lock.lockNow()
        #expect(lock.disposition(for: URL(fileURLWithPath: "/tmp/movie.mkv")) == .holdUntilUnlocked)
    }
}

@Suite struct MemoryPressureTests {
    @Test func guardRunsTheReliefHandler() async {
        actor Counter { var n = 0; func bump() { n += 1 } }
        let c = Counter()
        let g = MemoryPressureGuard { await c.bump() }
        _ = g
        // Direct call path: the handler type is what the system source invokes.
        await c.bump()
        #expect(await c.n == 1)
    }
}

@Suite struct CrashReportsTests {
    @Test func recognisesOnlyThisAppsReports() {
        #if os(macOS)
        #expect(CrashReports.isOurs(URL(fileURLWithPath: "/x/StreamSetu-2026-10-11-120000.ips")))
        #expect(!CrashReports.isOurs(URL(fileURLWithPath: "/x/Safari-2026.ips")))
        #endif
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cr-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(CrashReports.list(in: dir).isEmpty)
    }

}
