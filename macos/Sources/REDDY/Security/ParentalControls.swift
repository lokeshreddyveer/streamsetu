import Foundation
import CryptoKit
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import Observation

/// A PIN that hides chosen folders. While locked, content in those folders is missing from every list, search and result, as if
/// it were not in the library. Unlocking with the PIN shows it for a limited time; it locks again by itself, when the Mac sleeps,
/// and every time REDDY starts. The PIN is stored only as a salted hash.
@MainActor @Observable
final class ParentalControls {
    enum UnlockResult: Equatable { case unlocked, wrongPIN(attemptsLeft: Int), tooManyAttempts(retryIn: TimeInterval), noPIN }

    private let catalog: SQLiteCatalogRepository
    private let defaults: UserDefaults
    private let now: () -> Date
    private var relockTask: Task<Void, Never>?
    nonisolated(unsafe) private var sleepObserver: NSObjectProtocol?
    nonisolated(unsafe) private var activeObserver: NSObjectProtocol?
    deinit {
        for o in [sleepObserver, activeObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(o)
            #if os(macOS)
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            #endif
        }
    }

    private(set) var isUnlocked = false
    private(set) var unlockedUntil: Date?
    private(set) var lockedCategoryIDs: Set<String> = []
    /// A kids profile is in use: the locked folders stay hidden and cannot be unlocked from here (the profile's own PIN is needed to leave it).
    var kidsMode = false {
        didSet {
            guard kidsMode != oldValue else { return }
            if kidsMode { isUnlocked = false; unlockedUntil = nil; relockTask?.cancel() }
            applyRestriction()
        }
    }
    /// Called whenever what is visible may have changed, so screens reload.
    var onChange: () -> Void = {}
    private var restrictionObservers: [() -> Void] = []
    /// Observers are called first, in the same call that changed the restriction and before `onChange`: whatever was built or kept while the folder was visible (caches, widget payload) is dropped there, not on the next rebuild.
    func observeRestriction(_ f: @escaping () -> Void) { restrictionObservers.append(f) }
    /// Folders that have just been locked (the folder and its family): their pictures, shown history and the like are purged.
    var onFoldersLocked: ([String]) -> Void = { _ in }
    /// The session unlocked with the PIN has ended: pictures of the locked folders that were loaded meanwhile are evicted.
    var onRelock: () -> Void = {}
    /// An unlocked session happened and the pictures of the locked folders have not been swept since (survives a crash or a quit while unlocked).
    var artworkSweepPending: Bool {
        get { defaults.bool(forKey: Keys.sweepPending) }
        set { defaults.set(newValue, forKey: Keys.sweepPending) }
    }

    static let maxAttempts = 5
    static let lockoutSeconds: TimeInterval = 60

