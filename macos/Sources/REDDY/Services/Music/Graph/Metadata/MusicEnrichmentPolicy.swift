import Foundation

/// Why a metadata request was not made. The page works from what the graph already holds.
enum MusicEnrichmentSkip: String, Sendable, Equatable {
    case consentMissing, switchOff, kidsOrLocked, offline, filmLookupsOff, unconfigured
}

enum MusicEnrichmentDecision: Sendable, Equatable {
    case allowed
    case skipped(MusicEnrichmentSkip)
    var isAllowed: Bool { self == .allowed }
}

protocol MusicEnrichmentGating: Sendable {
    func decision(for source: MusicSourceID) -> MusicEnrichmentDecision
}

/// Gating before any network call (section 3.3): Music consent given, the per-source switch on, no Kids profile or app lock, the device online, and for
/// TMDB the person's own lookup switch (the artwork-matching one). Off means `.skipped`; nothing errors and nothing is asked.
struct MusicEnrichmentPolicy: MusicEnrichmentGating {
    var consentGiven: @Sendable () -> Bool
    var sourceOn: @Sendable (MusicSourceID) -> Bool
    var kidsOrLocked: @Sendable () -> Bool = { false }
    var offline: @Sendable () -> Bool = { false }
    /// The app's TMDB switch (the artwork-matching privacy switch); the gate refuses too, this only avoids building a request.
    var tmdbLookupsAllowed: @Sendable () -> Bool = { true }

    func decision(for source: MusicSourceID) -> MusicEnrichmentDecision {
        if kidsOrLocked() { return .skipped(.kidsOrLocked) }
        if !consentGiven() { return .skipped(.consentMissing) }
        if !sourceOn(source) { return .skipped(.switchOff) }
        if source == .tmdb, !tmdbLookupsAllowed() { return .skipped(.filmLookupsOff) }
        if offline() { return .skipped(.offline) }
        return .allowed
    }

    /// Everything on: for tests.
    static let open = MusicEnrichmentPolicy(consentGiven: { true }, sourceOn: { _ in true })
}

/// The per-source switches (Settings > Plugins & Sources > Metadata sources). Stored as one JSON map under `music.metadata.sources`; a source with no
/// entry takes its policy default (on, except Discogs). Every change is appended to the same change log the other sources use.
final class MusicMetadataSwitches: @unchecked Sendable {
    static let key = "music.metadata.sources"
    /// The sources with a switch, in the order Settings shows them.
    static let all: [MusicSourceID] = [.musicbrainz, .wikidata, .wikipedia, .imdb, .listenbrainz, .tmdb, .omdb, .discogs, .lastfm]
    /// Off until the person turns them on (Discogs, OMDb). Last.fm and OMDb also need a key, which the source checks itself.
    static let defaultOff: Set<MusicSourceID> = [.discogs, .omdb]

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func map() -> [String: Bool] {
        guard let d = defaults.data(forKey: Self.key), let m = try? JSONDecoder().decode([String: Bool].self, from: d) else { return [:] }
        return m
    }

    func isOn(_ source: MusicSourceID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return map()[source.rawValue] ?? !Self.defaultOff.contains(source)
    }

    func set(_ on: Bool, _ source: MusicSourceID, at: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        var m = map()
        guard (m[source.rawValue] ?? !Self.defaultOff.contains(source)) != on else { return }
        m[source.rawValue] = on
        if let d = try? JSONEncoder().encode(m) { defaults.set(d, forKey: Self.key) }
        let log = MusicRegistryChangeLog.load(defaults)
        MusicRegistryChangeLog.save(MusicRegistryChangeLog.appending(MusicRegistryChange(at: at, id: "metadata." + source.rawValue, on: on, reason: .switch), to: log), to: defaults)
    }

    /// Back to the defaults (the privacy wipe).
    func reset() { lock.lock(); defaults.removeObject(forKey: Self.key); lock.unlock() }
}
