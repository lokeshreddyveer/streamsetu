import Testing
import Foundation
@testable import REDDY

/// A stand-in for libmpv that records what is done to which context, and calls made on a context that was already destroyed (what would crash or corrupt memory with the real library).
private enum FakeMPV {
    static let lock = NSLock()
    nonisolated(unsafe) static var next: UInt = 0x1000
    nonisolated(unsafe) static var created: [UInt] = []
    nonisolated(unsafe) static var destroyed: Set<UInt> = []
    nonisolated(unsafe) static var violations: [String] = []
    nonisolated(unsafe) static var loadfiles: [String] = []

    static func reset() { lock.lock(); next = 0x1000; created = []; destroyed = []; violations = []; loadfiles = []; lock.unlock() }
    static func touch(_ ctx: OpaquePointer?, _ what: String) {
        guard let ctx else { return }
        let id = UInt(bitPattern: ctx)
        lock.lock(); if destroyed.contains(id) { violations.append("\(what) on destroyed context \(id)") }; lock.unlock()
    }
    static var snapshot: (violations: [String], loadfiles: [String], created: [UInt], destroyed: Set<UInt>) {
        lock.lock(); defer { lock.unlock() }; return (violations, loadfiles, created, destroyed)
    }

    static func library() -> MPVLibrary {
        let lib = MPVLibrary(testing: ())
        lib.create = { FakeMPV.lock.lock(); FakeMPV.next += 0x10; let id = FakeMPV.next; FakeMPV.created.append(id); FakeMPV.lock.unlock(); return OpaquePointer(bitPattern: id) }
        lib.initialize = { ctx in FakeMPV.touch(ctx, "initialize"); return 0 }
        lib.terminateDestroy = { ctx in
            FakeMPV.touch(ctx, "destroy again")
            if let ctx { FakeMPV.lock.lock(); FakeMPV.destroyed.insert(UInt(bitPattern: ctx)); FakeMPV.lock.unlock() }
        }
        lib.setOption = { ctx, _, _ in FakeMPV.touch(ctx, "setOption"); return 0 }
        lib.setProperty = { ctx, _, _ in FakeMPV.touch(ctx, "setProperty"); return 0 }
        lib.command = { ctx, argv in
            FakeMPV.touch(ctx, "command")
            var args: [String] = []; var i = 0
            while let p = argv?[i] { args.append(String(cString: p)); i += 1 }
            if args.first == "loadfile", args.count > 1 { FakeMPV.lock.lock(); FakeMPV.loadfiles.append(args[1]); FakeMPV.lock.unlock() }
            return 0
        }
        lib.requestLog = { ctx, _ in FakeMPV.touch(ctx, "requestLog"); return 0 }
        lib.wakeup = { _ in }
        lib.waitEvent = { _, _ in Thread.sleep(forTimeInterval: 0.005); return nil }
        lib.renderCreate = { out, ctx, _ in FakeMPV.touch(ctx, "renderCreate"); out?.pointee = OpaquePointer(bitPattern: 0x9000); return 0 }
        lib.renderFree = { _ in }
        lib.renderSetCallback = { _, _, _ in }
        lib.renderUpdate = { _ in 0 }
        return lib
    }
}

/// Lets a test hold one step of a load until it chooses to let it go on.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    private(set) var waiting = false
    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen { lock.unlock(); c.resume(); return }
            continuation = c; waiting = true; lock.unlock()
        }
    }
    func open() { lock.lock(); isOpen = true; let c = continuation; continuation = nil; lock.unlock(); c?.resume() }
}

/// Only the newest load of the MPV engine may attach playback or publish state; one that was overtaken, stopped or replaced while it waited must do nothing at all when it wakes.
@MainActor @Suite("MPV engine: loads that overlap", .serialized) struct MPVLoadRaceTests {
    private func request(_ name: String, live: Bool = false) -> PlaybackRequest {
        PlaybackRequest(itemID: name, kind: live ? .channel : .movie, sourceID: UUID(), title: name,
                        url: live ? URL(string: "http://host.example/\(name).ts")! : URL(fileURLWithPath: "/tmp/\(name).mkv"), isLive: live)
    }

