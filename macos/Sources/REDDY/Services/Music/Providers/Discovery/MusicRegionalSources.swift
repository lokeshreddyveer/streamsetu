import Foundation

/// A discovery source that can also be asked for one or more languages (JioSaavn's lists are per language, not per country).
/// A source that can list playlists made for a language (Deezer's editorial playlists for Hindi, Telugu and so on).
protocol MusicLanguagePlaylistSearch: Sendable {
    func languagePlaylists(_ language: MusicLanguage) async throws -> [MusicPlaylist]
}

protocol MusicLanguageDiscovery: Sendable {
    func featured(region: String, languages: [MusicLanguage]) async throws -> [MusicBrowseSection]
}

/// Which sources truly follow a country, decided in one place so Home, its labels and its tests agree. Every row here was checked live
/// against the public service with no key; a source that does not appear for a country does not follow it and is not presented as if it did.
enum MusicRegionalSources {
    /// JioSaavn lists Indian music; it is a regional source for India only (its per-language lists are used for a language anywhere).
    static let jioSaavnRegions: Set<String> = ["in"]

    /// YouTube Music's chart takes the country as an upper-case code. Any real country is asked; a country it has no chart for answers with nothing, which the
    /// page then says (the app keeps no list of the countries YouTube covers).
    static func youTubeChartsCountry(for region: String) -> String? {
        let r = region.lowercased()
        return r.count == 2 ? r.uppercased() : nil
    }

    /// True when the source gives a different answer for this country.
    static func followsRegion(providerID: String, region: String) -> Bool {
        let r = region.lowercased()
        guard !r.isEmpty else { return false }          // worldwide: no source follows a country
        switch providerID {
        case ITunesChartsDiscoveryProvider.id: return true
        case JioSaavnDiscoveryProvider.id: return jioSaavnRegions.contains(r)
        default: return false
        }
    }

    /// The languages JioSaavn is asked for: the person's own (only the ones it has lists for); for India with none, the languages the device is set to that it has lists for.
    /// With neither, none: the app does not pick languages for anyone.
    static func jioSaavnLanguages(region: String, wanted: [MusicLanguage], device: [String] = Locale.preferredLanguages) -> [MusicLanguage] {
        let usable = wanted.filter { $0.jioSaavnCode != nil }
        if !usable.isEmpty { return Array(usable.prefix(3)) }
        guard jioSaavnRegions.contains(region.lowercased()) else { return [] }
        let fromDevice = MusicLanguageNames.deviceLanguages(preferred: device).compactMap { MusicLanguage(stated: $0.english) }.filter { $0.jioSaavnCode != nil }
        MusicDebugLog.log("home", "JioSaavn languages for \(region): none from history, \(fromDevice.count) from the device")
        return Array(fromDevice.prefix(3))
    }

    /// The Apple, Deezer and JioSaavn lists are cut to a language by the writing system of each title; Latin titles cannot be told apart, so a
    /// Latin-script language filter does not cut anything.
    static func filter(_ tracks: [MusicTrack], to language: MusicLanguage?) -> [MusicTrack] {
        guard let language, language != .latin else { return tracks }
        return tracks.filter { MusicLanguageDetector.language(of: $0) == language }
    }

    /// Title of a regional shelf; it always names the country.
    static func topSongsTitle(region: String, language: MusicLanguage?) -> String {
        if region.isEmpty { return language.map { Localized.string("Top %@ songs worldwide", $0.displayName) } ?? Localized.string("Top songs worldwide") }
        let name = MusicDiscoveryRegion.name(region)
        if let language { return Localized.string("Top %1$@ songs in %2$@", language.displayName, name) }
        return Localized.string("Top songs in %@", name)
    }

    /// "Top charts in India", or "Top charts worldwide" when no country is chosen.
    static func chartsTitle(region: String) -> String {
        region.isEmpty ? Localized.string("Top charts worldwide") : Localized.string("Top charts in %@", MusicDiscoveryRegion.name(region))
    }

    static func newTitle(region: String, language: MusicLanguage?) -> String {
        if let language { return Localized.string("New in %@", language.displayName) }
        if region.isEmpty { return Localized.string("New worldwide") }
        return Localized.string("New in %@", MusicDiscoveryRegion.name(region))
    }
}
