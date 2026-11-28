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

/// The app's own wording as a plain String, for text that is built in code (a duration, "34m left") and shown with `Text(verbatim:)` or a String.
/// It reads the same tables as `Text("literal")` does, in the language chosen in Settings (or the device's). Keys are the English text with
/// `%@` / `%d` placeholders. Without a table for the language it returns the English text, so tests and the Mac command line stay in English.
enum Localized {
    nonisolated static let language = Locked<AppLanguage>(.system)

    nonisolated static func string(_ key: String, _ args: CVarArg...) -> String {
        let format = table()?.localizedString(forKey: key, value: key, table: nil) ?? key
        return args.isEmpty ? format : String(format: format, locale: nil, arguments: args)
    }

    /// The plural form for a count in the language in use: English and Telugu use "one" only for 1; Hindi uses it for 0 and 1 (CLDR). Add a language here when it gets a table.
    nonisolated static func isOne(_ n: Int, code: String) -> Bool { code == "hi" ? (n == 0 || n == 1) : n == 1 }

    /// "1 title" / "5 titles" in the language in use. `one` and `other` are two full English keys with a single `%@` for the number
    /// ("%@ title", "%@ titles"); each has its own line in the Hindi and Telugu tables, so a language with other plural rules can word both.
    nonisolated static func plural(_ n: Int, one: String, other: String) -> String {
        var code = language.value.rawValue
        if code == "system" { code = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en" }
        return string(isOne(n, code: code) ? one : other, n.formatted())
    }

    /// The language code in use ("en", "hi", "te"), for keys of saved copies of text that was translated when it was fetched.
    nonisolated static var activeCode: String {
        let code = language.value.rawValue
        if code == "system" { return Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en" }
        return code
    }

    private nonisolated static func table() -> Bundle? {
        var code = language.value.rawValue
        if code == "system" { code = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en" }
        guard code == "hi" || code == "te", let path = Bundle.main.path(forResource: code, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }
}
