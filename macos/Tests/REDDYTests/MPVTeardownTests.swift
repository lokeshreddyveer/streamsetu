import Testing
import Foundation
@testable import REDDY

/// A stand-in for libmpv that logs, in order, what happens to which context, so teardown can be checked against the next start.
private enum Fake {
    static let lock = NSLock()
    nonisolated(unsafe) static var next: UInt = 0x2000
    nonisolated(unsafe) static var log: [String] = []
    nonisolated(unsafe) static var destroyed: Set<UInt> = []
    nonisolated(unsafe) static var violations: [String] = []
    nonisolated(unsafe) static var destroyDelay: TimeInterval = 0
    /// When set, destroying a context blocks until the test opens the gate (no wall-clock assumptions).
    nonisolated(unsafe) static var destroyGate: DispatchSemaphore?

    static func reset(destroyDelay d: TimeInterval = 0) { lock.lock(); next = 0x2000; log = []; destroyed = []; violations = []; destroyDelay = d; destroyGate = nil; lock.unlock() }
    static func setGate(_ g: DispatchSemaphore?) { lock.lock(); destroyGate = g; lock.unlock() }
    static func note(_ s: String) { lock.lock(); log.append(s); lock.unlock() }
    static func touch(_ ctx: OpaquePointer?, _ what: String) {
        guard let ctx else { return }
        lock.lock(); if destroyed.contains(UInt(bitPattern: ctx)) { violations.append("\(what) on destroyed \(UInt(bitPattern: ctx))") }; lock.unlock()
    }
    final class Flag: @unchecked Sendable { private let l = NSLock(); private var v = false; var value: Bool { l.lock(); defer { l.unlock() }; return v }; func set() { l.lock(); v = true; l.unlock() } }
    static var snapshot: (log: [String], violations: [String]) { lock.lock(); defer { lock.unlock() }; return (log, violations) }

    static func library() -> MPVLibrary {
        let lib = MPVLibrary(testing: ())
        lib.create = { Fake.lock.lock(); Fake.next += 0x10; let id = Fake.next; Fake.log.append("create \(id)"); Fake.lock.unlock(); return OpaquePointer(bitPattern: id) }
        lib.initialize = { ctx in Fake.touch(ctx, "initialize"); return 0 }
        lib.terminateDestroy = { ctx in
            Fake.touch(ctx, "destroy twice")
            Fake.lock.lock(); let d = Fake.destroyDelay; Fake.lock.unlock()
            if d > 0 { Thread.sleep(forTimeInterval: d) }
            Fake.lock.lock(); let gate = Fake.destroyGate; Fake.lock.unlock()
            _ = gate?.wait(timeout: .now() + 10)
            if let ctx { Fake.lock.lock(); Fake.destroyed.insert(UInt(bitPattern: ctx)); Fake.log.append("destroy \(UInt(bitPattern: ctx))"); Fake.lock.unlock() }
        }
        lib.setOption = { ctx, _, _ in Fake.touch(ctx, "setOption"); return 0 }
        lib.setProperty = { ctx, name, value in
            Fake.touch(ctx, "setProperty")
            if let ctx, let name, let value, String(cString: name) == "mute" { Fake.note("\(String(cString: value) == "yes" ? "mute" : "unmute") \(UInt(bitPattern: ctx))") }
            return 0
        }
        lib.command = { ctx, _ in Fake.touch(ctx, "command"); return 0 }
        lib.requestLog = { ctx, _ in Fake.touch(ctx, "requestLog"); return 0 }
        lib.wakeup = { _ in }
        lib.waitEvent = { _, _ in Thread.sleep(forTimeInterval: 0.005); return nil }
        lib.renderCreate = { out, ctx, _ in Fake.touch(ctx, "renderCreate"); out?.pointee = OpaquePointer(bitPattern: 0x9000); return 0 }
        lib.renderFree = { _ in }
        lib.renderSetCallback = { _, _, _ in }
        lib.renderUpdate = { _ in 0 }
        return lib
    }
}

@MainActor @Suite("MPV engine: teardown off the main actor", .serialized) struct MPVTeardownTests {
    private func request(_ name: String) -> PlaybackRequest {
        PlaybackRequest(itemID: name, kind: .movie, sourceID: UUID(), title: name, url: URL(fileURLWithPath: "/tmp/\(name).mkv"), isLive: false)
    }
    private func engine(destroyDelay: TimeInterval = 0) -> MPVPlayerEngine {
        Fake.reset(destroyDelay: destroyDelay)
        var steps = MPVPlayerEngine.LoadSteps()
        steps.rotationDegrees = { _ in 0 }
        return MPVPlayerEngine(library: Fake.library(), steps: steps)
    }
    private func id(_ prefix: String, in log: [String]) -> [Int] { log.enumerated().filter { $0.element.hasPrefix(prefix) }.map(\.offset) }

