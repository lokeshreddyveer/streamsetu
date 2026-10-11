import SwiftUI
import Observation

@MainActor @Observable
final class SeriesDetailViewModel {
    var detail: SeriesDetail?
    var progress: [String: WatchProgress] = [:]
    var selectedSeason = 1
    var loading = true
    var error: String?
    var resumeTarget: Episode?

    var episodesInSeason: [Episode] { detail?.episodes.filter { $0.seasonNumber == selectedSeason } ?? [] }

    func load(_ series: Series, _ c: AppContainer) async {
        loading = true
        do {
            let d = try await c.details.series(id: series.id)
            detail = d
            if !d.seasons.contains(where: { $0.number == selectedSeason }) { selectedSeason = d.seasons.first?.number ?? 1 }
            error = nil
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        loading = false
        reloadProgress(series, c)
        if let t = resumeTarget { selectedSeason = t.seasonNumber }
    }

    func reloadProgress(_ series: Series, _ c: AppContainer) {
        progress = Dictionary(((try? c.historyRepo.progress(forSeries: series.id)) ?? []).map { ($0.itemID, $0) }, uniquingKeysWith: { a, _ in a })
        resumeTarget = try? c.history.resumeTarget(seriesID: series.id)
    }

    func markWatched(_ e: Episode, _ series: Series, _ c: AppContainer, watched: Bool) {
        if watched { try? c.historyRepo.markWatched(itemID: e.id, kind: .episode, seriesID: series.id, duration: e.durationSeconds ?? 1) }
        else { try? c.historyRepo.clearProgress(itemID: e.id) }
        reloadProgress(series, c)
    }
}
