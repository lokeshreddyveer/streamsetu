import Testing
import Foundation
@testable import REDDY

@Suite("A returning Search page resumes a search that was cut off") struct SearchResumeTests {
    @Test func onlyAnInterruptedSearchWithNothingToShowIsRunAgain() {
        typealias M = MusicSearchModel
        // words typed and committed, the load was cancelled (state cleared), no results: run it again
        #expect(M.needsResume(trimmed: "shreya", committed: "shreya", state: nil, hasResults: false))
        // nothing typed
        #expect(!M.needsResume(trimmed: "", committed: "", state: nil, hasResults: false))
        // the person is typing new words: suggestions show, nothing is resumed
        #expect(!M.needsResume(trimmed: "shreya g", committed: "shreya", state: nil, hasResults: false))
        // results are already on the page, or a load is running or failed (the page shows it)
        #expect(!M.needsResume(trimmed: "shreya", committed: "shreya", state: nil, hasResults: true))
        #expect(!M.needsResume(trimmed: "shreya", committed: "shreya", state: .loading, hasResults: false))
        #expect(!M.needsResume(trimmed: "shreya", committed: "shreya", state: .loaded(0), hasResults: false))
        #expect(!M.needsResume(trimmed: "shreya", committed: "shreya", state: .failed("x"), hasResults: false))
    }
}