    @Test func stopReturnsBeforeASlowDestroyFinishes() async throws {
        let e = engine()
        let gate = DispatchSemaphore(value: 0)
        try await e.load(request("a"))
        Fake.setGate(gate)          // the destroy cannot finish until the test says so
        e.stop()                                             // had stop waited for the destroy, it would sit here until the gate times out and the log below would hold a destroy
        #expect(!Fake.snapshot.log.contains { $0.hasPrefix("destroy") }, "destroy has not finished: stop did not wait for it")
        gate.signal()
        await e.drainTeardown()
        #expect(Fake.snapshot.log.contains { $0.hasPrefix("destroy") })
        #expect(Fake.snapshot.violations.isEmpty)
    }

    @Test func aDifferentEngineCanWaitForTheTeardownAndThePictureIsWipedAgainAfterIt() async throws {
        let e = engine()
        let gate = DispatchSemaphore(value: 0)
        try await e.load(request("a"))
        let before = e.layerClears
        Fake.setGate(gate)
        e.stop()
        #expect(e.layerClears == before + 1, "wiped at once")
        let finished = Fake.Flag()
        let waiter = Task { await MPVPlayerEngine.drainAllTeardowns(); finished.set() }
        for _ in 0..<20 { await Task.yield() }
        #expect(!finished.value && !Fake.snapshot.log.contains { $0.hasPrefix("destroy") }, "nothing may start on another engine while the old connection is still open")
        gate.signal()
        await waiter.value
        #expect(finished.value && Fake.snapshot.log.contains { $0.hasPrefix("destroy") })
        for _ in 0..<500 where e.layerClears < before + 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(e.layerClears == before + 2, "wiped again once the render queue had drained, so a late frame cannot stay on the layer")
    }

    @Test func theOldContextIsSilencedAtOnceAndDestroyedBeforeTheNextOneExists() async throws {
        let e = engine(destroyDelay: 0.1)
        try await e.load(request("a"))
        try await e.load(request("b"))                       // a channel switch: no stop in between
        let log = Fake.snapshot.log
        let create = id("create", in: log), destroy = id("destroy", in: log), mute = id("mute", in: log)
        #expect(create.count == 2 && destroy.count == 1 && mute.count == 1, "\(log)")
        #expect(mute[0] < create[1], "the first stream is muted before the second one starts")
        #expect(destroy[0] < create[1], "destroyed before the next context is created: no overlap, no two decoders")
        #expect(Fake.snapshot.violations.isEmpty)
        e.stop(); await e.drainTeardown()
    }

    @Test func aLoadThatWaitsForTeardownAndIsThenStoppedNeverCreatesAContext() async throws {
        let e = engine(destroyDelay: 0.3)
        try await e.load(request("a"))
        e.stop()
        let b = Task { @MainActor in try await e.load(request("b")) }
        await Task.yield()
        e.stop()                                             // the person gave up while the old stream was still being taken down
        let result = await b.result
        if case .success = result { Issue.record("a load stopped while waiting must end as cancelled") }
        await e.drainTeardown()
        #expect(Fake.snapshot.log.filter { $0.hasPrefix("create") }.count == 1, "only the first context was ever created")
        #expect(Fake.snapshot.violations.isEmpty)
    }

    @Test func rapidChannelSwitchingDestroysEveryContextExactlyOnceAndTouchesNoneAfter() async throws {
        let e = engine(destroyDelay: 0.02)
        for n in 0..<8 { try await e.load(request("c\(n)")) }
        e.stop()
        await e.drainTeardown()
        let s = Fake.snapshot
        #expect(s.log.filter { $0.hasPrefix("create") }.count == 8)
        #expect(s.log.filter { $0.hasPrefix("destroy") }.count == 8)
        #expect(s.violations.isEmpty, "\(s.violations)")
        // at no point are two contexts alive: every destroy of context k comes before the create of context k+1
        var alive = 0, peak = 0
        for l in s.log { if l.hasPrefix("create") { alive += 1; peak = max(peak, alive) } else if l.hasPrefix("destroy") { alive -= 1 } }
        #expect(peak == 1, "contexts alive at once: \(peak)")
    }
}
