import Testing
import Foundation
@testable import REDDY

/// A graph change that arrives while a section is still loading must not be lost: that load may have read older edges, so it has to run once more when it
/// ends (the page then shows the new data and not the old). `MusicEntityModel.refresh()` used to skip a section that was loading, so a change made during
/// a slow first load never reached the page.
@MainActor
@Suite("Entity model keeps changes that arrive during a load")
struct EntityModelChangeWhileLoadingTests {
    private actor Latch {
        private var opened = false
        func open() { opened = true }
        func wait() async { while !opened { try? await Task.sleep(nanoseconds: 2_000_000) } }
    }

    private actor Runs {
        private(set) var count = 0
        func next() -> Int { count += 1; return count }
    }

    private func readyModel() async throws -> MusicEntityModel {
        let f = await SongFixture.awaara()
        let model = MusicEntityModel(id: f["awara"], store: MusicEntityStore(graph: f.graph))
        model.start()
        try await settle { model.snapshot != nil }
        return model
    }

    private func settle(_ done: @MainActor () -> Bool) async throws {
        for _ in 0..<600 where !done() { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(done(), "the condition never became true")
    }

    @Test func aChangeDuringTheFirstLoadRunsTheSectionAgain() async throws {
        let model = try await readyModel()
        let latch = Latch(), runs = Runs()
        let key = "guard.section"
        model.load(MusicClosureSectionLoader(key: key) { _, _, _ in
            let n = await runs.next()
            if n == 1 { await latch.wait() }           // the first run is slow; it has read the old edges
            return MusicSectionResult(items: [AnyHashable(n)])
        })
        try await settle { model.section(key).phase == .loading }
        while await runs.count == 0 { try await Task.sleep(nanoseconds: 2_000_000) }

        await model.refresh()                           // the graph changed for this entity while the section is loading
        await latch.open()
        try await settle { !model.isWorking }

        #expect(await runs.count == 2, "the section must run again after the change that arrived while it loaded")
        #expect(model.sectionRuns[key] == 2)
        #expect(model.section(key).items(Int.self) == [2], "the page must end up with the second run's items")
        #expect(model.section(key).phase == .loaded)
    }

    @Test func aChangeAfterTheLoadHasFinishedRunsItOnceMoreAndNotTwice() async throws {
        let model = try await readyModel()
        let runs = Runs()
        let key = "guard.settled"
        model.load(MusicClosureSectionLoader(key: key) { _, _, _ in MusicSectionResult(items: [AnyHashable(await runs.next())]) })
        try await settle { model.section(key).phase == .loaded }
        await model.refresh()
        try await settle { !model.isWorking && model.section(key).items(Int.self) == [2] }
        #expect(await runs.count == 2)
    }

    @Test func aChangeDuringAPartialStageIsNotLostEither() async throws {
        let model = try await readyModel()
        let latch = Latch(), runs = Runs()
        let key = "guard.partial"
        model.load(MusicClosureSectionLoader(key: key) { _, _, report in
            let n = await runs.next()
            if n == 1 {
                await report.partial(MusicSectionResult(items: [AnyHashable(100)]))
                await latch.wait()
            }
            return MusicSectionResult(items: [AnyHashable(n)])
        })
        try await settle { model.section(key).phase == .partial }

        await model.refresh()
        await latch.open()
        try await settle { !model.isWorking }

        #expect(model.section(key).items(Int.self) == [2])
        #expect(model.section(key).phase == .loaded)
    }

    @Test func aSectionThatNeverLoadedIsNotStartedByARefresh() async throws {
        let model = try await readyModel()
        let runs = Runs()
        model.load(MusicClosureSectionLoader(key: "guard.other") { _, _, _ in MusicSectionResult(items: [AnyHashable(await runs.next())]) })
        try await settle { model.section("guard.other").phase == .loaded }
        await model.refresh()
        try await settle { !model.isWorking }
        // Only sections the page has loaded are refreshed; an unknown key stays untouched.
        #expect(model.section("never.asked").phase == .idle)
    }
}
