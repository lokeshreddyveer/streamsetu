import Foundation

/// Slows down guessing of a PIN: after a few wrong tries in a row, every try is refused for a minute. One of these per PIN, so every screen that asks for that PIN shares the same count.
struct PINThrottle: @unchecked Sendable {
    static let maxAttempts = 5
    static let lockoutSeconds: TimeInterval = 60

    private let defaults: UserDefaults
    private let name: String
    private let now: () -> Date

    init(name: String, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) { self.name = name; self.defaults = defaults; self.now = now }

    private var failuresKey: String { "pinthrottle.failures." + name }
    private var untilKey: String { "pinthrottle.until." + name }

    /// Seconds until a try is allowed again, or nil when one is allowed now.
    func lockedFor() -> TimeInterval? {
        guard let until = defaults.object(forKey: untilKey) as? Date, until > now() else { return nil }
        return until.timeIntervalSince(now())
    }

    /// Checks a try. `matches` is only called when a try is allowed. Returns nil for a right PIN, otherwise how many tries are left (0 when this one locked it).
    enum Outcome: Equatable { case right, wrong(attemptsLeft: Int), locked(retryIn: TimeInterval) }

    func attempt(_ matches: () -> Bool) -> Outcome {
        if let wait = lockedFor() { return .locked(retryIn: wait) }
        if matches() { defaults.set(0, forKey: failuresKey); defaults.removeObject(forKey: untilKey); return .right }
        let failures = defaults.integer(forKey: failuresKey) + 1
        if failures >= Self.maxAttempts {
            defaults.set(0, forKey: failuresKey)
            defaults.set(now().addingTimeInterval(Self.lockoutSeconds), forKey: untilKey)
            return .wrong(attemptsLeft: 0)
        }
        defaults.set(failures, forKey: failuresKey)
        return .wrong(attemptsLeft: Self.maxAttempts - failures)
    }
}
