import SwiftUI
import Observation

// What the Radio page shows besides the saved stations: "Made for you" and "Based on your region". Both are computed off the main thread from a
// trigger value (the country and the revisions of the person's history, likes and follows) and kept in state, so a track change never rebuilds
// the page (RD-1). The country's lists are fetched once per country from the sources that follow it.

@MainActor @Observable
final class MusicRadioModel {
    /// Changes when the page has to be worked out again.
    struct Trigger: Hashable, Sendable {
        var region: String
        var history: Int
        var liked: Int
        var followed: Int
    }

    private(set) var derived = RadioDerived.Result()
    private(set) var loadingRegion = false
    @ObservationIgnored private var chartSections: [MusicBrowseSection] = []
    @ObservationIgnored private var chartsFor: String?

    static func trigger(hub: MusicHub, region: String) -> Trigger {
        Trigger(region: region, history: hub.library.historyRevision, liked: hub.library.likedRevision, followed: hub.library.followedRevision)
    }

    /// Works the sections out. Cancelled by SwiftUI when the trigger changes, so only the newest answer lands.
    func refresh(hub: MusicHub, trigger: Trigger) async {
        // A burst of plays makes one rebuild.
        try? await Task.sleep(for: .milliseconds(350))
        if Task.isCancelled { return }
        if chartsFor != trigger.region { await loadCharts(hub: hub, region: trigger.region) }
        if Task.isCancelled { return }
        let input = RadioDerived.Input(history: hub.library.history, liked: hub.library.liked, followed: hub.library.followedArtists,
                                       chartSections: chartSections, region: trigger.region)
        let result = await Task.detached(priority: .utility) { RadioDerived.build(input) }.value
        if Task.isCancelled { return }
        derived = result
        MusicDebugLog.log("radio", "page built: daily=\(result.daily != nil) artists=\(result.artists.count) genres=\(result.genres.count) languages=\(result.languages.count) region=\(result.regional.count)")
    }

    /// The lists the sources return for the country; the names of the stations come from these answers.
    private func loadCharts(hub: MusicHub, region: String) async {
        chartSections = []; chartsFor = region
        guard !region.isEmpty else { return }
        loadingRegion = true
        defer { loadingRegion = false }
        let languages = MusicRadioStations.historyLanguages(liked: hub.library.liked, history: hub.library.history)
        var found: [MusicBrowseSection] = []
        for p in hub.registry.discovery where MusicRegionalSources.followsRegion(providerID: p.id, region: region) {
            if Task.isCancelled { chartsFor = nil; return }
            var sections: [MusicBrowseSection] = []
            if let j = p as? any MusicLanguageDiscovery, !languages.isEmpty {
                sections = (try? await MusicStreamResolver.withDeadline(MusicHomeLoaders.sourceDeadline) { try await j.featured(region: region, languages: Array(languages.prefix(3))) }) ?? []
            } else if let r = p as? any MusicRegionalDiscovery {
                sections = (try? await MusicStreamResolver.withDeadline(MusicHomeLoaders.sourceDeadline) { try await r.featured(region: region) }) ?? []
            }
            found += sections.filter { $0.scope.countsAsRegional(for: region, sourceFollowsRegion: true) }
        }
        if Task.isCancelled { chartsFor = nil; return }
        chartSections = found
        let count = found.count
        MusicDebugLog.log("radio", "region lists for \(region): \(count) sections")
    }
}
