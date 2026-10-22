import Foundation

/// What a setting does to what is already happening when it changes. The Settings screens and the assistant both go through here, so an effect is neither missed nor applied twice.
struct SettingApplyResult: Equatable, Sendable {
    /// The value now stored, in words.
    var now: String
    /// Whether the change reached a stream that is playing right now.
    var reachedPlayback: Bool
    /// What was done, or why it waits for the next stream.
    var note: String?
}

extension AppContainer {
    /// Settings whose change reaches what is playing. Everything else is stored and read when the next stream starts (the Settings screens say "from the next stream you start").
    @MainActor private func effect(for id: String) -> (() -> Void)? {
        switch id {
        case "subtitleSize", "subtitleBackground", "subtitleColor", "subtitlePosition", "subtitleOutline": return { [playback] in playback.applySubtitleStyle() }
        case "audioProcessing": return { [playback, settings] in playback.setAudioProcessing(settings.audioProcessing) }
        default: return nil
        }
    }

    /// Runs the effect of a setting that has just been stored. Called by the Settings screens when a control changes, and by `applySetting`. The same value is never applied twice in a row.
    @MainActor @discardableResult func settingChanged(_ id: String) -> SettingApplyResult? {
        guard let entry = AppSettingsCatalog.find(id), let value = entry.read?(settings) else { return nil }
        if appliedSettingValues[id] == value { return SettingApplyResult(now: value, reachedPlayback: false, note: nil) }
        appliedSettingValues[id] = value
        guard let run = effect(for: id) else { return SettingApplyResult(now: value, reachedPlayback: false, note: "It applies from the next stream you start.") }
        run()
        let playing = playback.current != nil
        return SettingApplyResult(now: value, reachedPlayback: playing, note: playing ? "It is applied to what is playing now." : nil)
    }

    /// Stores a catalogued setting and applies its effect: the one operation behind the assistant's setting changes.
    @MainActor func applySetting(id: String, value: String) -> SettingApplyResult? {
        guard let entry = AppSettingsCatalog.find(id), let write = entry.write, entry.accepts(value), write(settings, value) else { return nil }
        // the value is new on purpose: the effect must run even if the screen last saw the same text
        appliedSettingValues[id] = nil
        return settingChanged(id)
    }
}
