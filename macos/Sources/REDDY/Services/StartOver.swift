import Foundation

/// "Start from the beginning" for a live channel: when the programme on now began a while ago and the provider keeps an archive for the channel,
/// the person can watch it from its start through catch-up.
enum StartOver {
    /// It began at least this long ago, or it is not worth offering.
    static let minimumElapsed: TimeInterval = 5 * 60
    /// Shorter programmes (bumpers, news flashes) are not offered.
    static let minimumLength: TimeInterval = 15 * 60
    /// How long the offer stays on screen after the channel opens.
    static let showFor: TimeInterval = 25

    static func canOffer(program: EPGProgram, archiveDays: Int, now: Date = Date()) -> Bool {
        guard archiveDays > 0, program.isLive(at: now), program.end.timeIntervalSince(program.start) >= minimumLength else { return false }
        let elapsed = now.timeIntervalSince(program.start)
        return elapsed >= minimumElapsed && elapsed <= Double(archiveDays) * 86400
    }
}
