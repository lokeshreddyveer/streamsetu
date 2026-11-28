import Foundation

/// Looks up the stream for songs the person is likely to play next (the top few search results, the row under the pointer) so pressing play finds
/// the stream already resolved and checked. Strictly bounded: a few songs per hint, a couple of lookups at once, never on a metered link, never
/// while Music has been idle for a long time, and a newer hint cancels whatever the older one has not finished.
@MainActor
final class MusicPreResolver {
    struct Limits: Sendable {
        var perHint = 3
        var inflight = 2
        /// A song warmed this recently is not asked again.
        var recent: TimeInterval = 5 * 60
        /// No lookups when the person has not touched Music for this long.
        var idle: TimeInterval = 10 * 60
    }

    let limits: Limits
    private let now: () -> Date
    private let allowed: @MainActor () -> Bool
    private let warm: @Sendable (MusicTrack) async -> Void
    private var lastActivity: Date
    private var warmed: [String: Date] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private(set) var started = 0

    /// `allowed` is false on a metered link or when playback is blocked; `warm` resolves one song (and may throw away the result).
    init(limits: Limits = Limits(), now: @escaping () -> Date = { Date() }, allowed: @escaping @MainActor () -> Bool = { true },
         warm: @escaping @Sendable (MusicTrack) async -> Void) {
        self.limits = limits; self.now = now; self.allowed = allowed; self.warm = warm; self.lastActivity = now()
    }

    /// Any press, search or hover in Music.
    func noteActivity() { lastActivity = now() }

    var inflightCount: Int { tasks.count }

    /// Asks for these songs to be warmed, best first. Returns the uids actually started. `background` marks a hint the app raised by itself.
    @discardableResult
    func hint(_ tracks: [MusicTrack], background: Bool = false) -> [String] {
        // A hint from the person's own action counts as activity; one the app raised by itself is dropped once Music has been idle too long.
        if background { guard !isIdle else { return [] } } else { noteActivity() }
        guard allowed() else { cancelAll(); return [] }
        let t = now()
        warmed = warmed.filter { t.timeIntervalSince($0.value) < limits.recent }
        let wanted = tracks.filter { $0.directStreams?.first.map { !(URL(string: $0.url)?.isFileURL ?? false) } ?? true }
            .filter { warmed[$0.uid] == nil }
            .prefix(limits.perHint)
        // A newer hint replaces the older one: lookups that are not in the new list are cancelled.
        let keep = Set(wanted.map(\.uid))
        for (uid, task) in tasks where !keep.contains(uid) { task.cancel(); tasks[uid] = nil }
        var begun: [String] = []
        for track in wanted where tasks[track.uid] == nil {
            guard tasks.count < limits.inflight else { break }
            warmed[track.uid] = t
            started += 1
            let warm = self.warm
            let uid = track.uid
            tasks[uid] = Task { [weak self] in
                await warm(track)
                self?.finished(uid)
            }
            begun.append(uid)
        }
        return begun
    }

    /// True when the idle limit has passed: the caller should not start lookups.
    var isIdle: Bool { now().timeIntervalSince(lastActivity) > limits.idle }

    func cancelAll() { tasks.values.forEach { $0.cancel() }; tasks = [:] }

    private func finished(_ uid: String) { tasks[uid] = nil }
}
