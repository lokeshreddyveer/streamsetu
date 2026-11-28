import Foundation

/// Runs every lane at once and keeps the first acceptable answer. A lane returns nil when it found nothing acceptable. Lanes are given in
/// priority order (healthy providers first): when two answers arrive close together the earlier lane wins.
struct MusicRaceLane<Value: Sendable>: Sendable {
    var id: String
    var run: @Sendable () async throws -> Value?
}

struct MusicRaceResult<Value: Sendable>: Sendable {
    var winner: Int?
    var value: Value?
    /// Lane index to the error it ended with.
    var errors: [Int: String] = [:]
    var errorKinds: [Int: Error] = [:]
    var empty: Set<Int> = []
    var timedOut: Set<Int> = []
}

enum MusicRace {
    struct Config: Sendable {
        /// Normal limit for the whole race.
        var overall: TimeInterval = 20
        /// Lanes in `patientIDs` may keep going until this moment (a slow extractor that is still making progress).
        var patient: TimeInterval = 120
        var patientIDs: Set<String> = []
        /// How long a winner waits for a higher-priority lane that is still running.
        var tieGrace: TimeInterval = 0.2
    }

    private enum Event<V: Sendable>: Sendable {
        case done(Int, V?)
        case failed(Int, String, Error)
        case overall, patient, grace
    }

    static func run<V: Sendable>(lanes: [MusicRaceLane<V>], config: Config = Config(),
                                 sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) async -> MusicRaceResult<V> {
        var result = MusicRaceResult<V>()
        guard !lanes.isEmpty else { return result }
        let (events, cont) = AsyncStream<Event<V>>.makeStream()
        var laneTasks: [Task<Void, Never>] = []
        for (i, lane) in lanes.enumerated() {
            laneTasks.append(Task {
                do { cont.yield(.done(i, try await lane.run())) }
                catch { cont.yield(.failed(i, String(describing: error), error)) }
            })
        }
        var timers: [Task<Void, Never>] = []
        func timer(_ seconds: TimeInterval, _ ev: Event<V>) {
            timers.append(Task { do { try await sleep(seconds); cont.yield(ev) } catch {} })
        }
        timer(config.overall, .overall)
        var pending = Set(0..<lanes.count)
        var best: (index: Int, value: V)?
        var graceStarted = false

        func drop(_ i: Int) { pending.remove(i); laneTasks[i].cancel() }
        func finished() -> Bool {
            guard let b = best else { return pending.isEmpty }
            return !pending.contains { $0 < b.index }
        }

        loop: for await ev in events {
            switch ev {
            case .done(let i, let v):
                guard pending.contains(i) else { break }
                pending.remove(i)
                if let v { if best == nil || i < best!.index { best = (i, v) } } else { result.empty.insert(i) }
            case .failed(let i, let text, let err):
                guard pending.contains(i) else { break }
                pending.remove(i)
                if (err as? MusicError) == .cancelled || err is CancellationError { result.empty.insert(i) } else { result.errors[i] = text; result.errorKinds[i] = err }
            case .grace:
                if best != nil { break loop }
            case .overall:
                if best != nil { break loop }
                let slow = pending.filter { config.patientIDs.contains(lanes[$0].id) }
                for i in pending.subtracting(slow) { result.timedOut.insert(i); drop(i) }
                if slow.isEmpty { break loop }
                timer(max(0, config.patient - config.overall), .patient)
            case .patient:
                for i in pending { result.timedOut.insert(i) }
                break loop
            }
            if best != nil, finished() { break loop }
            if best != nil, !graceStarted { graceStarted = true; timer(config.tieGrace, .grace) }
            if best == nil, pending.isEmpty { break loop }
        }
        cont.finish()
        timers.forEach { $0.cancel() }
        laneTasks.forEach { $0.cancel() }
        if let b = best { result.winner = b.index; result.value = b.value }
        return result
    }
}
