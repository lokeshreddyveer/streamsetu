import Testing
import Foundation
import Network
@testable import REDDY

/// A tiny HTTP server that answers every request with a never-ending stream.
private final class StreamServer: @unchecked Sendable {
    let listener: NWListener
    private(set) var port: UInt16 = 0
    private var open: [NWConnection] = []
    private let queue = DispatchQueue(label: "test.stream")
    init() throws { listener = try NWListener(using: .tcp, on: .any) }
    func start() async {
        let ready = AsyncStream<UInt16>.makeStream()
        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            self.open.append(c)
            c.start(queue: self.queue)
            c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                c.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in self.pump(c) })
            }
        }
        listener.stateUpdateHandler = { [listener] in if case .ready = $0, let p = listener.port?.rawValue { ready.continuation.yield(p) } }
        listener.start(queue: queue)
        for await p in ready.stream { port = p; break }
    }
    private func pump(_ c: NWConnection) {
        c.send(content: Data(repeating: 0x47, count: 20_000), completion: .contentProcessed { [weak self] e in
            guard e == nil else { return }
            self?.queue.asyncAfter(deadline: .now() + 0.05) { self?.pump(c) }
        })
    }
    func stop() { listener.cancel(); open.forEach { $0.cancel() } }
}

@MainActor @Suite struct ScheduledRecordingTests {
    private func channel() -> Channel {
        Channel(id: "c1", sourceID: UUID(), providerID: "1", name: "News 24", normalizedName: "news 24", categoryID: nil, categoryName: nil, logoURL: nil, epgID: nil, language: nil, country: nil, resolutionHint: nil, sortOrder: 0, streamRef: "x")
    }
    private func program(start: Date, end: Date) -> EPGProgram { EPGProgram(id: 1, sourceID: UUID(), xmltvChannelID: "x", start: start, end: end, title: "Evening Bulletin") }
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "rec.\(UUID())")! }

    @Test func recordsTheStreamAtItsTimeAndStopsAtTheEnd() async throws {
        let server = try StreamServer(); await server.start(); defer { server.stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("reddy-rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ch = channel()
        let url = URL(string: "http://127.0.0.1:\(server.port)/live.ts")!
        let service = ScheduledRecordingService(find: { _ in ch }, resolve: { c in PlaybackRequest(itemID: c.id, kind: .channel, sourceID: c.sourceID, title: c.name, url: url, isLive: true) },
                                                defaults: defaults(), folder: folder, padding: 0)
        #expect(service.schedule(program: program(start: Date().addingTimeInterval(-1), end: Date().addingTimeInterval(1.5)), channel: ch))
        #expect(!service.schedule(program: program(start: service.items[0].start, end: service.items[0].end), channel: ch))      // the same one twice
        await service.check()
        #expect(service.items[0].state == .recording)
        let started = Date()
        await service.waitForRecordings()
        #expect(Date().timeIntervalSince(started) < 30)
        #expect(service.items[0].state == .done, "ended as \(service.items[0].state): \(service.items[0].detail ?? "no detail")")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        try #require(files.count == 1)
        #expect((try files[0].resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0)
        #expect(files[0].lastPathComponent.hasPrefix("News 24 - Evening Bulletin__"))
    }

    @Test func aProgrammeThatAlreadyEndedIsMissedAndACancelledOneIsForgotten() async throws {
        let ch = channel()
        let service = ScheduledRecordingService(find: { _ in ch }, resolve: { _ in throw SourceError.unsupported("x") }, defaults: defaults(), folder: FileManager.default.temporaryDirectory, padding: 0)
        let soon = Date().addingTimeInterval(3600)
        #expect(service.schedule(program: program(start: soon, end: soon.addingTimeInterval(1800)), channel: ch))
        service.cancel(channelID: ch.id, start: soon)
        #expect(service.items.isEmpty)
        #expect(!service.schedule(program: program(start: Date().addingTimeInterval(-7200), end: Date().addingTimeInterval(-3600)), channel: ch))
    }

    @Test func scheduledRecordingsSurviveARelaunch() throws {
        let d = defaults(); let ch = channel()
        let a = ScheduledRecordingService(find: { _ in ch }, resolve: { _ in throw SourceError.unsupported("x") }, defaults: d, folder: FileManager.default.temporaryDirectory)
        let t = Date().addingTimeInterval(3600)
        a.schedule(program: program(start: t, end: t.addingTimeInterval(600)), channel: ch)
        let b = ScheduledRecordingService(find: { _ in ch }, resolve: { _ in throw SourceError.unsupported("x") }, defaults: d, folder: FileManager.default.temporaryDirectory)
        #expect(b.items.count == 1 && b.items[0].title == "Evening Bulletin")
    }
}

@Suite struct WeeklyRecordingTests {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func at(_ day: Int, _ h: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h))! }
    private func weekly(_ day: Int) -> ScheduledRecording {
        var r = ScheduledRecording(channelID: "c", channelName: "News", title: "Show", start: at(day, 20), end: at(day, 21)); r.repeatsWeekly = true; return r
    }

    @Test func aWeeklyOneIsScheduledAgainForTheSameTimeNextWeek() {
        let next = weekly(20).nextWeek(after: at(20, 22), calendar: cal)
        #expect(next?.start == at(27, 20) && next?.end == at(27, 21))
        #expect(next?.repeats == true && next?.state == .scheduled && next?.title == "Show")
    }
    @Test func aOneOffDoesNotRepeat() {
        var r = weekly(20); r.repeatsWeekly = nil
        #expect(r.nextWeek(after: at(20, 22), calendar: cal) == nil)
    }
    @Test func afterALongGapItSkipsToTheFirstWeekNotYetOver() {
        let next = weekly(1).nextWeek(after: at(20, 12), calendar: cal)          // the app was closed for weeks
        #expect(next?.start == at(22, 20))
    }
    @Test func recordingsSavedBeforeRepeatingExistedStillLoad() throws {
        let old = #"[{"id":"8C0E3B5E-5B1B-4B0B-9C11-0A1B2C3D4E5F","channelID":"c","channelName":"N","title":"T","start":0,"end":3600,"state":"scheduled"}]"#
        let list = try JSONDecoder().decode([ScheduledRecording].self, from: Data(old.utf8))
        #expect(list.first?.repeats == false)
    }
}
