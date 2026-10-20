import Foundation
import ActivityKit
import WidgetKit

/// Keeps the Continue Watching widget and the download Live Activity up to date. Everything it needs is read from the app; nothing leaves the device.
@MainActor
final class WidgetBridge {
    static let shared = WidgetBridge()
    private var loop: Task<Void, Never>?
    private var lastPublished: [WidgetShared.Item] = []

    func start(_ c: AppContainer) {
        loop?.cancel()
        loop = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                if tick % 15 == 0 { await self?.publishContinue(c) }
                await self?.updateActivity(c)
                tick += 1
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// Writes what the person left unfinished, for the widget.
    func publishContinue(_ c: AppContainer) async {
        let items: [WidgetShared.Item] = await Task.detached {
            let list = (try? c.history.continueWatching(limit: 6, sourceID: nil)) ?? []
            return list.compactMap { ci -> WidgetShared.Item? in
                let fraction = ci.progress.durationSeconds > 0 ? ci.progress.positionSeconds / ci.progress.durationSeconds : 0
                switch ci.content {
                case .movie(let m):
                    guard let link = DeepLink.link(movie: m.title) else { return nil }
                    return .init(title: m.title, subtitle: "Movie", progress: fraction, link: link.absoluteString)
                case .episode(let e, let s):
                    guard let link = DeepLink.link(series: s.title) else { return nil }
                    return .init(title: s.title, subtitle: "S\(e.seasonNumber) E\(e.episodeNumber) · \(e.title)", progress: fraction, link: link.absoluteString)
                }
            }
        }.value
        guard items != lastPublished else { return }
        lastPublished = items
        WidgetShared.save(items)
        WidgetCenter.shared.reloadTimelines(ofKind: "ContinueWatching")
    }

    /// Shows the download in progress on the lock screen and in the Dynamic Island; ends it when nothing is downloading.
    private func updateActivity(_ c: AppContainer) async {
        let active = c.downloads.records.filter { $0.state == .downloading }
        guard let current = active.first else {
            if running { running = false; await Self.endActivities() }
            return
        }
        let waiting = c.downloads.records.filter { $0.state == .queued }.count
        let state = DownloadActivityAttributes.ContentState(title: current.title, fraction: current.fraction, waiting: waiting)
        if running { await Self.updateActivities(state) }
        else if ActivityAuthorizationInfo().areActivitiesEnabled { running = Self.startActivity(state) }
    }

    private var running = false

    // The calls that touch an Activity are kept off the main actor so the (non-Sendable) Activity never crosses between actors.
    nonisolated private static func startActivity(_ state: DownloadActivityAttributes.ContentState) -> Bool {
        (try? Activity.request(attributes: DownloadActivityAttributes(started: Date()), content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(60)))) != nil
    }

    nonisolated private static func updateActivities(_ state: DownloadActivityAttributes.ContentState) async {
        for a in Activity<DownloadActivityAttributes>.activities { await a.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(60))) }
    }

    nonisolated private static func endActivities() async {
        for a in Activity<DownloadActivityAttributes>.activities { await a.end(nil, dismissalPolicy: .after(Date().addingTimeInterval(8))) }
    }
}
