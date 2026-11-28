import Foundation

/// Related-track autoplay for songs that came from SoundCloud: SoundCloud's own "related" list, without repeats and with a ceiling on how many
/// rows one starting song may add, so an endless run cannot grow the queue without bound.
enum SoundCloudRelated {
    /// Most rows one starting song may add over a whole run.
    static let perSeedCap = 60

    /// Related rows not seen before (by id and by title and artist), at most `room` of them, in SoundCloud's order.
    static func select(_ related: [MusicTrack], excluding seen: Set<String>, room: Int) -> [MusicTrack] {
        guard room > 0 else { return [] }
        var ids = seen
        var names = Set<String>()
        var out: [MusicTrack] = []
        for t in related {
            guard ids.insert(t.uid).inserted else { continue }
            let key = MusicText.normalize(t.title) + "|" + MusicText.normalize(t.artistLine)
            guard names.insert(key).inserted else { continue }
            out.append(t)
            if out.count >= room { break }
        }
        return out
    }
}

/// How many related rows each starting song has already handed out.
final class SoundCloudRelatedBudget: @unchecked Sendable {
    static let shared = SoundCloudRelatedBudget()
    private let lock = NSLock()
    private var used: [String: Int] = [:]

    func room(for seed: String, cap: Int = SoundCloudRelated.perSeedCap) -> Int {
        lock.lock(); defer { lock.unlock() }
        return max(0, cap - (used[seed] ?? 0))
    }
    func spend(_ n: Int, seed: String) {
        lock.lock(); defer { lock.unlock() }
        if used.count > 40 { used.removeAll() }
        used[seed, default: 0] += n
    }
}

extension SoundCloudProvider {
    /// The autoplay source for a SoundCloud seed; for any other seed it answers nothing.
    func autoplaySource(budget: SoundCloudRelatedBudget = .shared) -> MusicClosureAutoplaySource {
        let provider = self
        return MusicClosureAutoplaySource(name: "soundcloud-related") { request in
            let seed = request.seed
            guard seed.providerID == Self.providerID else { return [] }
            let room = budget.room(for: seed.uid)
            guard room > 0 else {
                MusicDebugLog.log("soundcloud", "related autoplay: cap reached for \(seed.uid)")
                return []
            }
            guard let related = try? await provider.relatedTracks(to: seed.id, limit: 40) else {
                MusicDebugLog.log("soundcloud", "related autoplay: no answer for \(seed.uid)")
                return []
            }
            var seen: Set<String> = [seed.uid]
            for t in request.recentSeeds { seen.insert(t.uid) }
            let picked = SoundCloudRelated.select(related, excluding: seen, room: min(room, max(request.want * 2, 20)))
            budget.spend(picked.count, seed: seed.uid)
            MusicDebugLog.log("soundcloud", "related autoplay: \(picked.count) rows for \(seed.uid)")
            return picked.enumerated().map { i, t in
                MusicAutoplayCandidate(track: t, reason: MusicAutoplayReason(.radio, seed.title), rank: i)
            }
        }
    }
}
