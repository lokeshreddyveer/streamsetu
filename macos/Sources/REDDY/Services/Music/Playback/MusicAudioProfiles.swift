import Foundation
import Observation

// The person's own equalizer presets, and the sound they like on each output (headphones, speakers). Both are plain data kept on this device.

struct MusicCustomPreset: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var settings: MusicEqualizerSettings
}

enum MusicCustomPresetRules {
    static let maxPresets = 30
    static let nameLimit = 40

    static func cleanName(_ raw: String) -> String { String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(nameLimit)) }

    /// Saves `settings` under `name`: the same name (ignoring case) replaces the earlier preset, a new name is added at the front, the list is capped.
    static func saving(_ settings: MusicEqualizerSettings, as name: String, into list: [MusicCustomPreset]) -> [MusicCustomPreset] {
        let n = cleanName(name)
        guard !n.isEmpty else { return list }
        var s = settings
        s.enabled = true
        var out = list
        if let i = out.firstIndex(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) { out[i].settings = s; return out }
        out.insert(MusicCustomPreset(name: n, settings: s), at: 0)
        return Array(out.prefix(maxPresets))
    }
}

@MainActor @Observable
final class MusicCustomPresets {
    static let shared = MusicCustomPresets()
    private static let key = "music.eq.customPresets"
    private(set) var list: [MusicCustomPreset]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let d = defaults.data(forKey: Self.key), let l = try? JSONDecoder().decode([MusicCustomPreset].self, from: d) { list = l.filter { $0.settings.isValid } } else { list = [] }
    }

    func save(_ s: MusicEqualizerSettings, as name: String) { list = MusicCustomPresetRules.saving(s, as: name, into: list); persist() }
    func delete(_ id: UUID) { list.removeAll { $0.id == id }; persist() }
    private func persist() { if let d = try? JSONEncoder().encode(list) { defaults.set(d, forKey: Self.key) } }
}

/// The equalizer, balance and mono the person set for each output. When "remember per output" is on, plugging in other headphones brings their sound back.
@MainActor @Observable
final class MusicDeviceAudioProfiles {
    static let shared = MusicDeviceAudioProfiles()
    private static let key = "music.eq.deviceProfiles"
    private static let flag = "music.eq.rememberPerDevice"
    private(set) var profiles: [String: MusicEqualizerSettings]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let d = defaults.data(forKey: Self.key), let p = try? JSONDecoder().decode([String: MusicEqualizerSettings].self, from: d) { profiles = p.filter { $0.value.isValid } } else { profiles = [:] }
    }

    var remembers: Bool {
        get { defaults.bool(forKey: Self.flag) }
        set { defaults.set(newValue, forKey: Self.flag) }
    }

    func profile(for uid: String?) -> MusicEqualizerSettings? { uid.flatMap { profiles[$0] } }

    func store(_ s: MusicEqualizerSettings, for uid: String?) {
        guard remembers, let uid else { return }
        profiles[uid] = s
        if let d = try? JSONEncoder().encode(profiles) { defaults.set(d, forKey: Self.key) }
    }

    /// The settings to use after the output changed from `old` to `new`: the new output's own, or what was playing when there is none saved.
    nonisolated static func settings(afterChangingTo new: String?, current: MusicEqualizerSettings, saved: [String: MusicEqualizerSettings]) -> MusicEqualizerSettings {
        new.flatMap { saved[$0] } ?? current
    }
}
