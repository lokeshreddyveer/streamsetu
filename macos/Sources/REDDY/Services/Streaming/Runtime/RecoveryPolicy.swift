import Foundation

enum TerminationAction: Equatable, Sendable { case reload, showRetryCard }

/// What to do when a web content process stops: reload by itself a couple of times, then leave the decision to the person (no reload loops).
struct RecoveryPolicy: Equatable, Sendable {
    var maxAutoReloads = 2
    var window: TimeInterval = 60
    static let standard = RecoveryPolicy()

    /// `terminations` includes the one that just happened.
    func action(terminations: [Date], now: Date) -> TerminationAction {
        terminations.filter { now.timeIntervalSince($0) < window }.count <= maxAutoReloads ? .reload : .showRetryCard
    }

    /// The terminations still inside the window.
    func recent(_ terminations: [Date], now: Date) -> [Date] { terminations.filter { now.timeIntervalSince($0) < window } }
}