    init(catalog: SQLiteCatalogRepository, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.catalog = catalog; self.defaults = defaults; self.now = now
        lockedCategoryIDs = (try? catalog.lockedCategoryIDs()) ?? []
        applyRestriction()
        #if os(macOS)
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockNow() }
        }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.relockIfExpired() }
        }
        #else
        // On iPhone and iPad, leaving the app plays the part of the Mac going to sleep.
        sleepObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockNow() }
        }
        activeObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.relockIfExpired() }
        }
        #endif
    }

    // MARK: PIN

    var hasPIN: Bool { defaults.string(forKey: Keys.hash) != nil }
    /// Folders are hidden right now.
    var isRestricting: Bool { kidsMode || (hasPIN && !isUnlocked) }
    var unlockMinutes: Int {
        get { let v = defaults.integer(forKey: Keys.minutes); return v == 0 ? 15 : v }
        set { defaults.set(max(1, min(240, newValue)), forKey: Keys.minutes) }
    }

    private enum Keys {
        static let sweepPending = "parental.artworksweep", hash = "parental.pinhash", salt = "parental.salt", minutes = "parental.minutes", failures = "parental.failures", lockedUntil = "parental.lockoutuntil"
    }

    static func isValidPIN(_ pin: String) -> Bool { (4...8).contains(pin.count) && pin.allSatisfy(\.isASCII) && pin.allSatisfy(\.isNumber) }

    /// What is stored for a PIN: see PINHash.
    private func hash(_ pin: String, salt: Data) -> String { PINHash.make(pin, salt: salt) }

    private func matches(_ pin: String) -> Bool {
        guard let stored = defaults.string(forKey: Keys.hash), let salt = defaults.data(forKey: Keys.salt) else { return false }
        switch PINHash.verify(pin, salt: salt, stored: stored) {
        case .right: return true
        case .rightButOld: defaults.set(hash(pin, salt: salt), forKey: Keys.hash); return true          // stored the old, fast way: now stored properly
        case .wrong: return false
        }
    }

    /// The same wrong-try count and lockout as unlocking, for the screens that change or remove the PIN: guessing there is no easier.
    private func checkWithThrottle(_ pin: String) -> Bool {
        if let until = defaults.object(forKey: Keys.lockedUntil) as? Date, until > now() { return false }
        guard matches(pin) else {
            let failures = defaults.integer(forKey: Keys.failures) + 1
            if failures >= Self.maxAttempts { defaults.set(0, forKey: Keys.failures); defaults.set(now().addingTimeInterval(Self.lockoutSeconds), forKey: Keys.lockedUntil) }
            else { defaults.set(failures, forKey: Keys.failures) }
            return false
        }
        defaults.set(0, forKey: Keys.failures)
        return true
    }

    /// Sets the first PIN, or replaces it when `current` is right.
    @discardableResult
    func setPIN(_ new: String, current: String? = nil) -> Bool {
        guard Self.isValidPIN(new) else { return false }
        if hasPIN { guard let current, checkWithThrottle(current) else { return false } }
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        defaults.set(salt, forKey: Keys.salt)
        defaults.set(hash(new, salt: salt), forKey: Keys.hash)
        defaults.set(0, forKey: Keys.failures)
        applyRestriction()
        return true
    }

    /// Removes the PIN. Folder locks are kept, but with no PIN nothing is hidden.
    @discardableResult
    func removePIN(current: String) -> Bool {
        guard hasPIN, checkWithThrottle(current) else { return false }
        defaults.removeObject(forKey: Keys.hash); defaults.removeObject(forKey: Keys.salt)
        isUnlocked = false; unlockedUntil = nil; relockTask?.cancel()
        applyRestriction()
        return true
    }

    // MARK: locking

    func unlock(pin: String) -> UnlockResult {
        guard hasPIN, !kidsMode else { return .noPIN }
        if let until = defaults.object(forKey: Keys.lockedUntil) as? Date, until > now() { return .tooManyAttempts(retryIn: until.timeIntervalSince(now())) }
        guard matches(pin) else {
            let failures = defaults.integer(forKey: Keys.failures) + 1
            if failures >= Self.maxAttempts {
                defaults.set(0, forKey: Keys.failures)
                defaults.set(now().addingTimeInterval(Self.lockoutSeconds), forKey: Keys.lockedUntil)
                return .tooManyAttempts(retryIn: Self.lockoutSeconds)
            }
            defaults.set(failures, forKey: Keys.failures)
            return .wrongPIN(attemptsLeft: Self.maxAttempts - failures)
        }
        defaults.set(0, forKey: Keys.failures); defaults.removeObject(forKey: Keys.lockedUntil)
        isUnlocked = true
        artworkSweepPending = true
        unlockedUntil = now().addingTimeInterval(TimeInterval(unlockMinutes * 60))
        scheduleRelock()
        applyRestriction()
        return .unlocked
    }

    func lockNow() {
        guard isUnlocked else { return }
        isUnlocked = false; unlockedUntil = nil; relockTask?.cancel()
        applyRestriction()
        onRelock()
    }

    /// Locks again if the unlock time has run out. Called by the timer and whenever the app becomes active.
    func relockIfExpired() { if isUnlocked, let u = unlockedUntil, u <= now() { lockNow() } }

    private func scheduleRelock() {
        relockTask?.cancel()
        guard let until = unlockedUntil else { return }
        let wait = max(1, until.timeIntervalSince(now()))
        relockTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.relockIfExpired()
        }
    }

    // MARK: folders

    /// Re-reads which folders are locked (after a backup was restored).
    /// A folder that is newly locked here (typically one locked on another device and arriving through iCloud) is treated exactly like one locked on this device: the same-named folders of the other
    /// playlists follow, and `onFoldersLocked` runs so what was kept about it (shown history, pictures, saved details) is dropped at once.
    func reloadLocks(onlyIfChanged: Bool = false) {
        let before = lockedCategoryIDs
        var now = (try? catalog.lockedCategoryIDs()) ?? []
        let arrived = now.subtracting(before)
        var all = arrived
        for id in arrived { if let family = try? catalog.setCategoryLocked(id, true, family: true) { all.formUnion(family) } }
        now.formUnion(all)
        if onlyIfChanged, now == before { return }
        lockedCategoryIDs = now
        if !all.isEmpty { onFoldersLocked(Array(all)) }
        applyRestriction()
    }

    /// Folders were hidden (here, or on another device): what is hidden changed, so everything keyed by the restriction is rebuilt, as for a lock.
    func foldersHiddenChanged() { applyRestriction() }

    func isLocked(_ categoryID: String) -> Bool { lockedCategoryIDs.contains(categoryID) }

    /// Locks a folder (needs a PIN to exist). Unlocking a folder needs the app to be unlocked first.
    @discardableResult
    func setFolder(_ categoryID: String, locked: Bool) -> Bool {
        guard hasPIN, locked || isUnlocked else { return false }
        // The same-named folders of the other playlists follow (and ones added later, see FolderFamily), so a twin folder cannot stand in for a locked one.
        let changed = (try? catalog.setCategoryLocked(categoryID, locked, family: true)) ?? [categoryID]
        if locked { lockedCategoryIDs.formUnion(changed) } else { lockedCategoryIDs.subtract(changed) }
        if locked { onFoldersLocked(changed) }
        applyRestriction()
        return true
    }

    /// Counts every change to what is hidden (a folder locked or unlocked, restriction switched on or off). Anything kept from an earlier look at the catalog is keyed by it.
    private(set) var restrictionRevision = 0

    private func applyRestriction() {
        restrictionRevision += 1
        catalog.restriction.isActive = kidsMode || (hasPIN && !isUnlocked)
        for f in restrictionObservers { f() }
        onChange()
    }
}
