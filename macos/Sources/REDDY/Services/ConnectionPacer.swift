import Foundation

/// How long to wait between closing one live stream and opening the next on the same provider. Providers that allow one connection take a
/// moment to notice the old one is gone; open the new one too soon and they answer with nothing. The wait is learned per provider: it
/// grows when a provider says "busy", and shrinks while it keeps working, so a relaxed provider is never slowed down.
final class ConnectionPacer: @unchecked Sendable {
    static let shortest: TimeInterval = 0.3, longest: TimeInterval = 5, initial: TimeInterval = 0.5

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var closedAt: [UUID: Date] = [:]
    private var gaps: [UUID: TimeInterval] = [:]

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ id: UUID) -> String { "pacer.gap.\(id.uuidString.lowercased())" }

    func gap(for source: UUID) -> TimeInterval {
        lock.withLock { gaps[source] ?? (defaults.object(forKey: key(source)) as? Double) ?? Self.initial }
    }

    /// A live stream from this provider has just been closed (or replaced).
    func closed(_ source: UUID, at now: Date = Date()) { lock.withLock { closedAt[source] = now } }

    /// How long to wait before opening a new live stream on this provider.
    func delay(for source: UUID, now: Date = Date()) -> TimeInterval {
        let g = gap(for: source)
        return lock.withLock { closedAt[source].map { max(0, g - now.timeIntervalSince($0)) } ?? 0 }
    }

    func recordBusy(_ source: UUID) { set(source, min(Self.longest, gap(for: source) * 2 + 0.5)) }
    func recordSuccess(_ source: UUID) { set(source, max(Self.shortest, gap(for: source) * 0.9)) }

    private func set(_ source: UUID, _ value: TimeInterval) {
        lock.withLock { gaps[source] = value }
        defaults.set(value, forKey: key(source))
    }
}
