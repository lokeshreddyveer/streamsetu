import Foundation
import os

/// Read-only shelves for Home that need no account and no key: public charts and trending lists. Each one is a metadata provider that only
/// answers `featured()` (and the detail calls its own items need). Items carry no audio; the normal resolver finds it when one is played.
enum MusicDiscoveryBuiltIns {
    @MainActor static func register(into registry: MusicRegistry) {
        registry.register(DeezerDiscoveryProvider())
        registry.register(ITunesChartsDiscoveryProvider())
        registry.register(AudiusTrendingDiscoveryProvider())
        registry.register(SoundCloudDiscoveryProvider())
        registry.register(ListenBrainzDiscoveryProvider())
        registry.register(JioSaavnDiscoveryProvider())
    }
}

/// A discovery source whose lists depend on a country.
protocol MusicRegionalDiscovery: Sendable {
    func featured(region: String) async throws -> [MusicBrowseSection]
}

enum MusicDiscoveryRegion {
    static let defaultsKey = "music.home.region"

    /// "No country": the worldwide view. It is the first run's choice, and the one value that is not a country code.
    static let worldwide = ""
    static func isWorldwide(_ code: String) -> Bool { code.isEmpty }

    /// Every country the system knows, two-letter codes in lower case, named in the person's language and sorted by name. Nothing here is a list kept by the app;
    /// whether a source has a chart for a country is learned by asking it, and a country without one says so.
    /// The names follow the app's language (`Localized.activeCode`), not the system's, and are made again when it changes.
    static var supported: [(code: String, name: String)] {
        let language = Localized.activeCode
        if let hit = cache.withLock({ $0.language == language ? $0.list : nil }) { return hit }
        let locale = Locale(identifier: language)
        let list = Locale.Region.isoRegions.compactMap { r -> (String, String)? in
            let id = r.identifier
            guard id.count == 2, id.allSatisfy({ $0.isLetter && $0.isASCII }), let name = locale.localizedString(forRegionCode: id), name.lowercased() != id.lowercased() else { return nil }
            return (id.lowercased(), name)
        }.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
        cache.withLock { $0 = (language, list) }
        return list
    }
    private static let cache = OSAllocatedUnfairLock<(language: String, list: [(code: String, name: String)])>(initialState: ("", []))

    /// The system region when it is a country (used for searches, which need a store; never shown as a chart country).
    static func systemDefault(locale: Locale = .current) -> String {
        let code = (locale.region?.identifier ?? "").lowercased()
        return supported.contains { $0.code == code } ? code : "us"
    }

    /// The saved country, or worldwide when none was ever chosen.
    static func current(defaults: UserDefaults = .standard, locale: Locale = .current) -> String {
        if let c = defaults.string(forKey: defaultsKey), c.isEmpty || supported.contains(where: { $0.code == c }) { return c }
        return worldwide
    }

    static func name(_ code: String) -> String {
        if code.isEmpty { return Localized.string("Worldwide") }
        return supported.first { $0.code == code }?.name ?? Locale(identifier: Localized.activeCode).localizedString(forRegionCode: code) ?? code.uppercased()
    }
}

extension MusicProviderInfo {
    static func discovery(id: String, name: String, summary: String, host: String) -> MusicProviderInfo {
        MusicProviderInfo(id: id, name: name, summary: summary,
                          privacyNote: "Asks \(host) for its public lists when Home opens. No account, no search words and no device id are sent.")
    }
}
