import Foundation
import AVFoundation
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Remembered choices, skip intro and go to time, split out of PlaybackCoordinator along its own MARK.
extension PlaybackCoordinator {
    // MARK: remembered choices, skip intro, go to time

    /// Whether audio, subtitles, speed and timing come back the next time the same title plays.
    var remembersPerTitle: Bool { get { itemMemory.enabled } set { itemMemory.enabled = newValue } }

    func remember() {
        guard !isPrivate, let id = current?.itemID else { return }          // a private play leaves no remembered choices
        let e = ItemMemory.Entry(audioLanguage: audioTracks.first(where: \.isSelected)?.language, subtitleLanguage: subtitleTracks.first(where: \.isSelected).map { $0.language ?? "" } ?? "off",
                                 rate: rate, audioDelay: audioDelay, subtitleDelay: subtitleDelay)
        memoryEntry = e
        itemMemory.save(e, for: id)
    }

    /// Where the opening of this episode ends, while it is still on screen; nil for anything else.
    var introEnd: TimeInterval? {
        guard !isLive, let series = currentEpisode?.1 else { return nil }
        return introSkip.target(seriesID: series.id, position: position)
    }

    func skipIntro() { if let end = introEnd { seek(to: end) } }

    /// Where the recap at the start of this episode ends, while it is on screen; nil for anything else.
    var recapEnd: TimeInterval? {
        guard !isLive, currentEpisode != nil else { return nil }
        return episodeMarks.recapEnd(chapters: chapters, position: position, duration: duration)
    }

    func skipRecap() { if let end = recapEnd { seek(to: end) } }

    /// True once the credits of this episode have started and there is still something to skip.
    var creditsShowing: Bool {
        guard !isLive, let series = currentEpisode?.1, let d = duration, let start = episodeMarks.creditsStart(seriesID: series.id, chapters: chapters, duration: d) else { return false }
        return position >= start && d - position > 3
    }

    /// Skipping the credits plays the next episode when there is one, and otherwise goes to the end.
    func skipCredits() {
        guard let series = currentEpisode?.1, let d = duration else { return }
        if episodeMarks.isCreditsSkip(from: position, to: d, duration: d) { episodeMarks.learn(seriesID: series.id, from: position, duration: d) }
        if queueAdvance?() == true { return }
        if upNext != nil { playNextEpisode() } else { seek(to: d) }
    }

    /// Jumps to a point in a movie or episode.
    func goTo(_ seconds: TimeInterval) { seek(to: seconds) }

    /// "1:23:45", "83:45" or "45" (seconds) as seconds; nil when it is not a time.
    nonisolated static func parseTime(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: ":").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1! }
    }

    func step(_ delta: Int) {
        guard !queue.isEmpty else { return }
        let i = currentChannel.flatMap { c in queue.firstIndex { $0.id == c.id } } ?? (delta > 0 ? -1 : 0)
        let next = queue[((i + delta) % queue.count + queue.count) % queue.count]
        play(channel: next, privately: isPrivate)
    }

    func endSession(outcome: String, error: String?) {
        defer { onSessionChange?() }
        if let item = announced {
            announced = nil
            let done = outcome == "ended" ? 100 : ((duration ?? 0) > 0 ? min(100, position / (duration ?? 1) * 100) : 0)
            onWatchEvent?(.stopped(item, progress: done))
        }
        if let id = sessionID { try? historyRepo.endSession(id: id, outcome: outcome, error: error); sessionID = nil }
    }

    func cancelWork() {
        startTask?.cancel(); recoveryTask?.cancel(); stableTask?.cancel(); watchdogTask?.cancel(); ticker?.cancel(); ticker = nil
        generation += 1
    }

    /// For diagnostics export.
    var diagnosticsSummary: String { "state=\(state) · \(metrics.summary) · engines=\(factory.available.map(\.rawValue).sorted())" }
}
