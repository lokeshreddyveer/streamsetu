import Testing
import Foundation
@testable import REDDY

/// A timeout written as a task group (`work` against `Task.sleep`, first answer wins) only cuts the work off when the work child ends as soon as it
/// is cancelled. A child that awaits an unstructured Task's `.value` (or a detached task) does not: cancelling the child leaves the inner task running,
/// and the group cannot return until every child is done, so the "timeout" waits as long as the work. This is how the catalogue matcher's budget and
/// the host lookup's patience ran past their limits. Use a race that resumes a continuation once (MusicStreamResolver.withDeadline) or make the
/// work itself cooperative.
///
/// Count based per file like AlwaysOnAnimationGuardTests: `safe` entries carry the reason they are fine, `pending` ones are real offenders still to fix.
struct TimeoutThatCannotCutOffGuardTests {
    static let safe: [String: (Int, String)] = [:]

    static let pending: [String: (Int, String)] = [
        "Playback/StartDiagnosis.swift": (1, "resolve(_:patience:) waits for getaddrinfo in a detached task from inside the group, so a host that never answers holds the call past its patience"),
    ]

    @Test func noTaskGroupChildWaitsOnAnUnstructuredTask() {
        let found = GuardScans.taskGroupChildrenAwaitingTasks()
        let all = Self.safe.merging(Self.pending) { a, b in (a.0 + b.0, a.1) }
        #expect(GuardScanner.overBudget(found, allowed: all).isEmpty,
                "A task-group child awaits a Task's value, so a timeout raced against it cannot cut it off: \(GuardScanner.overBudget(found, allowed: all))")
        #expect(GuardScanner.staleEntries(found, allowed: all).isEmpty, "Lower or remove these entries: \(GuardScanner.staleEntries(found, allowed: all))")
    }

    /// The behaviour behind the rule: a task group whose child awaits an unstructured task returns only when that task is done, however short the other
    /// child's sleep. The deadline helper the app uses returns at the deadline while the work is still running.
    @Test func theAppsDeadlineHelperReturnsWhileTheWorkIsStillRunning() async {
        let started = Date()
        let result: String? = try? await MusicStreamResolver.withDeadline(0.15) { () async throws -> String in
            try await Task.sleep(nanoseconds: 3_000_000_000)
            return "late"
        }
        #expect(result == nil)
        #expect(Date().timeIntervalSince(started) < 2.0)
    }

    @Test func theScannerFlagsTheBadShapeAndNotTheGoodOne() {
        let bad = "func f() async { await withTaskGroup(of: Int.self) { g in g.addTask { await t.value; return 1 }\n g.addTask { return 0 } } }"
        let good = "func f() async { await withTaskGroup(of: Int.self) { g in g.addTask { await work(); return 1 }\n g.addTask { return 0 } } }"
        func count(_ s: String) -> Int {
            let code = GuardScanner.scrub(s, blankStrings: true)
            let bytes = Array(code.utf8)
            var n = 0; var from = code.startIndex
            while let r = code.range(of: "addTask {", range: from..<code.endIndex) {
                let open = code.utf8.distance(from: code.utf8.startIndex, to: r.upperBound) - 1
                if let c = GuardScanner.matchingBrace(bytes, open: open) {
                    let body = String(decoding: bytes[open...c], as: UTF8.self)
                    if body.range(of: #"\bawait\b[^\n]*\.value\b"#, options: .regularExpression) != nil { n += 1 }
                }
                from = r.upperBound
            }
            return n
        }
        #expect(count(bad) == 1)
        #expect(count(good) == 0)
    }
}