    /// An engine whose rotation probe (local files) and relay start (live streams) wait at the gate of the name in the address.
    private func engine(gates: [String: Gate], relay: Bool = false) -> MPVPlayerEngine {
        FakeMPV.reset()
        var steps = MPVPlayerEngine.LoadSteps()
        steps.rotationDegrees = { url in await gates[url.deletingPathExtension().lastPathComponent]?.wait(); return 0 }
        steps.shouldRelay = { _ in relay }
        steps.startRelay = { req in await gates[req.url.deletingPathExtension().lastPathComponent]?.wait(); return nil }
        return MPVPlayerEngine(library: FakeMPV.library(), steps: steps)
    }

    private func waitUntilWaiting(_ g: Gate) async {
        for _ in 0..<2_000 where !g.waiting { try? await Task.sleep(nanoseconds: 1_000_000) }
    }

    @Test func aLoadOvertakenByAnotherDoesNothingWhenItWakes() async throws {
        let slow = Gate()
        let e = engine(gates: ["slow": slow])
        let a = Task { @MainActor in try await e.load(request("slow")) }
        await waitUntilWaiting(slow)
        try await e.load(request("fast"))                                          // the person switched channel: this one goes all the way through
        slow.open()
        let result = await a.result
        let seen = FakeMPV.snapshot
        #expect(seen.violations.isEmpty, "nothing may be done to a context that was already destroyed: \(seen.violations)")
        #expect(seen.loadfiles == ["file:///tmp/fast.mkv"], "only the newest load attaches playback")
        if case .success = result { Issue.record("the overtaken load must end as cancelled, not as a success") }
        e.stop()
    }

    @Test func aLoadStoppedWhileItWaitsDoesNothingWhenItWakes() async throws {
        let slow = Gate()
        let e = engine(gates: ["slow": slow])
        let a = Task { @MainActor in try await e.load(request("slow")) }
        await waitUntilWaiting(slow)
        e.stop()
        slow.open()
        _ = await a.result
        let seen = FakeMPV.snapshot
        #expect(seen.violations.isEmpty, "\(seen.violations)")
        #expect(seen.loadfiles.isEmpty, "a stopped engine must not start playing when a late load wakes")
        #expect(e.state != .playing && e.state != .buffering && e.state != .preparing)
    }

    @Test func aLiveStreamWhoseRelayStartIsOvertakenIsNotAttached() async throws {
        let slow = Gate()
        let e = engine(gates: ["slow": slow], relay: true)
        let a = Task { @MainActor in try await e.load(request("slow", live: true)) }
        await waitUntilWaiting(slow)
        try await e.load(request("fast", live: true))
        slow.open()
        _ = await a.result
        let seen = FakeMPV.snapshot
        #expect(seen.violations.isEmpty, "\(seen.violations)")
        #expect(seen.loadfiles == ["http://host.example/fast.ts"])
        e.stop()
    }

    @Test func threeSwitchesFinishingOutOfOrderLeaveOnlyTheNewestPlaying() async throws {
        let g1 = Gate(), g2 = Gate(), g3 = Gate()
        let e = engine(gates: ["one": g1, "two": g2, "three": g3])
        let a = Task { @MainActor in try await e.load(request("one")) }
        await waitUntilWaiting(g1)
        let b = Task { @MainActor in try await e.load(request("two")) }
        await waitUntilWaiting(g2)
        let c = Task { @MainActor in try await e.load(request("three")) }
        await waitUntilWaiting(g3)
        g3.open(); _ = await c.result          // the newest finishes first
        g1.open(); _ = await a.result          // then the oldest wakes
        g2.open(); _ = await b.result          // then the middle one
        let seen = FakeMPV.snapshot
        #expect(seen.violations.isEmpty, "\(seen.violations)")
        #expect(seen.loadfiles == ["file:///tmp/three.mkv"], "\(seen.loadfiles)")
        e.stop()
    }

    @Test func anOvertakenLoadPublishesNoState() async throws {
        let slow = Gate()
        let e = engine(gates: ["slow": slow])
        let states = Task { @MainActor () -> [PlaybackState] in
            var seen: [PlaybackState] = []
            for await s in e.stateUpdates { seen.append(s) }
            return seen
        }
        let a = Task { @MainActor in try await e.load(request("slow")) }
        await waitUntilWaiting(slow)
        try await e.load(request("fast"))
        let before = e.state
        slow.open()
        _ = await a.result
        #expect(e.state == before, "the overtaken load must not move the state of the newest one")
        states.cancel()
        e.stop()
    }
}
