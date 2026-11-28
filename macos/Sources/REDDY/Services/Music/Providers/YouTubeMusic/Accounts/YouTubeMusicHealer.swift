import Foundation

// Session healing. When YouTube rejects a signed-in request, the request waits for ONE heal and retries once. A heal asks a hidden web view
// (which keeps the Google session) for the rotated cookies. Rules:
//  - at most one heal per five minutes: nine 401s from one dead cookie are one fix;
//  - a heal "in flight" counter and a completed counter, so a heal that starts and ends between two looks of a waiter still counts;
//  - while a heal runs, waiters wait as long as it takes; with no heal running they give up after 90 seconds;
//  - the heal never moves the person to another account: the web view's session must be the account being healed.

actor YTMHealCoordinator {
    enum Outcome: Equatable, Sendable {
        /// A heal ran (or was already running) and has finished. The caller retries once whether or not cookies changed.
        case finished
        /// A heal ran within the cooldown, so none was started. The caller retries once anyway.
        case cooledDown
        /// No heal began within the wait limit.
        case timedOut
    }

    static let cooldown: TimeInterval = 5 * 60
    static let waiterTimeout: TimeInterval = 90

    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let heal: @Sendable (_ accountKey: String) async -> Void
    private var inFlight = 0
    private var completed = 0
    private var lastStart: Date?

    init(now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
         heal: @escaping @Sendable (_ accountKey: String) async -> Void) {
        self.now = now; self.sleep = sleep; self.heal = heal
    }

    var healsRunning: Int { inFlight }
    var healsCompleted: Int { completed }

    /// Starts a heal unless one ran in the last five minutes, then waits for it.
    func requestHeal(accountKey: String) async -> Outcome {
        let mark = completed
        if inFlight > 0 { return await wait(mark: mark) }
        if let last = lastStart, now().timeIntervalSince(last) < Self.cooldown { return .cooledDown }
        lastStart = now()
        inFlight += 1
        await heal(accountKey)
        inFlight -= 1
        completed += 1
        return .finished
    }

    /// Waits for a heal that somebody else triggers. Overlapping heals release waiters only after the last one ends.
    func waitForHeal() async -> Outcome { await wait(mark: completed) }

    private func wait(mark: Int) async -> Outcome {
        var idle: TimeInterval = 0
        let step: TimeInterval = 0.5
        while true {
            if completed > mark && inFlight == 0 { return .finished }
            if inFlight > 0 { idle = 0 } else {
                if idle >= Self.waiterTimeout { return .timedOut }
                idle += step
            }
            await sleep(step)
        }
    }
}

/// Decides whether a refreshed web-view jar is worth signing in with.
enum YTMHealRules {
    /// The jar must belong to the account being healed, and must differ from the one already in use. A jar that belongs to another
    /// account means the web view holds a different Google session, and nothing happens.
    static func isUsable(webJar: YTMCookieJar, expectedAccountKey: String, currentJar: YTMCookieJar?) -> Bool {
        guard webJar.isSignedIn, webJar.accountKey == expectedAccountKey else { return false }
        if let currentJar, currentJar.sameSet(as: webJar) { return false }
        return true
    }
}
