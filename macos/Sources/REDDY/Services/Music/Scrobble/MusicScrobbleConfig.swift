import Foundation
import Observation

/// Everything the person can tune about scrobbling, saved as one JSON value. Unreadable or missing data falls back to the defaults.
struct MusicScrobbleConfig: Codable, Equatable, Sendable {
    static let floorSeconds = 30
    static let defaultPercent = 50
    static let defaultMinutes = 4

    var percent = MusicScrobbleConfig.defaultPercent
    /// 0 means no time cap.
    var minutes = MusicScrobbleConfig.defaultMinutes
    var nowPlaying = true
    var clean = ScrobbleCleanSettings()
    /// A service that is missing here is on; the person can switch one off without signing out.
    var serviceEnabled: [String: Bool] = [:]

    init() {}

    enum CodingKeys: String, CodingKey { case percent, minutes, nowPlaying, clean, serviceEnabled }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        percent = try c.decodeIfPresent(Int.self, forKey: .percent) ?? Self.defaultPercent
        minutes = try c.decodeIfPresent(Int.self, forKey: .minutes) ?? Self.defaultMinutes
        nowPlaying = try c.decodeIfPresent(Bool.self, forKey: .nowPlaying) ?? true
        clean = try c.decodeIfPresent(ScrobbleCleanSettings.self, forKey: .clean) ?? ScrobbleCleanSettings()
        serviceEnabled = try c.decodeIfPresent([String: Bool].self, forKey: .serviceEnabled) ?? [:]
    }

    var clampedPercent: Int { min(100, max(1, percent)) }
    var clampedMinutes: Int { min(60, max(0, minutes)) }
    func isServiceEnabled(_ id: String) -> Bool { serviceEnabled[id] ?? true }

    static func decode(_ data: Data?) -> MusicScrobbleConfig {
        guard let data, let c = try? JSONDecoder().decode(MusicScrobbleConfig.self, from: data) else { return MusicScrobbleConfig() }
        return c
    }
}

/// When a play counts.
enum ScrobbleThreshold {
    /// The stricter rule: half the track or 180 s, whichever is less (never under 30 s). Used when it is stricter than the configured rule.
    static let strictCapSeconds = 180.0

    /// Seconds of ACCUMULATED PLAY TIME at which the track scrobbles, or nil when it never will (known length under 30 s, or no length and no time cap).
    /// Two rules are combined and the stricter (larger) one wins: the configured rule (percent of the length, capped at the minutes setting, default
    /// 50 % / 4 min) and the 50 % / 180 s rule. The second only applies while the percent setting is at 50 or more, so a person who lowers the
    /// percent on purpose still gets what they asked for. Nothing counts before 30 s.
    static func firePoint(durationSeconds: Double?, config: MusicScrobbleConfig) -> Double? {
        let floor = Double(MusicScrobbleConfig.floorSeconds)
        let cap = config.clampedMinutes > 0 ? Double(config.clampedMinutes * 60) : nil
        let strict = config.clampedPercent >= 50
        if let d = durationSeconds, d > 0 {
            guard d >= floor else { return nil }
            let byPercent = d * Double(config.clampedPercent) / 100
            let configured = max(floor, cap.map { min(byPercent, $0) } ?? byPercent)
            return strict ? max(configured, max(floor, min(d * 0.5, strictCapSeconds))) : configured
        }
        guard let cap else { return nil }
        let configured = max(floor, cap)
        return strict ? max(configured, strictCapSeconds) : configured
    }

    static func isTooShort(durationSeconds: Double?) -> Bool {
        guard let d = durationSeconds, d > 0 else { return false }
        return d < Double(MusicScrobbleConfig.floorSeconds)
    }

    static func clock(_ seconds: Double) -> String { MusicTime.clock(seconds.rounded()) }
}

/// Saves the config 250 ms after the last change; the scrobbler reads the new value at once.
@MainActor @Observable
final class MusicScrobbleConfigStore {
    static let defaultsKey = "music.scrobble.config"

    var config: MusicScrobbleConfig { didSet { if config != oldValue { scheduleSave() } } }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        config = MusicScrobbleConfig.decode(defaults.data(forKey: Self.defaultsKey))
    }

    func flush() {
        saveTask?.cancel(); saveTask = nil
        if let d = try? JSONEncoder().encode(config) { defaults.set(d, forKey: Self.defaultsKey) }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
}

// MARK: preview

/// One connected service and what it will receive.
struct ScrobbleServiceState: Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var connected: Bool
    var enabled: Bool
    var isActive: Bool { connected && enabled }
}

/// `positionSeconds` is the accumulated play time so far, which is what the scrobble point is measured against.
struct ScrobbleLiveState: Sendable, Equatable { var positionSeconds: Double; var durationSeconds: Double? }

struct ScrobbleServicePreview: Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    /// What goes out for this service; nil when nothing is sent.
    var artist: String?; var title: String?; var album: String?
}

struct ScrobblePreview: Sendable, Equatable {
    var original: ScrobbleTrackInfo
    var cleaned: CleanedTrack
    var services: [ScrobbleServicePreview]
    var firePointSeconds: Double?
    var statusLine: String
    /// Chips for what changed: "Your edit", "Title split", "Rule N" (1-based).
    var chips: [String]
}

enum ScrobblePreviewBuilder {
    static func build(info: ScrobbleTrackInfo, config: MusicScrobbleConfig, masterOn: Bool, services: [ScrobbleServiceState],
                      live: ScrobbleLiveState? = nil) -> ScrobblePreview {
        let cleaned = MusicTrackCleaner.clean(info, config.clean)
        let active = services.filter(\.isActive)
        let duration = live?.durationSeconds ?? (info.durationMs > 0 ? Double(info.durationMs) / 1000 : nil)
        let fire = ScrobbleThreshold.firePoint(durationSeconds: duration, config: config)

        let status: String
        if active.isEmpty { status = "No scrobbling service is connected, so nothing is sent." }
        else if !masterOn { status = "Scrobbling is off." }
        else if cleaned.skip == .edit { status = "Your edit turns this track off." }
        else if cleaned.skip == .incomplete { status = "Nothing is sent: no title or artist is left." }
        else if live != nil, ScrobbleThreshold.isTooShort(durationSeconds: duration) { status = "Too short to scrobble." }
        else if let fire {
            if let live, live.positionSeconds >= fire { status = "Scrobbled at \(ScrobbleThreshold.clock(fire))." }
            else { status = "Scrobbles at \(ScrobbleThreshold.clock(fire))." }
        } else { status = "Too short to scrobble." }

        var chips: [String] = []
        if cleaned.editIndex != nil { chips.append("Your edit") }
        if cleaned.splitFired { chips.append("Title split") }
        chips += cleaned.rulesApplied.map { "Rule \($0 + 1)" }

        let sends = cleaned.skip == nil && masterOn
        let previews = active.map { s in
            ScrobbleServicePreview(id: s.id, name: s.name, artist: sends ? cleaned.artist : nil, title: sends ? cleaned.title : nil,
                                   album: sends && !cleaned.album.isEmpty ? cleaned.album : nil)
        }
        return ScrobblePreview(original: info, cleaned: cleaned, services: previews, firePointSeconds: fire, statusLine: status, chips: chips)
    }

    /// Shown when nothing is playing and the person has not picked a track.
    static let sample = ScrobbleTrackInfo(uid: "sample", title: "Nova Sky - Higher Ground (Official Video)", artists: ["NovaSkyVEVO"], album: "", isVideo: true)
}
