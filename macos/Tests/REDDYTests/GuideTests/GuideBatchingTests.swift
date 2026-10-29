import Testing
import Foundation
@testable import REDDY

/// Counts the programme queries the guide makes: rows are read in batches, never one query per row.
private final class QueryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [[String]] = []
    var delay: Duration = .zero
    func record(_ ids: [String]) { lock.lock(); all.append(ids); lock.unlock() }
    var queries: [[String]] { lock.lock(); defer { lock.unlock() }; return all }
}

@MainActor @Suite("The guide reads programmes in batches") struct GuideBatchingTests {
    nonisolated private func program(_ channel: String, _ title: String) -> EPGProgram {
        EPGProgram(id: Int64(abs(channel.hashValue % 100_000)), sourceID: UUID(), xmltvChannelID: channel, start: Date(), end: Date().addingTimeInterval(1800), title: title)
    }

    private func model(channels n: Int, log: QueryLog, title: String = "Now") throws -> GuideViewModel {
        let db = try TestSupport.makeDB()
        let src = try TestSupport.makeSource(db)
        let vm = GuideViewModel()
        vm.useChannels((0..<n).map { TestSupport.channel(src, "\($0)", "Channel \($0)", order: $0) })
        vm.fetch = { [self] ids, _, _ in
            log.record(ids)
            if log.delay != .zero { try? await Task.sleep(for: log.delay) }
            return Dictionary(uniqueKeysWithValues: ids.map { ($0, [program($0, title)]) })
        }
        return vm
    }

    @Test func manyRowsAppearingTogetherAreOneQueryNotOnePerRow() async throws {
        let log = QueryLog(); let vm = try model(channels: 200, log: log)
        let ids = vm.channels.map(\.id)
        for id in ids.prefix(30) { vm.rowAppeared(id) }
        await vm.flush()
        #expect(log.queries.count == 1, "30 visible rows made \(log.queries.count) queries")
        #expect(Set(log.queries[0]).isSuperset(of: Set(ids.prefix(30))), "every visible row is in it")
        #expect(log.queries[0].count <= GuideViewModel.batchSize)
        #expect(vm.programs[ids[0]]?.first?.title == "Now")
    }

    @Test func aSmallRangeBesideTheVisibleRowsIsReadAhead() async throws {
        let log = QueryLog(); let vm = try model(channels: 200, log: log)
        let ids = vm.channels.map(\.id)
        for id in ids[50..<60] { vm.rowAppeared(id) }
        await vm.flush()
        let asked = Set(log.queries.flatMap { $0 })
        #expect(asked.contains(ids[60 + GuideViewModel.prefetchAhead - 2]), "rows just below are ready before they are scrolled to")
        #expect(asked.contains(ids[50 - GuideViewModel.prefetchBehind]), "and just above")
        #expect(!asked.contains(ids[150]) && !asked.contains(ids[0]), "but nothing far away")
    }

    @Test func aQueryNeverAsksForMoreThanTheBatchSize() async throws {
        let log = QueryLog(); let vm = try model(channels: 500, log: log)
        for id in vm.channels.map(\.id).prefix(200) { vm.rowAppeared(id) }
        await vm.flush()
        #expect(log.queries[0].count == GuideViewModel.batchSize)
        #expect(Set(log.queries[0]).isSuperset(of: Set(vm.channels.map(\.id).prefix(GuideViewModel.batchSize))), "the visible rows come first")
    }

    @Test func rowsThatLeftTheScreenBeforeTheQueryAreNotAsked() async throws {
        let log = QueryLog(); let vm = try model(channels: 300, log: log)
        let ids = vm.channels.map(\.id)
        for id in ids[0..<10] { vm.rowAppeared(id) }
        for id in ids[0..<10] { vm.rowDisappeared(id) }
        await vm.flush()
        #expect(log.queries.isEmpty, "nothing on screen, nothing asked")
    }

    @Test func anAnswerForAWindowThatHasMovedOnIsThrownAway() async throws {
        let log = QueryLog(); log.delay = .milliseconds(60)
        let vm = try model(channels: 50, log: log, title: "Old window")
        let id = vm.channels[0].id
        vm.rowAppeared(id)
        let reading = Task { await vm.flush() }
        try await Task.sleep(for: .milliseconds(20))
        vm.windowMoved()                                           // the person scrolled two hours while the first answer was still coming
        await reading.value
        #expect(vm.programs[id] == nil, "the stale answer was not shown")
    }

    @Test func theGridKeepsWhatItHadWhileTheNextWindowLoads() async throws {
        let log = QueryLog(); let vm = try model(channels: 50, log: log)
        let id = vm.channels[0].id
        vm.rowAppeared(id); await vm.flush()
        #expect(vm.programs[id]?.first?.title == "Now")
        vm.windowMoved()
        #expect(vm.programs[id]?.first?.title == "Now", "still on screen until the new answer arrives")
        await vm.flush()
        #expect(log.queries.count == 2, "and the new window was read once, in one query")
    }
}
