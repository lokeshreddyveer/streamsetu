import Testing
import Foundation
@testable import REDDY

@Suite struct PlaybackLogTests {
    private func makeLog(max: Int = 1_000_000) -> PlaybackLog {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("plog-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return PlaybackLog(url: dir.appendingPathComponent("playback.log"), maxBytes: max)
    }

    @Test func linesAreKeptInOrderWithALaunchHeader() {
        let log = makeLog()
        log.append("start movie"); log.append("state playing")
        let t = log.tail()
        #expect(t.first?.contains("--- launch") == true)
        #expect(t.suffix(2).map { $0.hasSuffix("start movie") || $0.hasSuffix("state playing") } == [true, true])
    }

    @Test func aRepeatedLineIsCountedNotStored() {
        let log = makeLog()
        for _ in 0..<50 { log.append("h264: mmco: unref short failure") }
        log.append("state playing")
        let t = log.tail()
        #expect(t.filter { $0.contains("mmco") }.count == 1)
        #expect(t.contains { $0.contains("repeated 49 more times") })
    }

    @Test func theFileIsTrimmedByRotation() {
        let log = makeLog(max: 2_000)
        for i in 0..<400 { log.append("line number \(i) with some padding text to fill the file") }
        _ = log.tail()
        let size = (try? FileManager.default.attributesOfItem(atPath: log.url.path)[.size] as? Int) ?? 0
        #expect(size < 4_000)
        #expect(log.tail().last?.contains("line number 399") == true)
    }

    @Test func loginsNeverReachTheLog() {
        let log = makeLog()
        Trace.log("start http://host:8080/live/bob/s3cretpass/12345.ts")
        let joined = PlaybackLog.shared.tail(lines: 20).joined(separator: "\n")
        #expect(!joined.contains("s3cretpass"))
        _ = log
    }

    @Test func clearEmptiesTheLog() {
        let log = makeLog()
        log.append("something"); log.clear()
        #expect(log.tail().isEmpty)
    }
}
