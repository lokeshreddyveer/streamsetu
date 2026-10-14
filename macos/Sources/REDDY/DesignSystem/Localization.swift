import SwiftUI

extension String {
    /// A fixed piece of the app's own wording, looked up in the chosen language (Hindi and Telugu are provided; anything else stays as written).
    /// Used for text that is passed around as a String. Never use it for titles and names that come from a playlist.
    var loc: LocalizedStringKey { LocalizedStringKey(self) }
}

/// The language the app's own text is shown in. "system" follows the device; the others are the languages the app has text for.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, hi, te
    var id: String { rawValue }
    var label: String { switch self { case .system: "System"; case .en: "English"; case .hi: "हिन्दी"; case .te: "తెలుగు" } }
    /// nil leaves the environment alone, so the device language is used.
    var locale: Locale? { self == .system ? nil : Locale(identifier: rawValue) }
}
