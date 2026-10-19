import Testing
import Foundation
@testable import REDDY

@Suite struct RecordingTests {
    @Test func aRecordingIsNamedByChannelAndTimeAndReadBack() throws {
        let when = Date(timeIntervalSince1970: 1_792_000_000)
        let name = Recordings.fileName(channel: "News 24 | HD/4K", at: when)
        #expect(name.hasSuffix(".ts"))
        #expect(!name.contains("/") && !name.contains("|"))
        let parsed = try #require(Recordings.parse(fileName: name))
        #expect(parsed.title == "News 24 _ HD_4K")
        #expect(abs(parsed.date.timeIntervalSince(when)) < 1)
    }

    @Test func aFileThatIsNotOursIsIgnored() {
        #expect(Recordings.parse(fileName: "holiday.ts") == nil)
        #expect(Recordings.parse(fileName: "x__notadate.ts") == nil)
    }

    @Test func aChannelNameThatContainsTheSeparatorStillReadsBack() throws {
        let when = Date(timeIntervalSince1970: 1_792_000_000)
        let name = Recordings.fileName(channel: "A__B", at: when)
        #expect(try #require(Recordings.parse(fileName: name)).title == "A__B")
    }
}
