import Foundation
import QuartzCore

/// Judges the opening's own frames and says when it must give way to the app. A pure value, so it is tested without a screen.
///
/// The opening is decoration: it may never be the reason the app cannot be used. It trips when drawing a frame is slow (the mean draw
/// time of the last few frames) or when frames arrive far too rarely (the main thread, or the GPU, is not keeping up).
struct OpeningWatchdog {
    /// Frames ignored at the start (the first draws warm caches).
    var warmup = 2
    var window = 4
    /// Frame times are judged over a longer stretch: a single stall while the app builds underneath (a database read, a hub starting) skips a few frames of a time-driven
    /// story and is not a reason to cut it. Only frames that keep arriving far too rarely over this many are.
    var intervalWindow = 24
    var maxMeanDrawMs = 12.0
    var maxMeanIntervalMs = 50.0
    private(set) var seen = 0
    private var draws: [Double] = []
    private var times: [Double] = []
    private(set) var tripped: String?

    /// Records one drawn frame (its draw time, and the clock in seconds). Returns the reason when it trips (once).
    @discardableResult
    mutating func record(drawMs: Double, at t: Double) -> String? {
        guard tripped == nil else { return nil }
        seen += 1
        guard seen > warmup else { return nil }
        draws.append(drawMs); times.append(t)
        if draws.count > window { draws.removeFirst() }
        if times.count > intervalWindow { times.removeFirst() }
        if draws.count == window {
            let mean = draws.reduce(0, +) / Double(window)
            if mean > maxMeanDrawMs { tripped = "slow draw: \(Int(mean)) ms per frame"; return tripped }
        }
        if times.count == intervalWindow {
            let interval = (times.last! - times.first!) / Double(intervalWindow - 1) * 1000
            if interval > maxMeanIntervalMs { tripped = "slow frames: \(Int(interval)) ms apart"; return tripped }
        }
        return nil
    }

    /// The story has outlasted its length by more than a second without the app being revealed.
    static func overran(elapsedMs: Double, holdMs: Int) -> Bool { elapsedMs > Double(holdMs) + 1000 }
}

/// Times the opening's frames for the watchdog. A reference, so the drawing closure can feed it without changing any view state.
final class OpeningFrameMonitor: @unchecked Sendable {
    private var watchdog = OpeningWatchdog()
    private let lock = NSLock()
    /// Records a frame; the first time the watchdog trips, `onTrip` is called on the main queue.
    func frame(drawMs: Double, onTrip: @escaping @MainActor (String) -> Void) {
        lock.lock()
        let reason = watchdog.record(drawMs: drawMs, at: CACurrentMediaTime())
        lock.unlock()
        if let reason { DispatchQueue.main.async { MainActor.assumeIsolated { onTrip(reason) } } }
    }
}
