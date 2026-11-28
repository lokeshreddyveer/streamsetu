import Foundation
import Observation

/// The recording a person picked for one song, remembered so the song always plays from it. Keyed by the track's uid.
struct MusicMatchOverride: Codable, Hashable, Sendable {
    var providerID: String
    var sourceID: String
    /// Shown in the sheet so the person can see what is chosen without asking a provider.
    var title: String
    var artist: String?
    var pageURL: String?
    /// Streams the candidate already carried. Signed links expire, so the resolver treats these as a hint and asks the provider again when stale.
    var streams: [MusicStream]?
    var chosenAt: Date
}

/// Per-song "play it from this recording" choices. One small JSON file in the library directory; nothing leaves the device.
@MainActor @Observable
final class MusicMatchOverrides {
    /// Candidates kept per provider so one chatty provider cannot bury the others.
    static let candidatesPerProvider = 8

    private(set) var entries: [String: MusicMatchOverride]
    @ObservationIgnored private let store: MusicJSONStore<[String: MusicMatchOverride]>

    init(directory: URL, debounce: Duration = .seconds(1)) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = MusicJSONStore<[String: MusicMatchOverride]>(url: directory.appendingPathComponent("match-overrides.json"), debounce: debounce)
        self.store = store
        self.entries = store.load() ?? [:]
    }

    /// What the resolver needs: which provider and which of its recordings to use for this song, or nil for automatic matching.
    func override(for track: MusicTrack) -> (providerID: String, sourceID: String)? {
        guard let e = entries[track.uid] else { return nil }
        return (e.providerID, e.sourceID)
    }

    func entry(for track: MusicTrack) -> MusicMatchOverride? { entries[track.uid] }
    func streamsHint(for track: MusicTrack) -> [MusicStream] { entries[track.uid]?.streams ?? [] }
    func pageURL(for track: MusicTrack) -> String? { entries[track.uid]?.pageURL }
    func hasOverride(for track: MusicTrack) -> Bool { entries[track.uid] != nil }

    func choose(_ source: MusicAudioSource, for track: MusicTrack, now: Date = Date()) {
        entries[track.uid] = MusicMatchOverride(providerID: source.providerID, sourceID: source.id, title: source.title, artist: source.artist,
                                                pageURL: source.externalURL, streams: source.streams, chosenAt: now)
        store.save(entries)
    }

    func reset(for track: MusicTrack) {
        guard entries[track.uid] != nil else { return }
        entries[track.uid] = nil
        store.save(entries)
    }

    func resetAll() { entries = [:]; store.delete() }
    func flush() { store.flush() }

    /// Candidate recordings from every enabled audio provider, best first. A provider that fails or finds nothing is skipped.
    func candidates(for track: MusicTrack, registry: MusicRegistry) async -> [MusicAudioSource] {
        let providers = registry.audio
        let found = await withTaskGroup(of: [MusicAudioSource].self, returning: [[MusicAudioSource]].self) { group in
            for p in providers {
                group.addTask {
                    // A source that offers alternatives only on request (SoundCloud) is asked that way, not as a matcher.
                    if let alt = p as? any MusicAlternativeOffering { return (try? await alt.alternatives(for: track)) ?? [] }
                    return (try? await p.sources(for: track)) ?? []
                }
            }
            var all: [[MusicAudioSource]] = []
            for await part in group { all.append(part) }
            return all
        }
        return Self.rank(found, for: track)
    }

    /// Scores, drops duplicates, keeps the best few per provider and sorts best first. Pure, so it is tested without providers.
    static func rank(_ lists: [[MusicAudioSource]], for track: MusicTrack) -> [MusicAudioSource] {
        var seen = Set<String>()
        var scored: [(MusicAudioSource, Float)] = []
        for list in lists {
            let top = list
                .filter { seen.insert($0.uid).inserted }
                .map { ($0, MusicStreamResolver.score(track: track, candidate: $0)) }
                .sorted { $0.1 > $1.1 }
                .prefix(candidatesPerProvider)
            scored.append(contentsOf: top)
        }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }
}
