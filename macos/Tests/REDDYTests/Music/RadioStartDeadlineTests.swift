import Testing
import Foundation
@testable import REDDY

@Suite("Radio start cannot hold the row forever") struct RadioStartDeadlineTests {
    @Test func aStartThatNeverAnswersIsReleasedAfterADeadline() throws {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { dir.deleteLastPathComponent() }
        let v = try String(contentsOf: dir.appendingPathComponent("Sources/REDDY/Features/Music/MusicRadioView.swift"), encoding: .utf8)
        #expect(v.contains("Task.sleep(for: .seconds(25))") && v.contains("startingID = nil"), "other stations must become clickable again if one start hangs")
        let bar = try String(contentsOf: dir.appendingPathComponent("Sources/REDDY/Features/Music/MusicPlayerBar.swift"), encoding: .utf8)
        #expect(bar.contains("y: g.size.height + 2"), "the seek bar's hover time sits below the bar, not on the transport buttons")
    }
}
