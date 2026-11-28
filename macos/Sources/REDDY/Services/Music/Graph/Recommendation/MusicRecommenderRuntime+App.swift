import Foundation

// The app side of the recommender (kept out of the iOS-neutral pure files and out of the test package: it names the hub, the history and `Localized`).

extension MusicRecWording {
    /// Every reason reads from the app's string tables; names are filled in with `%@` and joined with the localised "and".
    static let localized = MusicRecWording(
        template: { Localized.string($0) },
        join: { names in
            switch names.count {
            case 0: return ""
            case 1: return names[0]
            default: return Localized.string("%1$@ and %2$@", names.dropLast().joined(separator: ", "), names[names.count - 1])
            }
        })
}

extension MusicRecExplanation {
    /// The line the card shows, in the person's language.
    var localizedText: String { text(.localized) }
}

/// The app's one recommender over the app's graph store, with the device-local affinity built from the play history. Created on first use.
/// Nothing here writes: affinity is derived from `hub.library.history` on demand, held in memory for a few minutes, and never sent anywhere.
final class MusicRecommenderRuntime: @unchecked Sendable {
    static let shared = MusicRecommenderRuntime()

    let affinity: MusicAffinityStore
    let recommender: MusicRecommender
    private static let floorKey = "music.rec.affinityResetAt"

    private init() {
        let graph = MusicGraphRuntime.shared
        let resolver = MusicAffinityEventResolver(store: graph.store, lookup: { uid in
            guard let id = try? await graph.index.lookup(providerUID: uid, kind: .recording) else { return nil }
            return id
        })
        let defaults = UserDefaults.standard
        let historyMirror = MusicHistoryMirrorBox()
        let floor = defaults.object(forKey: Self.floorKey) as? Date
        let store = MusicAffinityStore(floor: floor, saveFloor: { date in
            if let date { UserDefaults.standard.set(date, forKey: MusicRecommenderRuntime.floorKey) } else { UserDefaults.standard.removeObject(forKey: MusicRecommenderRuntime.floorKey) }
        }, source: {
            // Held back while the app is locked or a Kids profile is on: no history is read then.
            // The main actor only hands over the array (shared, not copied); the rows are converted off the main thread and only the new ones each time.
            let history: [PlayRecord] = await MainActor.run {
                let hub = MusicHub.shared
                return MusicRecommenderRuntime.learnable(hub.library.history, gated: hub.gated)
            }
            let plays = await historyMirror.plays(history)
            return await resolver.events(from: plays)
        })
        affinity = store
        recommender = MusicRecommender(store: graph.store, affinity: store)
        let cache = recommender.cache
        graph.onWipe { await store.wipe(); await cache.removeAll(); await historyMirror.reset() }
    }

    /// The plays the recommender may learn from: none while gated, and none from before a recommendations reset (read from the saved reset date, so a
    /// reset made before this rule existed counts too). Home, Radio and autoplay all take their affinity from here.
    static func learnable(_ history: [PlayRecord], gated: Bool, cutoff: Date? = MusicTasteReset.cutoff) -> [PlayRecord] {
        gated ? [] : MusicTasteReset.visible(history, cutoff: cutoff)
    }

    /// The Music settings reset button.
    func resetAffinity() async { await affinity.reset(); await recommender.cache.removeAll() }
    /// A play finished or a like changed: the next read rebuilds.
    func historyChanged() async { await affinity.invalidate() }
}
