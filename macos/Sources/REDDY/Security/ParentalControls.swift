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
    private var sleepObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?

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
        static let hash = "parental.pinhash", salt = "parental.salt", minutes = "parental.minutes", failures = "parental.failures", lockedUntil = "parental.lockoutuntil"
    }

    static func isValidPIN(_ pin: String) -> Bool { (4...8).contains(pin.count) && pin.allSatisfy(\.isASCII) && pin.allSatisfy(\.isNumber) }

    private func hash(_ pin: String, salt: Data) -> String {
        SHA256.hash(data: salt + Data(pin.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func matches(_ pin: String) -> Bool {
        guard let stored = defaults.string(forKey: Keys.hash), let salt = defaults.data(forKey: Keys.salt) else { return false }
        let candidate = hash(pin, salt: salt)
        // compared in full whatever the first difference, so timing says nothing about the PIN
        return zip(Array(candidate.utf8), Array(stored.utf8)).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0 && candidate.count == stored.count
    }

    /// Sets the first PIN, or replaces it when `current` is right.
    @discardableResult
    func setPIN(_ new: String, current: String? = nil) -> Bool {
        guard Self.isValidPIN(new) else { return false }
        if hasPIN { guard let current, matches(current) else { return false } }
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
        guard hasPIN, matches(current) else { return false }
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
        unlockedUntil = now().addingTimeInterval(TimeInterval(unlockMinutes * 60))
        scheduleRelock()
        applyRestriction()
        return .unlocked
    }

    func lockNow() {
        guard isUnlocked else { return }
        isUnlocked = false; unlockedUntil = nil; relockTask?.cancel()
        applyRestriction()
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
    func reloadLocks() { lockedCategoryIDs = (try? catalog.lockedCategoryIDs()) ?? []; applyRestriction() }

    func isLocked(_ categoryID: String) -> Bool { lockedCategoryIDs.contains(categoryID) }

    /// Locks a folder (needs a PIN to exist). Unlocking a folder needs the app to be unlocked first.
    @discardableResult
    func setFolder(_ categoryID: String, locked: Bool) -> Bool {
        guard hasPIN, locked || isUnlocked else { return false }
        try? catalog.setCategoryLocked(categoryID, locked)
        if locked { lockedCategoryIDs.insert(categoryID) } else { lockedCategoryIDs.remove(categoryID) }
        applyRestriction()
        return true
    }

    private func applyRestriction() {
        catalog.restriction.isActive = kidsMode || (hasPIN && !isUnlocked)
        onChange()
    }
}
