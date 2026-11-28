import Foundation
import Observation

/// A named sound: tempo, pitch and reverb together.
struct MusicEffectPreset: Codable, Equatable, Identifiable, Sendable {
    var name: String
    var speed: Double
    var semitones: Int
    var reverb: MusicReverbSettings

    var id: String { name.lowercased() }
    var settings: MusicEffectSettings { MusicEffectSettings(speed: speed, semitones: semitones, reverb: reverb) }

    init(name: String, settings s: MusicEffectSettings) {
        self.name = name; speed = s.speed; semitones = s.semitones; reverb = s.reverb
    }

    /// A short line for a tooltip: tempo as 0.00x, pitch, and the room when reverb is on.
    var summary: String {
        var parts = [String(format: "%.2fx", speed), "pitch " + MusicEffectSettings.pitchLabel(semitones)]
        if reverb.enabled { parts.append(reverb.room.title.lowercased()) }
        return parts.joined(separator: ", ")
    }
}

struct MusicBuiltInEffectPreset: Identifiable, Sendable {
    var id: String
    var title: String
    var detail: String
    var settings: MusicEffectSettings
}

enum MusicEffectPresets {
    /// The five built-in sounds, with the exact values.
    static let builtIn: [MusicBuiltInEffectPreset] = [
        MusicBuiltInEffectPreset(id: "original", title: "Original", detail: "No tempo, pitch or reverb change.", settings: .original),
        MusicBuiltInEffectPreset(id: "slowed", title: "Slowed", detail: "Slower and lower with a hall around it, like a record played slow.",
                                 settings: MusicEffectSettings(speed: 0.85, semitones: -3,
                                                               reverb: MusicReverbSettings(enabled: true, preset: 4, wet: 40, decay: 1.8))),
        MusicBuiltInEffectPreset(id: "nightcore", title: "Nightcore", detail: "Faster and higher with a short plate. Gentler than the genre.",
                                 settings: MusicEffectSettings(speed: 1.2, semitones: 3,
                                                               reverb: MusicReverbSettings(enabled: true, preset: 6, wet: 15, decay: 1.2, preDelay: 20))),
        MusicBuiltInEffectPreset(id: "practice", title: "Practice", detail: "Slower at the same pitch, for playing along.",
                                 settings: MusicEffectSettings(speed: 0.75)),
        MusicBuiltInEffectPreset(id: "hall", title: "Hall", detail: "The normal song inside a large hall.",
                                 settings: MusicEffectSettings(reverb: MusicReverbSettings(enabled: true, preset: 5, wet: 25, decay: 3.2))),
    ]

    static let maxNameLength = 80

    /// Which chip is lit: the first built-in, then the first saved preset, whose sound equals the current one.
    static func activeChip(for s: MusicEffectSettings, saved: [MusicEffectPreset]) -> String? {
        if let b = builtIn.first(where: { $0.settings.sameSound(as: s) }) { return b.id }
        return saved.first { $0.settings.sameSound(as: s) }.map { "saved:" + $0.id }
    }

    static func cleanName(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t.count > maxNameLength ? nil : t
    }

    /// Reads a saved collection. Anything wrong rejects the whole file, so saving can never silently erase what is on disk: names are
    /// trimmed, non-empty, at most 80 characters and unique ignoring case; tempo 0.25...2 (older builds allowed 0.25, so it is raised to
    /// 0.5); pitch a whole number -12...12; reverb values in range with whole numbers where the field is whole.
    static func parse(_ data: Data) -> [MusicEffectPreset]? {
        guard let raw = try? JSONDecoder().decode([MusicEffectPreset].self, from: data) else { return nil }
        var seen = Set<String>()
        var out: [MusicEffectPreset] = []
        for var p in raw {
            guard let name = cleanName(p.name), seen.insert(name.lowercased()).inserted else { return nil }
            guard p.speed.isFinite, (0.25...2.0).contains(p.speed), MusicEffectSettings.semitoneRange.contains(p.semitones) else { return nil }
            let r = p.reverb
            guard [r.dry, r.wet, r.decay, r.preDelay, r.damping, r.reflections].allSatisfy(\.isFinite), r.isValid, r.integersAreWhole else { return nil }
            p.name = name
            p.speed = max(0.5, p.speed)
            out.append(p)
        }
        return out
    }
}

/// The saved presets. Stored as one JSON array in the music state folder; an unreadable file disables saving rather than being overwritten.
@MainActor @Observable
final class MusicEffectPresetStore {
    enum SaveOutcome: Equatable { case saved, replaced, needsReplace, nothingToSave, invalidName, unavailable }

    private(set) var presets: [MusicEffectPreset] = []
    /// Set when the file exists but could not be read. Saving stays off while it is set.
    private(set) var loadError: String?
    @ObservationIgnored private let file: URL

    init(directory: URL) {
        file = directory.appendingPathComponent("effect-presets.json")
        load()
    }

    var canSave: Bool { loadError == nil }

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        if let p = MusicEffectPresets.parse(data) { presets = p } else { loadError = "The saved presets file could not be read, so saving is turned off." }
    }

    /// Saves the current sound under a name. `storedTempo` is used instead of the settings' tempo (in a listening room the shown tempo is
    /// the room's 1.0 but the preset keeps its own). An existing name needs `replace: true`. A sound identical to a built-in or saved
    /// preset cannot be saved.
    @discardableResult
    func save(name: String, settings: MusicEffectSettings, storedTempo: Double? = nil, replace: Bool = false) -> SaveOutcome {
        guard canSave else { return .unavailable }
        guard let clean = MusicEffectPresets.cleanName(name) else { return .invalidName }
        var s = settings
        if let t = storedTempo { s.speed = t }
        guard s.isValid else { return .invalidName }
        let existing = presets.firstIndex { $0.name.lowercased() == clean.lowercased() }
        let others = presets.enumerated().filter { $0.offset != existing }.map(\.element)
        if MusicEffectPresets.builtIn.contains(where: { $0.settings.sameSound(as: s) }) || others.contains(where: { $0.settings.sameSound(as: s) }) {
            return .nothingToSave
        }
        if let i = existing {
            guard replace else { return .needsReplace }
            presets[i] = MusicEffectPreset(name: clean, settings: s)
            persist()
            return .replaced
        }
        presets.append(MusicEffectPreset(name: clean, settings: s))
        persist()
        return .saved
    }

    func delete(_ preset: MusicEffectPreset) {
        guard canSave else { return }
        presets.removeAll { $0.name.lowercased() == preset.name.lowercased() }
        persist()
    }

    func nameExists(_ name: String) -> Bool {
        guard let c = MusicEffectPresets.cleanName(name) else { return false }
        return presets.contains { $0.name.lowercased() == c.lowercased() }
    }

    /// The settings to apply for a preset: a copy, with tempo forced to 1 in a room. The saved preset itself is never touched.
    static func settings(for preset: MusicEffectPreset, inRoom: Bool) -> MusicEffectSettings {
        inRoom ? preset.settings.inRoom() : preset.settings
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
