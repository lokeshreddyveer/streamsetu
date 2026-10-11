import Foundation

struct ResumePlaybackUseCase: Sendable {
    let history: HistoryService
    func continueWatching(limit: Int = 12) async throws -> [ContinueItem] {
        try await Task.detached { [history] in try history.continueWatching(limit: limit) }.value
    }
    func target(forSeries id: String) async throws -> Episode? {
        try await Task.detached { [history] in try history.resumeTarget(seriesID: id) }.value
    }
}
