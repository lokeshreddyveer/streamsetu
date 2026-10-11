import Foundation

/// "Stop playback after…": when it ends, and how the volume fades out before it does. Pure, so the timing rules are testable.
struct SleepTimer: Equatable, Sendable {
    static let fadeSeconds: TimeInterval = 10
    static let presets: [Int] = [15, 30, 45, 60, 90, 120]

    let endsAt: Date

    init(minutes: Int, from now: Date = Date()) { endsAt = now.addingTimeInterval(TimeInterval(max(1, min(600, minutes))) * 60) }
    init(until date: Date) { endsAt = date }

    func remaining(at now: Date = Date()) -> TimeInterval { max(0, endsAt.timeIntervalSince(now)) }
    func hasEnded(at now: Date = Date()) -> Bool { now >= endsAt }

    /// 1 until the last `fadeSeconds`, then falling smoothly to 0 at the end.
    func volumeFactor(at now: Date = Date()) -> Double {
        let left = remaining(at: now)
        guard left < Self.fadeSeconds else { return 1 }
        return max(0, left / Self.fadeSeconds)
    }

    /// "42 min", "9 min", "45 s".
    static func label(forRemaining seconds: TimeInterval) -> String {
        seconds >= 90 ? "\(Int((seconds / 60).rounded(.up))) min" : "\(Int(seconds.rounded(.up))) s"
    }
}
