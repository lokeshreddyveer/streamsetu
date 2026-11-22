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
        // A lock, a relock or a change of profile rewrites the widget in the same call, so a title that just became restricted is not left on the home screen until the next tick.
        c.parental.observeRestriction { [weak self] in self?.publishContinueNow(c) }
        c.observeProfileSwitch { [weak self] in self?.publishContinueNow(c) }
        publishContinueNow(c)          // before the first widget reload: what an earlier session left behind is replaced at launch
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
        let history = c.widgetHistory
        let entries = await Task.detached { ContinueWidgetFeed.entries(history: history) }.value
        write(entries)
    }

    /// The same, at once, on the calling thread: used when what may be shown has just changed.
    func publishContinueNow(_ c: AppContainer) { write(ContinueWidgetFeed.entries(history: c.widgetHistory)) }

    private func write(_ entries: [ContinueWidgetFeed.Entry]) {
        let items = entries.map { WidgetShared.Item(title: $0.title, subtitle: $0.subtitle, progress: $0.progress, link: $0.link) }
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
