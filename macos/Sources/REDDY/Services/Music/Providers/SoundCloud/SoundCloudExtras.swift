import Foundation

/// What the app keeps about SoundCloud tracks in memory for this run: the full track reply (its audio addresses and permission flags are fetched
/// fresh, never saved to disk), comments for chapters, and waveform samples. Stream addresses are never stored anywhere: a restored queue asks again.
actor SoundCloudExtras {
    static let shared = SoundCloudExtras()
    /// A full track reply is reused for this long (its signed addresses are short lived).
    static let freshFor: TimeInterval = 300
    private static let limit = 200

    private var tracks: [String: (track: SCTrack, at: Date)] = [:]
    private var waves: [String: [Float]] = [:]
    private var chapterMemo: [String: [SoundCloudChapter]] = [:]
    private let client: SoundCloudClient
    init(client: SoundCloudClient = .shared) { self.client = client }

    func remember(_ t: SCTrack) {
        guard !t.isStub else { return }
        if tracks.count >= Self.limit { tracks.removeAll(keepingCapacity: true) }
        tracks[t.id] = (t, Date())
    }

    /// The full track, fetched when it is not held fresh.
    func track(id: String, forceFresh: Bool = false) async throws -> SCTrack {
        if !forceFresh, let c = tracks[id], Date().timeIntervalSince(c.at) < Self.freshFor { return c.track }
        let data = try await client.data(path: "tracks/\(id)")
        guard let t = SoundCloudJSON.track(SoundCloudJSON.object(data)) else { throw MusicError.notFound }
        remember(t)
        SoundCloudAvailabilityBook.shared.note(trackID: t.id, SoundCloudAvailability.of(t))
        return t
    }

    func forget(id: String) { tracks[id] = nil }

    // MARK: chapters

    /// Chapters of a long track: from the description when it carries a tracklist, otherwise from the uploader's timestamped comments.
    func chapters(trackID: String) async -> [SoundCloudChapter] {
        if let memo = chapterMemo[trackID] { return memo }
        guard let t = try? await track(id: trackID) else { return [] }
        let duration = Double(t.durationMs) / 1000
        var found = SoundCloudChapters.parse(description: t.about ?? "", duration: duration)
        if found.isEmpty, (t.commentCount ?? 0) >= SoundCloudChapters.minimumCount {
            if let data = try? await client.data(path: "tracks/\(trackID)/comments", query: ["limit": "200", "threads": "0"]) {
                let comments = SoundCloudJSON.rows(SoundCloudJSON.any(data)).compactMap(SoundCloudJSON.comment)
                    .filter { $0.userID == nil || $0.userID == t.user?.id }
                found = SoundCloudChapters.parse(comments: comments, duration: duration)
            }
        }
        let result = found
        MusicDebugLog.log("soundcloud", "chapters for track \(trackID): \(result.count)")
        if chapterMemo.count > 50 { chapterMemo.removeAll() }
        chapterMemo[trackID] = result
        return result
    }

    // MARK: waveform

    /// Amplitude samples (0...1) of a track's waveform, or nil when SoundCloud gives none.
    func waveform(trackID: String) async -> [Float]? {
        if let w = waves[trackID] { return w.isEmpty ? nil : w }
        guard let t = try? await track(id: trackID), let raw = t.waveformURL, let url = URL(string: raw), SoundCloudWaveform.isTrusted(url) else {
            waves[trackID] = []
            MusicDebugLog.log("soundcloud", "no waveform for track \(trackID)")
            return nil
        }
        do {
            let data = try await client.http.get(url, headers: ["User-Agent": SoundCloudClientID.browserAgent])
            let samples = SoundCloudWaveform.samples(from: data)
            if waves.count > 50 { waves.removeAll() }
            waves[trackID] = samples
            if samples.isEmpty { MusicDebugLog.log("soundcloud", "waveform for track \(trackID) was empty") }
            return samples.isEmpty ? nil : samples
        } catch {
            MusicDebugLog.log("soundcloud", "waveform could not be loaded for track \(trackID)")
            return nil
        }
    }
}
