import Testing
import Foundation

/// A release date that arrives as "1951-09-12" is read at midnight UTC. Showing that instant in the person's own time zone puts it on the previous day
/// anywhere west of Greenwich (the film About tab and header did). Any file that reads dates at UTC must show them with an explicit `timeZone:` (as
/// MusicSoundtrackHeaderSection does) or list the reason it is safe.
///
/// Count based like AlwaysOnAnimationGuardTests; `pending` holds real offenders still to fix and a lower count than listed fails too.
struct DateOnlyTimeZoneGuardTests {
    static let safe: [String: (Int, String)] = [:]

    static let pending: [String: (Int, String)] = [:]

    @Test func utcDatesAreNotShownInLocalTime() {
        let found = GuardScans.utcDatesShownInLocalTime()
        let all = Self.safe.merging(Self.pending) { a, b in (a.0 + b.0, a.1) }
        #expect(GuardScanner.overBudget(found, allowed: all).isEmpty, "A date read at UTC is formatted without timeZone:, so it shows a day early west of UTC: \(GuardScanner.overBudget(found, allowed: all))")
        #expect(GuardScanner.staleEntries(found, allowed: all).isEmpty, "Lower or remove these entries: \(GuardScanner.staleEntries(found, allowed: all))")
    }
}
